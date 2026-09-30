import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import calendar_mutation as mutation
import calendar_query
import calendar_schedule
import agentx_model
from agentx_worker import Worker
from test_calendar_schedule import job as schedule_job,decision as schedule_decision
from answer_fixtures import tool_context

def job():
    j=schedule_job();j.update(version=7,state='mutation_pending',text='把刚才那个改到下午四点',mutation_source_id='mutation-1')
    j['query']['mode']='events';j['query'].update(slot_kind='timed',duration_days=1)
    j['route']['kind']='calendar_mutation';j['conversation_context']=[dict(text='创建整理书架',response='已保存',state='verified',events=[dict(title='AgentX Test 整理书架',start_at='2030-10-02T14:00:00+08:00',end_at='2030-10-02T15:00:00+08:00')])]
    return j

def context():
    return dict(tool_name='calendar_mutation_candidates',source_id='mutation-1',query=job()['query'],queried_at='2030-09-30T12:00:00Z',candidates=[dict(target_ref='candidate-1',title='AgentX Test 整理书架',start_at='2030-10-02T14:00:00+08:00',end_at='2030-10-02T15:00:00+08:00',time_zone='Asia/Shanghai',is_all_day=False,calendar_name='Synthetic',writable=True,recurring=False)])

def decision():
    p={k:None for k in mutation.PATCH_FIELDS};p.update(start_at='2030-10-02T16:00:00+08:00',end_at='2030-10-02T17:00:00+08:00')
    return dict(source_id='mutation-1',decision='execute',message='准备修改时间',actions=[dict(item_id='i1',target_ref='candidate-1',operation='update',scope='this_event',patch=p)])

