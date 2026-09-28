"""Report-only fixtures: these are not device execution evidence."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import tempfile
import json

spec = importlib.util.spec_from_file_location('calendar_task', Path(__file__).resolve().parents[1] / 'scripts/calendar_task.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ReportTests(unittest.TestCase):
    def test_wait_failure_does_not_send_calendar_task(self):
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / 'task.json'
            output = Path(directory) / 'result.json'
            request.write_text('{"session_id":"unit-only"}')
            argv = ['calendar_task.py', 'run', str(request), '--wait-for-background', '--output', str(output)]
            with patch.object(module.sys, 'argv', argv), patch.object(module, 'call', side_effect=RuntimeError('offline')) as call:
                self.assertEqual(module.main(), 1)
                call.assert_called_once_with('calendar_status', {})
            result = json.loads(output.read_text())
            self.assertEqual(result['not_sent_error'], 'offline')
            self.assertIsNone(result['mac_sent_at'])

    def test_disconnect_is_unknown_not_unsaved(self):
        text = module.report({'mac_sent_at': 't1', 'mac_received_at': 't2', 'transport_error': 'timeout'})
        self.assertIn('unknown', text)
        self.assertIn('不代表手机未保存', text)

    def test_partial_report_preserves_failure_reason(self):
        item = {'item_id': 'invalid', 'request': {}, 'status': 'failed', 'saved_at': None,
                'verified_at': None, 'deduplicated': False, 'error': {'message': 'invalid time'}}
        text = module.report({'mac_sent_at': 't1', 'mac_received_at': 't2',
                              'rpc_response': {'result': {'task_id': 'unit-only', 'status': 'partial', 'items': [item]}}})
        self.assertIn('partial', text)
        self.assertIn('invalid time', text)

    def test_rpc_rejection_remains_rejection(self):
        text = module.report({'mac_sent_at': 't1', 'mac_received_at': 't2',
                              'rpc_response': {'error': {'message': 'session_mismatch'}}})
        self.assertIn('RPC 拒绝', text)
        self.assertIn('session_mismatch', text)

if __name__ == '__main__':
    unittest.main()
