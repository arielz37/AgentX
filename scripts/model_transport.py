"""Bounded, observable retries for inference only; never calls an iPhone tool."""
from contextlib import contextmanager
from contextvars import ContextVar
import copy
import email.utils
import hashlib
import http.client
import json
import os
import random
import socket
import ssl
import time
import urllib.error
import urllib.request

STAGE_TIMEOUT = 120
PARSE_TIMEOUT = 180  # Inventory, complete draft and independent review share this budget.
ATTEMPT_TIMEOUT = 60
MAX_ATTEMPTS = 3
_journal = ContextVar('model_request_journal', default=None)
QUOTA_CODES = {'insufficient_quota', 'billing_hard_limit_reached', 'billing_not_active',
               'organization_spend_limit_exceeded', 'project_spend_limit_exceeded',
               'organization_usage_limit_exceeded', 'credits_exhausted'}


class ModelRequestError(RuntimeError):
    def __init__(self, code, metadata):
        super().__init__(code)
        self.model_metadata = metadata
        self.request_metadata = metadata


@contextmanager
def request_journal(entries, persist):
    """Checkpoint complete inference responses before review, in local task JSON."""
    token = _journal.set((entries, persist))
    try:
        yield
    finally:
        _journal.reset(token)


def _retry_after(headers):
    raw = (headers or {}).get('Retry-After', '')
    try:
        return max(0, float(raw))
    except (ValueError, TypeError):
        try:
            return max(0, email.utils.parsedate_to_datetime(raw).timestamp() - time.time())
        except (ValueError, TypeError, AttributeError):
            return 0


def _http_code(error):
    # Classify a provider code, never retain its message, request headers or body.
    try:
        info = json.loads(error.read(65536)).get('error', {})
        code = info.get('code') or info.get('type')
        if code in QUOTA_CODES or info.get('type') == 'insufficient_quota':
            return 'model_quota_exhausted', False
    except (ValueError, TypeError, AttributeError, OSError):
        pass
    return f'model_http_{error.code}', error.code in (408, 409, 429) or error.code >= 500


def _read_response(response, deadline, attempt, started):
    """Consume SSE but only accept a terminal full response, never partial JSON."""
    if 'text/event-stream' not in response.headers.get('Content-Type', '').lower():
        return json.load(response)
    attempt['transport'] = 'sse'
    attempt['stream_events'] = 0
    data = []
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        # urllib's HTTPResponse socket must use the remaining wall-clock budget;
        # a continuous stream must not extend the request indefinitely.
        sock = getattr(getattr(getattr(response, 'fp', None), 'raw', None), '_sock', None)
        if sock is not None:
            sock.settimeout(remaining)
        raw = response.readline()
        if not raw:
            # Even syntactically complete output_text is untrusted before the
            # response.completed event. A truncated stream is retryable.
            raise http.client.IncompleteRead(b'')
        line = (raw.decode('utf-8') if isinstance(raw, bytes) else raw).rstrip('\r\n')
        if line.startswith('data:'):
            data.append(line[5:].lstrip(' '))
        elif not line and data:
            event = json.loads('\n'.join(data)); data = []
            if not isinstance(event, dict):
                raise ValueError('Invalid stream event')
            attempt['stream_events'] += 1
            attempt.setdefault('first_event_seconds', round(time.monotonic()-started, 3))
            if event.get('type') in ('response.completed', 'response.incomplete', 'response.failed'):
                result = event.get('response')
                if not isinstance(result, dict):
                    raise ValueError('Invalid terminal response')
                return result
            if event.get('type') == 'error':
                return {'status': 'failed', 'error': {'code': event.get('code')}}


