import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import calendar_schedule as schedule
import agentx_model
from agentx_worker import Worker
from fixtures import plan
from answer_fixtures import query_job,tool_context

def job():
    j=query_job();j.update(version=6,state='schedule_pending',text='10月2日下午两点到六点找空档帮我安排一小时整理书架，不用提醒。',
        route=dict(kind='calendar_schedule',message='先查询再排程',supported=['calendar'],unsupported=[]))
    j['schedule_request']=dict(time_authority='self_directed',reason='自行整理可以自由选时',items=[dict(item_id='i1',title='整理书架',evidence='安排一小时整理书架')])
    return j

def decision():
    p=plan();f=p['items'][0]['fields'];f['start_at']['value']='2030-10-02T16:00:00+08:00';f['end_at']['value']='2030-10-02T17:00:00+08:00'
    return dict(source_id='snapshot-1',decision='scheduled',message='建议在已有安排之后整理一小时；具体时间由空档自动选择，尚未保存。',plan=p)

class ScheduleTests(unittest.TestCase):
    def test_routing_requires_new_version_and_only_reads_first(self):
        j=job();r=dict(route=j['route'],query=j['query'],plan=None,schedule_request=j['schedule_request'])
        agentx_model.validate(r,j)
        self.assertEqual(len(agentx_model.envelope_schema(j)['properties']['response']['anyOf']),6)
        for version in (3,4,5):
            old={**j,'version':version}
            with self.assertRaises(ValueError):agentx_model.validate(r,old)
        r['plan']=decision()['plan']
        with self.assertRaises(ValueError):agentx_model.validate(r,j)
        self.assertNotIn('当前不支持一步',agentx_model.routing_rules(j))

    def test_manifest_rejects_external_time_and_omissions(self):
        j=job();j['schedule_request']['time_authority']='external_unknown'
        with self.assertRaises(ValueError):schedule.validate(decision(),j,tool_context())
        j=job();j['schedule_request']['items'].append(dict(item_id='i2',title='整理书架',evidence='整理书架'))
        with self.assertRaises(ValueError):schedule.validate(decision(),j,tool_context())
        j=job();j['schedule_request']['items'][0]['evidence']='接口里已有的一件事'
        with self.assertRaises(ValueError):schedule.validate(decision(),j,tool_context())

    def test_query_review_can_correct_a_mistaken_route_to_creation(self):
        j=job();r=dict(route=j['route'],query=j['query'],plan=None,schedule_request=j['schedule_request'])
        with patch('agentx_model.base.request_json',side_effect=[({'response':r},{}),
                   (dict(decision='pass',issues=[],corrected_inventory=None,corrected_response=None),{})]) as api:
            final,_=agentx_model.parse(j, inventory_model=lambda *_: ({'overflow':False,'items':[]},{}))
        self.assertEqual(final,r)
        review_schema=api.call_args_list[1].args[1]
        variants=review_schema['properties']['corrected_response']['anyOf'][:-1]
        creation=next(x for x in variants if x['properties']['route']['properties']['kind']['enum']==['calendar'])
        self.assertIn('items',creation['properties']['plan']['properties'])
        self.assertIn('source_quote',review_schema['$defs'])

    def test_choice_must_fit_real_slot_and_duration(self):
        schedule.validate(decision(),job(),tool_context())
        for start,end in [('15:00:00','16:00:00'),('14:30:00','15:30:00'),('16:00:00','18:00:00'),('18:00:00','19:00:00')]:
            d=decision();f=d['plan']['items'][0]['fields'];f['start_at']['value']='2030-10-02T'+start+'+08:00';f['end_at']['value']='2030-10-02T'+end+'+08:00'
            with self.assertRaises(ValueError):schedule.validate(d,job(),tool_context())
        d=decision();d['source_id']='stale'
        with self.assertRaises(ValueError):schedule.validate(d,job(),tool_context())

    def test_multi_item_overlap_and_adjacent(self):
        d=decision();other=copy.deepcopy(d['plan']['items'][0]);other['item_id']='i2';d['plan']['items'].append(other)
        j=job();j['schedule_request']['items'].append(dict(item_id='i2',title='整理书架',evidence='整理书架'))
        with self.assertRaises(ValueError):schedule.validate(d,j,tool_context())
        other['fields']['start_at']['value']='2030-10-02T17:00:00+08:00';other['fields']['end_at']['value']='2030-10-02T18:00:00+08:00'
        j=job();j['schedule_request']['items'].append(dict(item_id='i2',title='整理书架',evidence='整理书架'))
        schedule.validate(d,j,tool_context())
        other['calendar']['is_all_day']=True
        with self.assertRaises(ValueError):schedule.validate(d,job(),tool_context())

    def test_no_slots_no_plan_and_provenance(self):
        ctx=tool_context();ctx['result']['free_slots']=[]
        with self.assertRaises(ValueError):schedule.validate(decision(),job(),ctx)
        d=dict(source_id='snapshot-1',decision='no_slot',message='没有找到符合条件的空档，没有创建。',plan=None)
        schedule.validate(d,job(),ctx)
        d=decision();d['plan']['items'][0]['fields']['start_at']['source']='inferred'
        with self.assertRaises(ValueError):schedule.validate(d,job(),tool_context())

    def test_model_gets_original_and_tool_data_then_reviews(self):
        d=decision()
        with patch('calendar_schedule.base.request_json',side_effect=[(d,{'model':'fixture'}),
                   (dict(decision='pass',reason='',corrected_schedule=None),{})]) as api:
            final,meta=schedule.schedule_from_tool(job(),tool_context())
        self.assertEqual(final,d);self.assertEqual(api.call_count,2)
        first=json.loads(api.call_args_list[0].args[0][1]['content'])
        self.assertEqual(first['original_request'],job()['text'])
        self.assertEqual(first['tool_result']['result']['free_slots'][1]['start_at'],'2030-10-02T16:00:00+08:00')
        self.assertIn('国庆假期',json.dumps(first,ensure_ascii=False))

    def test_store_retry_uses_durable_decision_without_remodelling(self):
        calls=[]
        def rpc(m,p):calls.append(m);raise TimeoutError()
        model=lambda *_:(decision(),{})
        with tempfile.TemporaryDirectory() as folder,patch.dict(os.environ,OPENAI_API_KEY='fixture'):
            with patch('builtins.print'):
                w=Worker(Path(folder),transport=rpc,schedule_model=model)
                with self.assertRaises(TimeoutError):w.process(job(),{'can_execute':True})
                doc=json.loads(next(Path(folder).glob('*.json')).read_text())
                # First timeout fetching readonly context is safe to retry.
                doc['answer_context']=tool_context();w.save(next(Path(folder).glob('*.json')),doc)
                with self.assertRaises(TimeoutError):w.process(job(),{'can_execute':True})
                def forbidden(*_):raise AssertionError('must not call model again')
                w.schedule_model=forbidden
                with self.assertRaises(TimeoutError):w.process(job(),{'can_execute':True})
                doc=json.loads(next(Path(folder).glob('*.json')).read_text())
                self.assertEqual(doc['schedule'],decision())
                self.assertNotIn('plan_execute',calls)

    def test_read_then_store_then_fresh_poll_write_once(self):
        calls=[];j=job()
        def rpc(m,p):
            calls.append(m)
            if m=='plan_answer_context':return tool_context()
            if m=='plan_schedule_store':return {**j,'state':'planned','schedule':p['schedule'],'plan':p['schedule']['plan']}
            if m=='plan_execute':raise TimeoutError('lost write response')
            raise AssertionError(m)
        with tempfile.TemporaryDirectory() as folder,patch.dict(os.environ,OPENAI_API_KEY='fixture'):
            w=Worker(Path(folder),transport=rpc,schedule_model=lambda *_:(decision(),{}))
            w.process(j,{'can_execute':True})
            self.assertEqual(calls,['plan_answer_context','plan_schedule_store'])
            ready={**j,'state':'planned','schedule':decision(),'plan':decision()['plan']}
            w.process(ready,{'can_execute':False});self.assertNotIn('plan_execute',calls)
            w.process(ready,{'can_execute':True});w.process(ready,{'can_execute':True})
            Worker(Path(folder),transport=rpc).process(ready,{'can_execute':True})
            self.assertEqual(calls.count('plan_execute'),1)

    def test_swift_omits_null_fields_but_write_phase_still_runs(self):
        def swift_wire(value):
            if isinstance(value,dict):return {k:swift_wire(v) for k,v in value.items() if v is not None}
            if isinstance(value,list):return [swift_wire(v) for v in value]
            return value
        calls=[];j=job()
        ready=swift_wire({**j,'state':'planned','schedule':decision(),'plan':decision()['plan']})
        def rpc(m,p):
            calls.append(m)
            if m=='plan_answer_context':return tool_context()
            if m=='plan_schedule_store':return ready
            if m=='plan_execute':return {**ready,'state':'verified','execution':{'items':[]}}
            raise AssertionError(m)
        with tempfile.TemporaryDirectory() as folder,patch.dict(os.environ,OPENAI_API_KEY='fixture'):
            w=Worker(Path(folder),transport=rpc,schedule_model=lambda *_:(decision(),{}))
            w.process(j,{'can_execute':True})
            report=next(Path(folder).glob('*.md')).read_text()
            self.assertIn('location：空缺',report)
            w.process(ready,{'can_execute':True})
            self.assertEqual(calls.count('plan_execute'),1)

    def test_secondary_report_failure_never_stops_durable_execution(self):
        j={**job(),'state':'planned','schedule':decision(),'plan':decision()['plan']}
        calls=[]
        with tempfile.TemporaryDirectory() as folder:
            w=Worker(Path(folder),transport=lambda m,p:(calls.append(m) or {**j,'state':'verified','execution':{'items':[]}}))
            with patch('agentx_worker.markdown',side_effect=KeyError('optional field')):
                w.process(j,{'can_execute':True})
            doc=json.loads(next(Path(folder).glob('*.json')).read_text())
            self.assertEqual(calls,['plan_execute'])
            self.assertEqual(doc['phone']['state'],'verified')
            self.assertEqual(doc['report_error'],'KeyError')
            w.save(next(Path(folder).glob('*.json')),doc)
            self.assertNotIn('report_error',doc)

    def test_crash_during_model_fails_without_write_or_retry(self):
        calls=[]
        with tempfile.TemporaryDirectory() as folder,patch.dict(os.environ,OPENAI_API_KEY='fixture'):
            j=job();p=Path(folder)/(j['submission_id']+'.json')
            request={k:j[k] for k in ('submission_id','task_id','version','text','submitted_at','time_zone','test_mode','assistant_id')}
            p.write_text(json.dumps(dict(request=request,attempts={},schedule_started='earlier')))
            w=Worker(Path(folder),transport=lambda m,p:(calls.append(m) or {**j,'state':'schedule_failed'}),schedule_model=lambda *_:self.fail('model replay'))
            w.process(j,{'can_execute':True})
            self.assertEqual(calls,['plan_schedule_fail'])

if __name__=='__main__':unittest.main()
