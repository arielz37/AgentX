import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
import model_transport as transport
from agentx_worker import Worker, failure_message
from fixtures import job, envelope


def response(value=None, **changes):
    body = dict(status='completed', id='resp-test', model='test-model', usage={'output_tokens': 4},
                output=[{'content': [{'type': 'output_text', 'text': json.dumps(value or {'ok': True})}]}])
    body.update(changes)
    stream = io.StringIO(json.dumps(body)); stream.headers = {'x-request-id': 'req-test'}
    return stream


def http_error(code, provider_code='server_error', headers=None):
    return urllib.error.HTTPError('https://api.openai.com/v1/responses', code, 'private error message',
                                  headers or {}, io.BytesIO(json.dumps({'error': {'code': provider_code, 'message': 'private body'}}).encode()))


def sse(events, crlf=False):
    text = ': heartbeat\n\n' + ''.join('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n' for event in events)
    stream = io.BytesIO(text.replace('\n','\r\n').encode() if crlf else text.encode())
    stream.headers = {'Content-Type':'text/event-stream; charset=utf-8','x-request-id':'req-stream'}
    return stream


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, OPENAI_API_KEY='secret-test-key'); self.env.start()
        self.sleep = patch('model_transport.time.sleep'); self.sleep.start()
    def tearDown(self):
        self.sleep.stop(); self.env.stop()
    def invoke(self, name='test', deadline=None):
        return transport.request_json([{'role':'user','content':'test input'}], {'type':'object'}, name,
                                      deadline or time.monotonic()+120)
    def test_timeout_retries_with_bounded_timeout(self):
        with patch.object(transport.urllib.request, 'urlopen', side_effect=[TimeoutError(), response()]) as api:
            value, meta = self.invoke()
        self.assertTrue(value['ok']); self.assertEqual(len(meta['attempts']), 2)
        self.assertEqual(meta['attempts'][0]['error'], 'model_request_timeout')
        self.assertEqual(api.call_args_list[0].kwargs['timeout'], 60)
        self.assertNotIn('secret-test-key', json.dumps(meta))
    def test_network_reset_recovers(self):
        with patch.object(transport.urllib.request, 'urlopen', side_effect=[ConnectionResetError(), response()]):
            _, meta = self.invoke()
        self.assertEqual(meta['attempts'][0]['error'], 'model_connection_interrupted')
    def test_stream_uses_terminal_full_response_not_text_deltas(self):
        terminal=json.loads(response().getvalue())
        events=[{'type':'response.created'}, {'type':'response.output_text.delta','delta':'{"ok":false}'},
                {'type':'response.completed','response':terminal}]
        with patch.object(transport.urllib.request,'urlopen',return_value=sse(events,crlf=True)) as api:
            value,meta=self.invoke()
        self.assertTrue(value['ok']); self.assertTrue(json.loads(api.call_args.args[0].data)['stream'])
        self.assertEqual(meta['attempts'][0]['stream_events'],3)
        self.assertEqual(meta['attempts'][0]['transport'],'sse')
    def test_stream_eof_after_valid_json_retries_without_checkpointing_partial_plan(self):
        entries={};saved=[]
        partial=sse([{'type':'response.output_text.done','text':'{"ok":false}'}])
        with transport.request_journal(entries,lambda:saved.append(copy.deepcopy(entries))), patch.object(transport.urllib.request,'urlopen',side_effect=[partial,response()]):
            value,meta=self.invoke()
        self.assertTrue(value['ok'])
        self.assertEqual(meta['attempts'][0]['error'],'model_connection_interrupted')
        self.assertFalse(any(e.get('value')=={'ok':False} for snapshot in saved for e in snapshot.values()))
    def test_stream_failed_temporary_error_retries_but_quota_does_not(self):
        failed={'type':'response.failed','response':{'status':'failed','error':{'code':'server_error'}}}
        with patch.object(transport.urllib.request,'urlopen',side_effect=[sse([failed]),response()]):
            _,meta=self.invoke()
        self.assertEqual(meta['attempts'][0]['error'],'model_provider_temporary_error')
        with patch.object(transport.urllib.request,'urlopen',return_value=sse([{'type':'error','code':'insufficient_quota','message':'private'}])) as api:
            with self.assertRaises(transport.ModelRequestError) as ctx:self.invoke()
        self.assertEqual(str(ctx.exception),'model_quota_exhausted'); self.assertEqual(api.call_count,1)
        self.assertNotIn('private',json.dumps(ctx.exception.request_metadata))
    def test_stream_obeys_wall_clock_deadline_even_with_continuous_events(self):
        stream=sse([{'type':'response.created'}, {'type':'response.completed','response':json.loads(response().getvalue())}])
        with patch.object(transport.time,'monotonic',side_effect=[1,2,3]):
            with self.assertRaises(TimeoutError):transport._read_response(stream,2.5,{},0)
    def test_stream_multiline_data(self):
        terminal=json.loads(response().getvalue())
        stream=io.BytesIO(('data: {"type":"response.completed",\ndata: "response":'+json.dumps(terminal)+'}\n\n').encode())
        stream.headers={'Content-Type':'text/event-stream'}
        self.assertEqual(transport._read_response(stream,time.monotonic()+60,{},time.monotonic()),terminal)
    def test_503_respects_retry_after(self):
        with patch.object(transport.urllib.request, 'urlopen', side_effect=[http_error(503, headers={'Retry-After':'4'}), response()]), patch.object(transport.time,'sleep') as sleep:
            self.invoke()
        self.assertGreater(sleep.call_args.args[0], 3.8)
    def test_long_retry_after_exhausts_budget_without_early_retry(self):
        with patch.object(transport.urllib.request, 'urlopen', side_effect=http_error(429, headers={'Retry-After':'600'})) as api:
            with self.assertRaises(transport.ModelRequestError): self.invoke()
        self.assertEqual(api.call_count, 1)
    def test_auth_schema_and_quota_are_not_retried(self):
        for code, provider in [(401,'invalid_api_key'),(400,'invalid_json_schema'),(429,'insufficient_quota')]:
            with self.subTest(code=code), patch.object(transport.urllib.request, 'urlopen', side_effect=http_error(code,provider)) as api:
                with self.assertRaises(transport.ModelRequestError) as ctx: self.invoke()
                self.assertEqual(api.call_count,1)
                self.assertNotIn('private', json.dumps(ctx.exception.request_metadata))
    def test_maximum_three_attempts(self):
        with patch.object(transport.urllib.request, 'urlopen', side_effect=TimeoutError()) as api:
            with self.assertRaises(transport.ModelRequestError) as ctx:self.invoke()
        self.assertEqual(api.call_count,3);self.assertEqual(len(ctx.exception.request_metadata['attempts']),3)
    def test_expired_budget_never_sends(self):
        with patch.object(transport.urllib.request, 'urlopen') as api:
            with self.assertRaises(transport.ModelRequestError):self.invoke(deadline=time.monotonic()-1)
        api.assert_not_called()
    def test_output_limit_retries_complete_response_with_larger_budget(self):
        with patch.object(transport.urllib.request,'urlopen',side_effect=[response(status='incomplete',incomplete_details={'reason':'max_output_tokens'}),response()]) as api:
            self.invoke()
        self.assertEqual([json.loads(c.args[0].data)['max_output_tokens'] for c in api.call_args_list],[16000,32000])
    def test_filter_or_refusal_not_retried_or_parsed(self):
        for stream in [response(status='incomplete',incomplete_details={'reason':'content_filter'}),response(output=[{'content':[{'type':'refusal'}]}])]:
            with patch.object(transport.urllib.request,'urlopen',return_value=stream) as api:
                with self.assertRaises(transport.ModelRequestError):self.invoke()
                self.assertEqual(api.call_count,1)
    def test_checkpoint_resume_skips_completed_generation_and_retries_only_review(self):
        entries={};saved=[]
        with transport.request_journal(entries,lambda:saved.append(copy.deepcopy(entries))):
            with patch.object(transport.urllib.request,'urlopen',side_effect=[response(),KeyboardInterrupt()]) as api:
                self.invoke('draft')
                with self.assertRaises(KeyboardInterrupt):self.invoke('review')
            # Simulate process recovery from the durable journal, not in-memory state.
        entries=copy.deepcopy(saved[-1])
        with transport.request_journal(entries,lambda:None), patch.object(transport.urllib.request,'urlopen',return_value=response()) as api:
            _,meta=self.invoke('draft');self.invoke('review')
        self.assertTrue(meta['checkpoint_reused']);self.assertEqual(api.call_count,1)
        self.assertTrue(all(json.loads(c.args[0].data)['store'] is False for c in api.call_args_list))
    def test_different_input_not_reused(self):
        entries={}
        with transport.request_journal(entries,lambda:None), patch.object(transport.urllib.request,'urlopen',side_effect=[response(),response()]) as api:
            self.invoke('one');self.invoke('two')
        self.assertEqual(api.call_count,2)


