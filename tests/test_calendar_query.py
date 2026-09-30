import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
import calendar_query as query
from agentx_model import parse, validate, envelope_schema
from agentx_worker import Worker
from fixtures import job, envelope

def request():
    return dict(mode='free_slots', start_at='2030-09-28T00:00:00+08:00', end_at='2030-09-29T00:00:00+08:00',
                time_zone='Asia/Shanghai', duration_minutes=60, day_start_minute=540, day_end_minute=1260, assumptions=['默认每天9–21点'])

def response():
    return dict(route=dict(kind='calendar_query', message='将查询指定范围', supported=['calendar'], unsupported=[]), plan=None, query=request())

def submission(state='queued'):
    j=job(state);j.update(version=4,text='明天找一个小时的空档')
    if state=='planned':
        j.pop('plan',None);j.update(query=request(),route=response()['route'])
    return j

class QueryTests(unittest.TestCase):
    def test_limits_offsets_and_unknown_fields(self):
        query.validate(request())
        for key,value in [('duration_minutes',True),('duration_minutes',481),('day_end_minute',500),
                          ('end_at','2031-09-29T00:00:00+08:00'),('start_at','2030-09-28T00:00:00Z'),
                          ('time_zone','Imaginary/Place'),('mode','delete'),('extra','injection')]:
            q=request();q[key]=value
            with self.assertRaises(ValueError):query.validate(q)

    def test_dst_fold_compares_instants(self):
        q=request();q.update(time_zone='America/New_York',start_at='2030-11-03T01:45:00-04:00',end_at='2030-11-03T01:15:00-05:00')
        query.validate(q)
        q['start_at'],q['end_at']=q['end_at'],q['start_at']
        with self.assertRaises(ValueError):query.validate(q)

    def test_review_receives_literal_window_and_offset_error(self):
        q=request();q.update(day_start_minute=14,day_end_minute=18,start_at='2030-09-27T16:00:00Z')
        facts=query.review_facts(q)
        self.assertEqual(facts['day_start_minute_as_clock'],'00:14')
        self.assertEqual(facts['start_at_local'],'2030-09-28T00:00:00+08:00')
        self.assertIn('validation_error',facts)

    def test_route_exclusivity_and_legacy(self):
        validate(response(),submission())
        v5=submission();v5['version']=5;validate(response(),v5)
        with self.assertRaises(ValueError):validate(response(),job())
        bad=response();bad['plan']=envelope()['plan']
        with self.assertRaises(ValueError):validate(bad,submission())
        for kind in ('calendar','unsupported','mixed','clarify'):
            j=job();j['version']=4
            r=envelope(kind);r['query']=None;validate(r,j)
            r['query']=request()
            with self.assertRaises(ValueError):validate(r,submission())
        self.assertEqual(len(envelope_schema(submission())['properties']['response']['anyOf']),5)

    def test_query_gets_two_model_calls_without_calendar_contents(self):
        j=submission();j['queryResult']={'title':'PRIVATE_SENTINEL'}
        with patch('agentx_model.base.request_json',side_effect=[({'response':response()},{}),
                  (dict(decision='pass',issues=[],corrected_inventory=None,corrected_response=None),{})]) as api:
            r,meta=parse(j, inventory_model=lambda *_: ({'overflow':False,'items':[]},{}))
        self.assertEqual(r,response());self.assertEqual(meta['review']['status'],'passed')
        self.assertEqual(api.call_count,2)
        for call in api.call_args_list:self.assertNotIn('PRIVATE_SENTINEL',json.dumps(call.args[0]))

    def test_query_storage_then_execute_once_and_stop(self):
        calls=[]
        def transport(method,params):calls.append((method,params));return submission('planned')
        with tempfile.TemporaryDirectory() as folder,patch.dict(os.environ,OPENAI_API_KEY='test-placeholder'):
            w=Worker(Path(folder),model=lambda _: (response(),{'review':{'status':'passed'}}),transport=transport)
            w.process(submission(),{'can_execute':True})
            self.assertEqual([c[0] for c in calls],['plan_claim','plan_store'])
            self.assertIsNone(calls[-1][1]['plan'])
            w.process(submission('planned'),{'can_execute':True})
            w.process(submission('planned'),{'can_execute':True})
            w.process(submission('query_complete'),{'can_execute':True})
            self.assertEqual([c[0] for c in calls].count('plan_execute'),1)
            self.assertNotIn('calendar_execute',[c[0] for c in calls])

if __name__=='__main__':unittest.main()
