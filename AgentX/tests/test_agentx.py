import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from agentx_model import parse, validate, envelope_schema
from agentx_worker import Worker, identity
from agentx_config import PORT, ROOT
from calendar_task import call
from fixtures import job, plan, route, envelope

class RouteTests(unittest.TestCase):
    def test_four_route_contracts(self):
        for kind in ('calendar','mixed','unsupported','clarify'):validate(envelope(kind),job())
    def test_no_plan_allowed_on_unsupported_mixed_or_unclear(self):
        for kind in ('mixed','unsupported','clarify'):
            p=envelope(kind);p['plan']=plan()
            with self.assertRaises(ValueError):validate(p,job())
    def test_no_arbitrary_module_or_rpc(self):
        for key,value in [('kind','open_app'),('supported',['sms'])]:
            p=envelope();p['route'][key]=value
            with self.assertRaises(ValueError):validate(p,job())
        j=job();j['assistant_id']='sms'
        with self.assertRaises(ValueError):parse(j)
    def test_partial_calendar_information_stays_calendar(self):
        p=envelope();p['plan']['items'][0]['fields']['start_at']=dict(value=None,source='unresolved',evidence=None,reason='关键事实未知',critical=True,blocks_creation=True)
        validate(p,job())
    def test_schema_keeps_calendar_and_no_reverted_timing_compiler(self):
        s=envelope_schema(job()); props=s['properties']['response']['anyOf'][0]['properties']['plan']['properties']['items']['items']['properties']
        self.assertIn('calendar',props);self.assertIn('alerts',props);self.assertNotIn('timing',props)
    def parse_mock(self,draft,review):
        with patch('agentx_model.base.request_json',side_effect=[({'response':draft},{}),(review,{})]) as api:
            result,meta=parse(job())
            self.assertEqual(api.call_count,2)
            self.assertEqual(api.call_args_list[0].args[3],api.call_args_list[1].args[3])
            second=api.call_args_list[1].args[0]
            self.assertEqual(len(second),2)
            self.assertEqual(json.loads(second[1]['content'])['original_text'],job()['text'])
            return result,meta
    def test_route_and_plan_review_in_one_independent_call(self):
        p=envelope();r,m=self.parse_mock(p,dict(decision='pass',issues=[],corrected_response=None))
        self.assertEqual(r,p);self.assertEqual(m['review']['status'],'passed')
    def test_review_can_correct_bad_route_before_write(self):
        r,m=self.parse_mock(envelope(),dict(decision='correct',issues=[dict(item_id=None,field='route',reason='用户请求发送邮件')],corrected_response=envelope('unsupported')))
        self.assertIsNone(r['plan']);self.assertEqual(m['review']['status'],'corrected')
    def test_failed_blocked_or_inconsistent_review_never_passes(self):
        for decision,issues,corrected in [('block',[dict(item_id=None,field='route',reason='不明确')],None),('correct',[],envelope()),('pass',[],envelope())]:
            with self.assertRaises(ValueError):self.parse_mock(envelope(),dict(decision=decision,issues=issues,corrected_response=corrected))
    def test_invalid_corrected_calendar_is_not_repaired_silently(self):
        p=envelope();p['plan']['items'][0]['fields']['start_at']['critical']=True
        with self.assertRaises(ValueError):self.parse_mock(envelope(),dict(decision='correct',issues=[dict(item_id='i1',field='start_at',reason='错误')],corrected_response=p))
    def test_timeout_rejects_and_preserves_draft(self):
        with patch('agentx_model.base.request_json',side_effect=[({'response':envelope()},{}),RuntimeError('model_timeout')]):
            with self.assertRaises(RuntimeError) as ctx:parse(job())
            self.assertEqual(ctx.exception.model_metadata['review']['status'],'failed')

