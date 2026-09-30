import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from agentx_worker import Worker
from tool_answer import answer_from_tool, bounded_execution_context, validate_answer_review, answer_review_schema
from fixtures import job


def inputs():
    j=job('partial');j.update(version=8,completion_source_id='actual-result-1',completion_answer_state='pending',
        route={'kind':'calendar'},conversation_context=[{'text':'unrelated history, must not send'}])
    rows=[dict(item_id='i1',status='verified',save_status='saved',verification_status='verified'),
          dict(item_id='i2',status='saved_unverified',save_status='saved',verification_status='failed'),
          dict(item_id='i3',status='failed',save_status='not_attempted',verification_status='not_attempted')]
    j['execution']={'status':'partial','items':rows}
    c=dict(source_id=j['completion_source_id'],tool_name='calendar_execution',status='partial',time_zone='Asia/Shanghai',result=copy.deepcopy(j['execution']))
    return j,c


def reviewed(text, ctx, decision='correct'):
    claims=[{k:r.get(k) for k in ('item_id','status','save_status','verification_status')} | {'answer_claim':text} for r in ctx['result']['items']]
    return {'review':dict(decision=decision,reason='逐项核对接口结果',corrected_answer=text if decision=='correct' else None,claims=claims)}


class CompletionAnswerTests(unittest.TestCase):
    def test_context_matches_actual_rows_and_never_opts_in_old_jobs(self):
        j,c=inputs();bounded_execution_context(j,c)
        for change in ('old','source','omit','status'):
            job,ctx=copy.deepcopy(j),copy.deepcopy(c)
            if change=='old':job['version']=7
            if change=='source':ctx['source_id']='other'
            if change=='omit':ctx['result']['items'].pop()
            if change=='status':ctx['result']['items'][1]['status']='verified'
            with self.assertRaises(ValueError):bounded_execution_context(job,ctx)
    def test_actual_result_goes_to_model_then_independent_review_without_history(self):
        j,c=inputs();raw='都好了';correct='第一件完成了，第二件已保存但还没核验，第三件没添加。'
        replies=[({'answer':raw},{'model':'test'}),(reviewed(correct,c),{})]
        with patch('tool_answer.base.request_json',side_effect=replies) as api:
            a,m=answer_from_tool(j,c)
        self.assertEqual(a['text'],correct)
        for call in api.call_args_list:
            payload=json.loads(call.args[0][1]['content'])
            self.assertEqual(payload['tool_result'],c)
            self.assertNotIn('conversation_context',payload)
            self.assertNotIn('本轮未新增、删除',call.args[0][0]['content'])
    def test_invalid_correct_null_is_repaired_once_with_shared_deadline(self):
        j,c=inputs();correct='第一件完成，第二件已保存但未核验，第三件没有添加。'
        bad={'review':dict(decision='correct',reason='没有问题',corrected_answer=None,claims=[])}
        with patch('tool_answer.base.request_json',side_effect=[({'answer':'全部成功'},{'model':'test'}),(bad,{}),(reviewed(correct,c),{})]) as api:
            a,m=answer_from_tool(j,c)
        self.assertEqual(a['text'],correct);self.assertEqual(api.call_count,3)
        self.assertEqual(len({x.args[3] for x in api.call_args_list}),1)
        self.assertEqual(api.call_args_list[-1].args[2],'agentx_answer_review_repair')
        repair=json.loads(api.call_args_list[-1].args[0][1]['content'])['previous_review_to_repair']
        self.assertIn('inconsistent_decision',repair['validation_error'])
        self.assertEqual(len(m['reviews']),2)
    def test_false_success_claim_omission_and_empty_claim_are_rejected(self):
        j,c=inputs()
        for change in ('status','omit','quote','duplicate'):
            value=reviewed('真实答复',c)
            rows=value['review']['claims']
            if change=='status':rows[2]['save_status']='saved'
            if change=='omit':rows.pop()
            if change=='quote':rows[0]['answer_claim']=''
            if change=='duplicate':rows[1]=rows[0]
            with self.assertRaises(ValueError):validate_answer_review(value,'候选',c,True)
    def test_repair_exhaustion_keeps_evidence_and_never_returns_bad_answer(self):
        j,c=inputs();bad=reviewed('都好了',c);bad['review']['claims'][2]['save_status']='saved'
        with patch('tool_answer.base.request_json',side_effect=[({'answer':'都好了'},{'model':'test'}),(bad,{}),(bad,{})]) as api:
            with self.assertRaisesRegex(ValueError,'answer_review_repair_exhausted') as caught:answer_from_tool(j,c)
        self.assertEqual(api.call_count,3)
        self.assertEqual(len(caught.exception.model_metadata['reviews']),2)
        self.assertEqual(caught.exception.model_metadata['draft_answer'],'都好了')
    def test_schema_correct_branch_requires_nonempty_replacement(self):
        branches=answer_review_schema(True)['properties']['review']['anyOf']
        correct=next(v for v in branches if v['properties']['decision']['enum']==['correct'])
        self.assertEqual(correct['properties']['corrected_answer']['type'],'string')
        self.assertEqual(correct['properties']['corrected_answer']['minLength'],1)
    def test_user_retry_archives_failure_and_only_regenerates_answer(self):
        j,c=inputs();calls=[];attempts=[]
        answer=dict(text='真实答复',source_id=c['source_id'],model='test',generated_at='2030-01-01T00:00:00Z')
        def rpc(method,p):
            calls.append((method,p))
            if method.endswith('_context'):return c
            return j
        def model(*_):
            attempts.append(1)
            if len(attempts)==1:raise ValueError('answer_review_repair_exhausted')
            return answer,{}
        with tempfile.TemporaryDirectory() as tmp,patch.dict(os.environ,OPENAI_API_KEY='test'):
            w=Worker(Path(tmp),answer_model=model,transport=rpc);w.process(j,{})
            j['completion_answer_state']='failed';w.process(j,{})
            self.assertEqual(len(attempts),1)
            j.update(completion_answer_state='pending',answer_retry_id='user-request-2');w.process(j,{})
            doc=json.loads(next(Path(tmp).glob('*.json')).read_text())
        self.assertEqual(len(attempts),2)
        self.assertEqual([m for m,p in calls],['plan_completion_context','plan_completion_fail','plan_completion_store'])
        self.assertEqual(calls[-1][1]['answer_retry_id'],'user-request-2')
        self.assertIn('answer_error',doc['answer_attempt_history'][0])
        self.assertNotIn('answer_error',doc)
        self.assertEqual(j['execution'],c['result'])
    def test_answer_delivery_retry_never_repeats_calendar_write_or_model(self):
        j,c=inputs();calls=[];models=[]
        answer=dict(text='第一件好了，另两件见说明。',source_id=c['source_id'],model='test',generated_at='2030-01-01T00:00:00Z')
        def rpc(method,p):
            calls.append(method)
            if method=='plan_completion_context':return c
            if calls.count('plan_completion_store')==1:raise TimeoutError()
            return {**j,'answer':answer,'completion_answer_state':'complete'}
        def model(*args):models.append(args);return answer,{}
        with tempfile.TemporaryDirectory() as tmp,patch.dict(os.environ,OPENAI_API_KEY='test'):
            w=Worker(Path(tmp),answer_model=model,transport=rpc)
            with self.assertRaises(TimeoutError):w.process(j,{})
            w.process(j,{})
        self.assertEqual(len(models),1)
        self.assertEqual(calls,['plan_completion_context','plan_completion_store','plan_completion_store'])
    def test_model_failure_preserves_execution_and_only_sends_answer_failure(self):
        j,c=inputs();calls=[]
        def rpc(method,p):calls.append(method);return c if method.endswith('_context') else j
        def fail(*_):raise ValueError('Model answer review did not pass')
        with tempfile.TemporaryDirectory() as tmp,patch.dict(os.environ,OPENAI_API_KEY='test'):
            Worker(Path(tmp),answer_model=fail,transport=rpc).process(j,{})
        self.assertEqual(calls,['plan_completion_context','plan_completion_fail'])
        self.assertEqual(j['execution']['items'][1]['save_status'],'saved')


if __name__=='__main__':unittest.main()