class RecoveryTests(unittest.TestCase):
    def test_failure_messages_distinguish_output_contract_from_service_interruption(self):
        self.assertIn('纠正后的结果',failure_message('model_review_contract_invalid: evidence'))
        self.assertIn('有限重试',failure_message('model_provider_temporary_error'))
        self.assertIn('模型服务返回处理失败',failure_message('model_provider_failed'))
        for code in ['model_review_contract_invalid','model_provider_failed','model_provider_temporary_error']:
            self.assertIn('没有写入日历',failure_message(code))
    def test_worker_crash_in_model_recovers_same_task_without_calendar_replay(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ,OPENAI_API_KEY='test'):
            folder=Path(tmp);q=job('queued');calls=[]
            def rpc(method,p):calls.append(method);return q
            def crash(_):raise KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt):Worker(folder,model=crash,transport=rpc).process(q,{})
            w=Worker(folder,model=lambda _: (envelope(),{'review':{'status':'passed'}}),transport=rpc)
            w.process(q,{})
            doc=json.loads((folder/'ax-test.json').read_text())
            self.assertEqual(doc['model_runs']['parse'],2)
            self.assertIn('plan_store',calls);self.assertNotIn('plan_execute',calls)
            self.assertFalse(w.can_resume_model(doc,'parse'))


if __name__=='__main__':unittest.main()
