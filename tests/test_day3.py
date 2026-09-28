import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from wellphone_model import validate, parse, FIELDS, normalize_context_evidence, schema_for_text
from wellphone_worker import Worker


def field(value, source='inferred', critical=False, blocks=False):
    return dict(value=value, source=source, evidence=None, reason='根据提交上下文', critical=critical, blocks_creation=blocks)

def plan():
    return {'overflow': False, 'items': [{'item_id': 'i1', 'kind': 'flexible', 'fields': dict(
        title=field('整理房间'), start_at=field('2030-09-28T14:00:00+08:00', 'defaulted'),
        end_at=field('2030-09-28T15:00:00+08:00', 'defaulted'), time_zone=field('Asia/Shanghai'),
        location=field(None, 'unresolved'))}]}

def job(state='planned'):
    return dict(submission_id='task-1', task_id='task-1', version=1, text='明天整理房间', submitted_at='2030-09-27T12:00:00Z',
                time_zone='Asia/Shanghai', test_mode=True, lease_id='lease-1', state=state, message='', plan=plan())

class ContractTests(unittest.TestCase):
    def test_flexible_and_optional_missing(self): validate(plan(), job())
    def test_critical_missing_is_retained(self):
        p = plan(); p['items'][0]['fields']['start_at'] = field(None, 'unresolved', True, True)
        validate(p, job())
    def test_provenance_rejections(self):
        for change in [dict(source='explicit'), dict(critical=True), dict(evidence='不在原文'), dict(value=None), dict(blocks_creation=True)]:
            p = plan(); p['items'][0]['fields']['start_at'].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError): validate(p, job())
    def test_overflow_and_duplicate(self):
        for p in [{'overflow': True, 'items': plan()['items']}, {'overflow': False, 'items': plan()['items'] * 9}, {'overflow': False, 'items': plan()['items'] * 2}]:
            with self.assertRaises(ValueError): validate(p, job())
    def test_context_evidence_normalization_is_narrow_and_audited(self):
        p=plan(); f=p['items'][0]['fields']['time_zone']
        f.update(source='explicit', evidence='Asia/Shanghai')
        changes=normalize_context_evidence(p, job())
        self.assertEqual(len(changes), 1); self.assertEqual(changes[0]['original']['source'], 'explicit')
        self.assertIsNone(f['evidence']); self.assertEqual(f['source'], 'inferred'); validate(p, job())
        p['items'][0]['fields']['title']['evidence']='invented quotation'
        normalize_context_evidence(p,job())
        with self.assertRaises(ValueError): validate(p,job())
    def test_evidence_enum_can_only_quote_original_text(self):
        text='明天9点到10点练琴，下午散步。'
        schema=schema_for_text(text)
        quotes=schema['$defs']['source_quote']['enum']
        self.assertTrue(all(q in text for q in quotes))
        self.assertNotIn('下午4点到5点', quotes)
        long_text='自然语言计划'*500
        self.assertTrue(all(q in long_text for q in schema_for_text(long_text)['$defs']['source_quote']['enum']))
    def test_four_candidates(self):
        p = plan(); p['items'] = [dict(copy.deepcopy(p['items'][0]), item_id='i' + str(i)) for i in range(1,5)]
        validate(p, job())
    def test_refusal_incomplete_and_http(self):
        import io
        from urllib.error import HTTPError
        with patch.dict(os.environ, OPENAI_API_KEY='unit-test-placeholder'):
            for response in [{'status':'incomplete'}, {'status':'completed','output':[{'content':[{'type':'refusal'}]}]}]:
                with patch('urllib.request.urlopen', return_value=io.BytesIO(json.dumps(response).encode())):
                    with self.assertRaises(RuntimeError): parse(job())
            with patch('urllib.request.urlopen', side_effect=HTTPError('url', 401, 'bad', {}, None)):
                with self.assertRaisesRegex(RuntimeError, 'HTTP 401'): parse(job())