def request_json(messages, schema, name, deadline):
    key = os.environ.get('OPENAI_API_KEY', '')
    if not key:
        raise ModelRequestError('model_not_configured', {'stage': name, 'attempts': []})
    body = {'model': os.environ.get('AGENTX_MODEL', 'gpt-4.1-mini'), 'store': False, 'stream': True,
            'input': messages, 'max_output_tokens': 16000,
            'text': {'format': {'type': 'json_schema', 'name': name, 'strict': True, 'schema': schema}}}
    fingerprint = hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    journal = _journal.get()
    entry = journal[0].setdefault(fingerprint, {'stage': name, 'attempts': []}) if journal else {'stage': name, 'attempts': []}
    if 'value' in entry:
        return copy.deepcopy(entry['value']), {**copy.deepcopy(entry['metadata']), 'checkpoint_reused': True}
    attempts = entry['attempts']
    if any(a.get('error') == 'model_output_limit' for a in attempts):
        body['max_output_tokens'] = 32000

    def persist():
        if journal:
            journal[1]()

    def fail(code):
        raise ModelRequestError(code, {'stage': name, 'requested_model': body['model'], 'attempts': copy.deepcopy(attempts)})

    # Pending requests left by a crash count toward the same per-request limit.
    while len(attempts) < MAX_ATTEMPTS:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail('model_stage_timeout')
        if attempts:
            if attempts[-1].get('retryable') is False:
                fail(attempts[-1].get('error', 'model_request_failed'))
            delay = max(attempts[-1].get('retry_after_seconds', 0), 2 ** (len(attempts)-1) + random.uniform(0, .3))
            # Persist wall-clock retry time so a worker restart cannot skip it.
            retry_at = attempts[-1].setdefault('retry_at', time.time() + delay)
            delay = max(0, retry_at - time.time())
            if delay + 1 >= remaining:
                persist(); fail(attempts[-1].get('error', 'model_stage_timeout'))
            persist(); time.sleep(delay)
        started = time.monotonic()
        attempt = {'number': len(attempts)+1, 'status': 'started', 'max_output_tokens': body['max_output_tokens']}
        attempts.append(attempt); persist()
        retryable = False
        code = 'model_request_failed'
        result = None
        req = urllib.request.Request('https://api.openai.com/v1/responses', data=json.dumps(body).encode(),
            headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=min(ATTEMPT_TIMEOUT, max(.001, deadline-time.monotonic()))) as response:
                attempt['request_id'] = response.headers.get('x-request-id')
                result = _read_response(response, min(deadline, started+ATTEMPT_TIMEOUT), attempt, started)
        except urllib.error.HTTPError as error:
            code, retryable = _http_code(error)
            attempt.update(http_status=error.code, request_id=error.headers.get('x-request-id') if error.headers else None,
                           retry_after_seconds=_retry_after(error.headers))
            error.close()
        except (TimeoutError, socket.timeout):
            code, retryable = 'model_request_timeout', True
        except urllib.error.URLError as error:
            reason = error.reason
            code = 'model_request_timeout' if isinstance(reason, (TimeoutError, socket.timeout)) else 'model_network_error'
            retryable = not isinstance(reason, ssl.SSLCertVerificationError)
        except (ConnectionError, http.client.HTTPException):
            code, retryable = 'model_connection_interrupted', True
        except (ValueError, UnicodeError):
            code, retryable = 'model_invalid_response', True
        attempt['elapsed_seconds'] = round(time.monotonic()-started, 3)
        if result is not None:
            if not isinstance(result, dict):
                code, retryable = 'model_invalid_response', True
            elif time.monotonic() > deadline:
                code = 'model_stage_timeout'
            else:
                attempt.update(response_id=result.get('id'), response_status=result.get('status'), usage=result.get('usage'))
                reason = (result.get('incomplete_details') or {}).get('reason')
                provider_code = (result.get('error') or {}).get('code')
                if result.get('status') == 'failed':
                    if provider_code in QUOTA_CODES:
                        code = 'model_quota_exhausted'
                    elif provider_code in ('server_error', 'rate_limit_exceeded'):
                        code, retryable = 'model_provider_temporary_error', True
                    else:
                        code = 'model_provider_failed'
                elif result.get('status') == 'incomplete' and reason == 'max_output_tokens':
                    code, retryable = 'model_output_limit', body['max_output_tokens'] < 32000
                    body['max_output_tokens'] = 32000
                elif result.get('status') != 'completed':
                    code = 'model_filtered' if reason == 'content_filter' else 'model_incomplete'
                else:
                    chunks = [c for o in result.get('output', []) for c in o.get('content', [])]
                    if any(c.get('type') == 'refusal' for c in chunks):
                        code = 'model_refused'
                    else:
                        try:
                            value = json.loads(''.join(c['text'] for c in chunks if c.get('type') == 'output_text'))
                        except (ValueError, KeyError, TypeError):
                            code, retryable = 'model_invalid_json', True
                        else:
                            attempt['status'] = 'completed'
                            metadata = {'model': result.get('model', body['model']), 'requested_model': body['model'],
                                        'response_id': result.get('id'), 'usage': result.get('usage'),
                                        'stage': name, 'attempts': copy.deepcopy(attempts)}
                            entry.update(value=value, metadata=metadata); persist()
                            return value, metadata
        attempt.update(status='failed', error=code, retryable=retryable)
        persist()
        if not retryable:
            fail(code)
    fail(attempts[-1].get('error', 'model_attempts_exhausted'))