class CalendarV7Tests(unittest.TestCase):
    def test_selected_time_schema_discloses_provenance(self):
        d=calendar_schedule.schema(schedule_job())
        fields=d["properties"]["plan"]["anyOf"][0]["properties"]["items"]["items"]["properties"]["fields"]["properties"]
        for name in ("start_at","end_at"):
            self.assertEqual([x["properties"]["source"]["enum"] for x in fields[name]["anyOf"]],[["defaulted"]])

    def test_all_day_ignores_legacy_timed_limit(self):
        j=job();j['query'].update(mode='free_slots',slot_kind='all_day',duration_minutes=480,day_start_minute=0,day_end_minute=1440)
        j['text']='整理书架不用提醒';j['schedule_request']['items'][0]['evidence']='整理书架'
        route={**j['route'],'kind':'calendar_schedule'}
        agentx_model.validate(dict(route=route,plan=None,query=j['query'],schedule_request=j['schedule_request']),j)
        j['query']['slot_kind']='timed'
        with self.assertRaises(ValueError):agentx_model.validate(dict(route=route,plan=None,query=j['query'],schedule_request=j['schedule_request']),j)

    def test_year_bounds(self):
        q=job()['query']
        for a,b,valid in [('2027-03-01','2028-03-01',True),('2028-02-29','2029-02-28',True),('2028-02-29','2029-03-01',False)]:
            q.update(start_at=a+'T00:00:00+08:00',end_at=b+'T00:00:00+08:00')
            if valid:calendar_query.validate(q)
            else:
                with self.assertRaises(ValueError):calendar_query.validate(q)

    def test_mutation_source_target_and_scope(self):
        mutation.validate(decision(),job(),context())
        for field,value in [('target_ref','fake'),('scope','future_events'),('operation','create')]:
            d=decision();d['actions'][0][field]=value
            with self.assertRaises(ValueError):mutation.validate(d,job(),context())
        c=context();c['candidates'][0]['writable']=False
        with self.assertRaises(ValueError):mutation.validate(decision(),job(),c)
        d=decision();d['decision']='needs_clarification'
        with self.assertRaises(ValueError):mutation.validate(d,job(),context())
        d['actions']=[];mutation.validate(d,job(),context())

    def test_identical_candidates_need_link_or_clarification(self):
        c=context();duplicate=copy.deepcopy(c['candidates'][0]);duplicate['target_ref']='duplicate';c['candidates'].append(duplicate)
        with self.assertRaises(ValueError):mutation.validate(decision(),job(),c)
        c['candidates'][0]['related_history_refs']=['prior/i1']
        mutation.validate(decision(),job(),c)

    def test_frozen_reference_cannot_fall_back_to_old_event(self):
        j=job();j['query']['target_history_refs']=['recent/i1']
        c=context();c['query']['target_history_refs']=['recent/i1'];c['candidates'][0]['related_history_refs']=['older/i1']
        with self.assertRaises(ValueError):mutation.validate(decision(),j,c)
        self.assertEqual(mutation.schema(c)['properties']['actions']['items']['properties']['target_ref']['enum'],['no-candidates'])
        c['candidates'][0]['related_history_refs']=['recent/i1'];mutation.validate(decision(),j,c)

    def test_context_reaches_initial_and_second_models(self):
        j=job();r=dict(route=j['route'],plan=None,query=j['query'],schedule_request=None)
        agentx_model.validate(r,j)
        with patch('agentx_model.base.request_json',side_effect=[({'response':r},{}),(dict(decision='pass',issues=[],corrected_inventory=None,corrected_response=None),{})]) as api:
            agentx_model.parse(j, inventory_model=lambda *_: ({'overflow':False,'items':[]},{}))
        first=api.call_args_list[0].args[0][0]['content']
        self.assertIn('conversation_context',first)
        with patch('calendar_mutation.base.request_json',side_effect=[(decision(),{}),(dict(decision='pass',reason='',corrected=None),{})]) as api:
            result,_=mutation.decide(j,context())
        self.assertEqual(result,decision())
        first=json.loads(api.call_args_list[0].args[0][1]['content'])
        self.assertEqual(first['conversation_context'],j['conversation_context'])

    def test_store_retry_does_not_remodel_or_write(self):
        calls=[];models=[]
        def rpc(m,p):calls.append(m);raise TimeoutError()
        def model(*args):models.append(1);return decision(),{}
        with tempfile.TemporaryDirectory() as tmp,patch.dict(os.environ,OPENAI_API_KEY='fixture'),patch('builtins.print'):
            w=Worker(Path(tmp),transport=rpc,mutation_model=model)
            path=Path(tmp)/(job()['submission_id']+'.json')
            path.write_text(json.dumps(dict(request={},attempts={},mutation_context=context())))
            for _ in range(2):
                with self.assertRaises(TimeoutError):w.process(job(),dict(can_execute=True))
            self.assertEqual(len(models),1);self.assertEqual(calls,['plan_mutation_store','plan_mutation_store'])

    def test_unknown_write_never_replayed_and_expired_never_sent(self):
        j=job();j.update(state='planned',mutation=decision());calls=[]
        def rpc(m,p):calls.append(m);raise TimeoutError()
        with tempfile.TemporaryDirectory() as tmp,patch('builtins.print'):
            w=Worker(Path(tmp),transport=rpc)
            w.process(j,dict(can_execute=False));self.assertEqual(calls,[])
            w.process(j,dict(can_execute=True));w.process(j,dict(can_execute=True))
            self.assertEqual(calls,['plan_execute'])

    def test_all_day_schedule_requires_actual_whole_day(self):
        j=schedule_job();j.update(version=7,text='10月2日到4日找一个整天空闲日整理书架，不用提醒。')
        j['schedule_request']['items'][0]['evidence']='整理书架'
        q=j['query'];q.update(start_at='2030-10-02T00:00:00+08:00',end_at='2030-10-05T00:00:00+08:00',slot_kind='all_day',duration_days=1,day_start_minute=0,day_end_minute=1440)
        d=schedule_decision();item=d['plan']['items'][0];item['calendar']['is_all_day']=True
        item['fields']['start_at']['value']='2030-10-03T00:00:00+08:00';item['fields']['end_at']['value']='2030-10-04T00:00:00+08:00'
        c=tool_context();c['result']['request']=copy.deepcopy(q);c['result']['free_slots']=[dict(start_at='2030-10-03T00:00:00+08:00',end_at='2030-10-04T00:00:00+08:00')]
        calendar_schedule.validate(d,j,c)
        item['fields']['start_at']['value']='2030-10-03T09:00:00+08:00'
        with self.assertRaises(ValueError):calendar_schedule.validate(d,j,c)
