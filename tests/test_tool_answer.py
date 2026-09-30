import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from tool_answer import answer_from_tool, bounded_context, local_time_context
from agentx_worker import Worker
from answer_fixtures import query_job, tool_context, model_answer

class ModelAnswerTests(unittest.TestCase):
    def test_model_sees_real_result_and_original_question(self):
        job=query_job();job['unrelated_history']={'title':'DO_NOT_UPLOAD_OLD_TASK'}
        with patch('tool_answer.base.request_json',side_effect=[({'answer':'模型根据接口写出的回答'}, {'model':'configured-model'}),
                   ({'review':{'decision':'pass','reason':'符合接口','corrected_answer':None}},{'model':'configured-model'})]) as api:
            result,_=answer_from_tool(job,tool_context())
        messages=api.call_args_list[0].args[0];payload=json.loads(messages[1]['content'])
        self.assertEqual(payload['original_request'],job['text'])
        self.assertEqual(payload['tool_result'],local_time_context(tool_context()))
        self.assertEqual(api.call_count,2)
        self.assertEqual(api.call_args_list[0].args[3],api.call_args_list[1].args[3])
        event=payload['tool_result']['result']['events'][1]
        self.assertEqual(event['start_at'],'2030-10-02T15:00:00+08:00')
        self.assertEqual(event['actual_duration_minutes'],60)
        self.assertNotIn('DO_NOT_UPLOAD_OLD_TASK',json.dumps(messages))
        self.assertEqual(result['text'],'模型根据接口写出的回答')
        self.assertEqual(result['source_id'],'snapshot-1')

    def test_answer_correction_is_model_text_not_code_rewriting(self):
        with patch('tool_answer.base.request_json',side_effect=[({'answer':'错误首稿'},{'model':'configured'}),
                  ({'review':{'decision':'correct','reason':'首稿漏看占用','corrected_answer':'模型纠正后的完整回答'}},{'model':'configured'})]):
            answer,meta=answer_from_tool(query_job(),tool_context())
        self.assertEqual(answer['text'],'模型纠正后的完整回答')
        self.assertEqual(meta['review']['decision'],'correct')

    def test_blocked_answer_is_not_displayed(self):
        with patch('tool_answer.base.request_json',side_effect=[({'answer':'候选'},{'model':'configured'}),
                  ({'review':{'decision':'block','reason':'不能确认事实','corrected_answer':None}},{'model':'configured'}),
                  ({'review':{'decision':'block','reason':'不能确认事实','corrected_answer':None}},{'model':'configured'})]):
            with self.assertRaises(ValueError):answer_from_tool(query_job(),tool_context())

    def test_legacy_incomplete_wrong_source_or_unexpected_data_rejected(self):
        for mutation in ('legacy','source','status','notes','query','too_many'):
            j=query_job();c=tool_context()
            if mutation=='legacy':j['version']=4
            if mutation=='source':c['source_id']='different'
            if mutation=='status':c['status']='failed'
            if mutation=='notes':c['result']['events'][0]['notes']='unrequested private notes'
            if mutation=='query':c['result']['request']['duration_minutes']=90
            if mutation=='too_many':c['result']['events']*=51
            with patch('tool_answer.base.request_json') as api:
                with self.assertRaises(ValueError):answer_from_tool(j,c)
                api.assert_not_called()

    def test_failure_or_invalid_model_output_has_no_template_fallback(self):
        for value in ({'answer':''},{'answer':'x'*4001},{'answer':'ok','action':'create'}):
            with patch('tool_answer.base.request_json',return_value=(value,{'model':'configured'})):
                with self.assertRaises(ValueError):answer_from_tool(query_job(),tool_context())
        with patch('tool_answer.base.request_json',side_effect=RuntimeError('network')):
            with self.assertRaises(RuntimeError):answer_from_tool(query_job(),tool_context())

class AnswerWorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.folder=Path(self.tmp.name)
        self.calls=[];self.phone=query_job();self.answer_model=Mock(return_value=(model_answer(),{'model':'test-model'}))
        self.env=patch.dict(os.environ,OPENAI_API_KEY='test-placeholder');self.env.start()
    def tearDown(self):self.env.stop();self.tmp.cleanup()
    def transport(self,m,p):
        self.calls.append(m)
        if m=='plan_answer_context':return tool_context()
        if m=='plan_answer_store':self.phone.update(answer=p['answer'],state='query_complete')
        if m=='plan_answer_fail':self.phone['state']='answer_failed'
        return copy.deepcopy(self.phone)
    def worker(self,transport=None):return Worker(self.folder,transport=transport or self.transport,answer_model=self.answer_model)
    def test_answer_after_read_even_when_execution_window_ended(self):
        w=self.worker();w.process(self.phone,{'can_execute':False});w.process(self.phone,{})
        self.assertEqual(self.calls,['plan_answer_context','plan_answer_store'])
        self.answer_model.assert_called_once()
        self.assertEqual(self.phone['answer']['text'],model_answer()['text'])
    def test_lost_delivery_only_resends_durable_answer_not_model_or_calendar(self):
        def lost(m,p):
            if m=='plan_answer_store':self.calls.append(m);raise OSError('disconnected')
            return self.transport(m,p)
        with self.assertRaises(OSError):self.worker(lost).process(self.phone,{})
        self.worker().process(self.phone,{})
        self.answer_model.assert_called_once()
        self.assertEqual(self.calls,['plan_answer_context','plan_answer_store','plan_answer_store'])
    def test_model_failure_records_read_success_and_answer_failure(self):
        self.answer_model.side_effect=RuntimeError('model_timeout')
        w=self.worker();w.process(self.phone,{});w.process(self.phone,{})
        self.assertEqual(self.phone['state'],'answer_failed')
        self.assertEqual(self.phone['execution']['status'],'query_complete')
        self.assertNotIn('answer',self.phone)
        self.answer_model.assert_called_once()
    def test_new_crashed_answer_stage_recovers_once_without_requery(self):
        def crash(*_):raise KeyboardInterrupt()
        self.answer_model.side_effect=crash
        with self.assertRaises(KeyboardInterrupt):self.worker().process(self.phone,{})
        self.answer_model.side_effect=None
        self.worker().process(self.phone,{})
        self.assertEqual(self.answer_model.call_count,2);self.assertEqual(self.phone['state'],'query_complete')
        self.assertEqual(self.calls,['plan_answer_context','plan_answer_store'])
    def test_legacy_tasks_never_export_existing_details(self):
        self.phone.update(version=4,state='query_complete');self.phone.pop('query_result_id')
        self.worker().process(self.phone,{})
        self.assertEqual(self.calls,[]);self.answer_model.assert_not_called()
    def test_user_retries_query_answer_without_reading_calendar_again(self):
        self.answer_model.side_effect=RuntimeError('answer_review_repair_exhausted')
        self.worker().process(self.phone,{})
        self.assertEqual(self.phone['state'],'answer_failed')
        self.phone.update(state='answer_pending',answer_retry_id='retry-query-only')
        self.answer_model.side_effect=None
        self.worker().process(self.phone,{})
        self.assertEqual(self.calls,['plan_answer_context','plan_answer_fail','plan_answer_store'])
        self.assertEqual(self.answer_model.call_count,2)
        self.assertEqual(self.phone['execution']['status'],'query_complete')
    def test_lost_query_response_recovers_snapshot_without_reexecuting(self):
        def lost(m,p):
            if m=='plan_execute':self.calls.append(m);raise OSError('lost execute response')
            return self.transport(m,p)
        pending=copy.deepcopy(self.phone);pending.update(state='planned');pending.pop('query_result_id');pending.pop('execution')
        self.worker(lost).process(pending,{'can_execute':True})
        self.worker().process(self.phone,{})
        self.assertEqual(self.calls.count('plan_execute'),1)
        self.assertEqual(self.calls[-2:],['plan_answer_context','plan_answer_store'])
    def test_inline_snapshot_survives_immediate_phone_suspension(self):
        def inline(m,p):
            if m=='plan_execute':
                self.calls.append(m);return dict(copy.deepcopy(self.phone),answer_context=tool_context())
            return self.transport(m,p)
        pending=copy.deepcopy(self.phone);pending.update(state='planned');pending.pop('query_result_id');pending.pop('execution')
        self.worker(inline).process(pending,{'can_execute':True})
        self.assertEqual(self.calls,['plan_execute','plan_answer_store'])
        self.answer_model.assert_called_once()
    def test_wrong_cached_snapshot_fails_without_model(self):
        def bad(m,p):
            if m=='plan_answer_context':return dict(tool_context(),source_id='other-task')
            return self.transport(m,p)
        self.worker(bad).process(self.phone,{})
        self.assertEqual(self.phone['state'],'answer_failed');self.answer_model.assert_not_called()

if __name__=='__main__':unittest.main()
