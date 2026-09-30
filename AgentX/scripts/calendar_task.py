"""Identity-checked adapter over the attributed PhoneAgent RPC transport."""
import datetime as dt
from agentx_config import ROOT, PORT, APP_ID, PROTOCOL_VERSION
from vendor import rpc


def call(method, params, timeout=30):
    response = rpc.rpc_call('127.0.0.1', PORT,
        rpc.build_request(1, method, {**params, 'client': APP_ID, 'protocol_version': PROTOCOL_VERSION}),
        connect_timeout_s=3, read_timeout_s=timeout, max_bytes=1024 * 1024)
    if 'error' not in response:
        result = response.get('result', {})
        if result.get('app_id') != APP_ID or result.get('protocol_version') != PROTOCOL_VERSION:
            raise RuntimeError('AgentX protocol identity mismatch; refusing this service')
    return response


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()