class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.directory=Path(self.temp.name);self.calls=[]
    def tearDown(self):self.temp.cleanup()
    def transport(self,m,p):
        self.calls.append((m,p));return job()
    def worker(self,kind):
        return Worker(self.directory,model=lambda _: (envelope(kind),{'review':{'status':'passed'}}),transport=self.transport)
    def test_calendar_stored_before_fresh_host_poll_then_one_execute(self):
        w=self.worker('calendar')
        with patch.dict(os.environ,OPENAI_API_KEY='test-placeholder'):w.process(job('queued'),{'can_execute':True})
        self.assertEqual([c[0] for c in self.calls],['plan_claim','plan_store'])
        w.process(job(),{'can_execute':True});w.process(job(),{'can_execute':True})
        self.assertEqual([c[0] for c in self.calls].count('plan_execute'),1)
        self.assertEqual(self.calls[1][1]['assistant_id'],'auto')
    def test_noncalendar_never_stores_or_executes_events(self):
        for kind in ('unsupported','mixed','clarify'):
            with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ,OPENAI_API_KEY='test-placeholder'):
                w=self.worker(kind);w.directory=Path(tmp);self.calls.clear()
                w.process(job('queued'),{'can_execute':True})
                self.assertEqual([c[0] for c in self.calls],['plan_claim','plan_route'])
    def test_low_disk_blocks_before_model_or_execution(self):
        with patch.dict(os.environ,OPENAI_API_KEY='test-placeholder'), patch('agentx_worker.shutil.disk_usage',return_value=Mock(free=1)):
            self.worker('calendar').process(job('queued'),{'can_execute':True})
        self.assertEqual([c[0] for c in self.calls],['plan_fail'])
        self.assertIn('磁盘',self.calls[0][1]['message'])
    def test_interrupted_parse_is_not_misreported_as_known_worker_restart(self):
        q=job('queued')
        (self.directory/'ax-test.json').write_text(json.dumps({'request':{k:q[k] for k in ('submission_id','task_id','version','assistant_id','text','submitted_at','time_zone','test_mode')},'attempts':{},'parse_started':'2030-09-27T12:00:00Z'}))
        self.worker('calendar').process(q,{})
        self.assertEqual([c[0] for c in self.calls],['plan_fail'])
        self.assertIn('结果未保存',self.calls[0][1]['message'])
    def test_model_failure_distinct_from_scope_mismatch(self):
        def fail(_):raise RuntimeError('model_timeout')
        with patch.dict(os.environ,OPENAI_API_KEY='test-placeholder'):
            Worker(self.directory,model=fail,transport=self.transport).process(job('queued'),{})
        self.assertEqual([c[0] for c in self.calls],['plan_claim','plan_fail'])
    def test_request_id_content_and_scope_are_immutable(self):
        w=self.worker('calendar');w.process(job(),{})
        for key,value in [('text','另一个任务'),('assistant_id','calendar')]:
            changed=job();changed[key]=value
            with self.assertRaises(ValueError):w.process(changed,{})
    def test_lost_response_not_replayed_across_worker_restart(self):
        def lost(m,p):self.calls.append(m);raise OSError('lost response')
        Worker(self.directory,transport=lost).process(job(),{'can_execute':True})
        Worker(self.directory,transport=lost).process(job(),{'can_execute':True})
        self.assertEqual(self.calls,['plan_execute'])
    def test_only_acknowledged_no_write_deferral_retries(self):
        def deferred(m,p):
            self.calls.append(m)
            return dict(job(),execution_deferred=len(self.calls)==1,deferred_reason='application_transition_no_writes')
        w=Worker(self.directory,transport=deferred)
        for _ in range(3):w.process(job(),{'can_execute':True})
        self.assertEqual(len(self.calls),2)
    def test_navigation_or_terminal_poll_cannot_execute(self):
        w=self.worker('calendar')
        for state in ('verified','partial','not_completed','unknown','failed','unsupported','scope_mismatch','needs_clarification','mixed','window_expired'):
            w.process(job(state),{'can_execute':True})
        self.assertEqual(self.calls,[])
    def test_expired_budget_never_executes(self):
        self.worker('calendar').process(job(),{'can_execute':False});self.assertEqual(self.calls,[])
    def test_identity_includes_module(self):self.assertEqual(identity(job())['assistant_id'],'auto')

class IsolationTests(unittest.TestCase):
    def test_transport_port_identity_and_no_legacy_fallback(self):
        with patch('calendar_task.rpc.rpc_call',return_value={'result':{'app_id':'agentx','protocol_version':1}}) as rpc:
            call('calendar_status',{});args=rpc.call_args.args
            self.assertEqual(args[1],PORT);self.assertNotEqual(PORT,45678)
            self.assertEqual(args[2]['params']['client'],'agentx')
        for result in [{},{'app_id':'wellphone','protocol_version':1},{'app_id':'agentx','protocol_version':2}]:
            with patch('calendar_task.rpc.rpc_call',return_value={'result':result}) as rpc:
                with self.assertRaises(RuntimeError):call('plan_poll',{})
                self.assertEqual(rpc.call_count,1)
    def test_launcher_paths_separate_and_foreign_process_not_reused(self):
        import start_agentx as s
        self.assertEqual(s.RUNTIME,ROOT/'.runtime');self.assertEqual(s.WORKER,ROOT/'scripts/agentx_worker.py')
        self.assertFalse(s.is_forwarder_command('python3 /old/PhoneAgent/forward_rpc_localhost.py --udid fake',ROOT,s.FORWARDER,{'fake'}))
        self.assertTrue(s.is_forwarder_command('python3 scripts/vendor/forward_rpc_localhost.py --udid fake',ROOT,s.FORWARDER,{'fake'}))
    def test_foreign_port_conflict_does_not_kill_services(self):
        import start_agentx as s
        with patch('start_agentx.socket.socket') as sock, patch('start_agentx.run') as run:
            sock.return_value.__enter__.return_value.bind.side_effect=OSError('occupied');run.return_value.stdout=''
            with self.assertRaises(s.StartupError):s.forwarder_running({'hardwareProperties':{'udid':'fake'}})
    def test_worker_lock_path_is_independent(self):
        import start_agentx as s
        with patch('start_agentx.lock_file',return_value=None) as lock:
            self.assertTrue(s.worker_running());self.assertEqual(lock.call_args.args[0],ROOT/'data/.worker.lock')

if __name__=='__main__':unittest.main()