class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.directory = Path(self.temp.name); self.calls=[]
    def tearDown(self): self.temp.cleanup()
    def transport(self, method, params):
        self.calls.append(method)
        if method == 'plan_execute': raise OSError('lost response')
        return job()
    def test_lost_response_not_retried_even_after_restart(self):
        worker = Worker(self.directory, transport=self.transport)
        worker.process(job(), {'can_execute': True})
        Worker(self.directory, transport=self.transport).process(job(), {'can_execute': True})
        self.assertEqual(self.calls.count('plan_execute'), 1)
        doc=json.loads((self.directory/'task-1.json').read_text())
        self.assertEqual(doc['attempts']['lease-1']['status'], 'sent_result_unknown')
    def test_expired_or_ineligible_never_sends(self):
        worker = Worker(self.directory, transport=self.transport)
        worker.process(job('window_expired'), {'can_execute': True})
        worker.process(job(), {'can_execute': False})
        self.assertNotIn('plan_execute', self.calls)
    def test_foreground_eligible_sends(self):
        worker=Worker(self.directory, transport=self.transport)
        worker.process(job(), {'can_execute':True, 'application_state':'foreground'})
        self.assertEqual(self.calls.count('plan_execute'),1)
    def test_only_acknowledged_transition_deferral_can_retry(self):
        def transport(method, params):
            self.calls.append(method)
            if self.calls.count('plan_execute')==1:
                return {**job(), 'execution_deferred':True, 'deferred_reason':'application_transition_no_writes'}
            return {**job('verified'), 'execution':{'status':'verified','items':[]}}
        worker=Worker(self.directory, transport=transport)
        worker.process(job(), {'can_execute':True, 'application_state':'foreground'})
        worker.process(job(), {'can_execute':False, 'application_state':'inactive'})
        worker.process(job(), {'can_execute':True, 'application_state':'background'})
        worker.process(job(), {'can_execute':True})
        self.assertEqual(self.calls.count('plan_execute'),2)
    def test_content_conflict(self):
        worker = Worker(self.directory, transport=self.transport); worker.process(job(), {})
        changed=job(); changed['text']='另一个输入'
        with self.assertRaises(ValueError): worker.process(changed, {})
    def test_real_report_overrules_pending_attempt(self):
        worker=Worker(self.directory, transport=self.transport); worker.process(job(), {'can_execute':True})
        completed=job('verified'); completed['execution']={'items':[{'item_id':'i1','status':'verified','save_status':'saved','verification_status':'verified'}]}
        worker.process(completed, {})
        self.assertIn('verified', (self.directory/'task-1.md').read_text())
    def test_slow_model_cannot_use_stale_budget(self):
        queued=job('queued'); queued.pop('plan')
        worker=Worker(self.directory, model=lambda _: (plan(), {'model':'test-double'}), transport=self.transport)
        with patch.dict(os.environ, OPENAI_API_KEY='test-placeholder'):
            worker.process(queued, {'can_execute':True})
        self.assertNotIn('plan_execute', self.calls)
        self.assertEqual(self.calls, ['plan_claim', 'plan_store'])


class ForwardingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import importlib.util
        path = Path(__file__).resolve().parents[1] / 'PhoneAgent/.agents/skills/phoneagent/scripts/forward_rpc_localhost.py'
        spec=importlib.util.spec_from_file_location('wellphone_forwarder_test', path)
        cls.forwarder=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.forwarder)
    def setUp(self): self.forwarder._SUCCESSFUL_HOSTS.clear()
    def test_successful_route_cached(self):
        f=self.forwarder
        with patch.object(f, '_coredevice_candidates', return_value=['observed-host']) as discovery, patch.object(f, '_try_connect', return_value=Mock(getpeername=lambda: ('fd00::1',45678,0,0))) as connect:
            f.connect_remote('device',45678,2); f.connect_remote('device',45678,2)
        self.assertEqual(discovery.call_count,1)
        self.assertEqual(connect.call_args_list[1].args[0], 'fd00::1')
    def test_failed_cache_rediscovered(self):
        f=self.forwarder; f._SUCCESSFUL_HOSTS[('device',45678)]='old-host'
        with patch.object(f, '_coredevice_candidates', return_value=['new-host']) as discovery, patch.object(f, '_try_connect', side_effect=[None,Mock(getpeername=lambda: ('fd00::2',45678,0,12))]):
            f.connect_remote('device',45678,2)
        self.assertEqual(discovery.call_count,1)
        self.assertEqual(f._SUCCESSFUL_HOSTS[('device',45678)],'fd00::2%12')

if __name__ == '__main__': unittest.main()
