"""Regression: history-driven wrong route must not lock the reviewer out of create."""
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import agentx_model as model
from fixtures import job, envelope
from test_calendar_query import request


def submission():
    j=job('queued');j.update(version=7,assistant_id='calendar',conversation_context=[
        dict(text='上一轮完整新建计划',state='schedule_failed',response='已读取空档但模型排程失败',events=[])])
    return j


def creation():
    r=envelope();r.update(query=None,schedule_request=None);return r


def wrong_route():
    q=request();q.update(mode='conflicts',slot_kind='timed',duration_days=1,target_history_refs=[])
    return dict(route=dict(kind='calendar_mutation',message='将检查冲突后添加',supported=['calendar'],unsupported=[]),
                plan=None,query=q,schedule_request=None)


def correction(value):
    return dict(decision='correct',issues=[dict(item_id=None,field='route',reason='用户要求新建，候选误判为改删')],corrected_inventory=None,corrected_response=value)


class RoutingRecoveryTests(unittest.TestCase):
    def test_wrong_mutation_draft_can_be_corrected_to_create(self):
        with patch('agentx_model.base.request_json',side_effect=[({'response':wrong_route()},{}),(correction(creation()),{})]) as api:
            r,meta=model.parse(submission(), inventory_model=lambda *_: ({'overflow':False,'items':[]},{}))
        self.assertEqual(r,creation());self.assertEqual(meta['review']['status'],'corrected')
        schema=api.call_args_list[1].args[1]
        kinds=[v.get('properties',{}).get('route',{}).get('properties',{}).get('kind',{}).get('enum') for v in schema['properties']['corrected_response']['anyOf']]
        self.assertIn(['calendar'],kinds)
        data=json.loads(api.call_args_list[1].args[0][1]['content'])
        self.assertIn('Mutation requires',data['candidate_contract_checks']['validation_error'])
        self.assertEqual(data['reference_context']['conversation_context'],submission()['conversation_context'])
    def test_schema_couples_mode_to_route_and_evidence_to_current_text(self):
        schema=model.envelope_schema(submission());variants=schema['properties']['response']['anyOf']
        for kind,mode in [('calendar_mutation','events'),('calendar_schedule','free_slots')]:
            v=next(v for v in variants if v['properties']['route']['properties']['kind']['enum']==[kind])
            self.assertEqual(v['properties']['query']['properties']['mode']['enum'],[mode])
        evidence=v['properties']['schedule_request']['properties']['items']['items']['properties']['evidence']
        self.assertEqual(evidence,{'$ref':'#/$defs/source_quote'})
        self.assertTrue(all(q in submission()['text'] for q in schema['$defs']['source_quote']['enum']))
    def test_invalid_review_gets_one_targeted_repair_without_regeneration(self):
        bad=creation();bad['plan']['items'][0]['fields']['title']['evidence']='编造的原文'
        replies=[({'response':wrong_route()},{}),(correction(bad),{}),(correction(creation()),{})]
        with patch('agentx_model.base.request_json',side_effect=replies) as api:
            final,meta=model.parse(submission(), inventory_model=lambda *_: ({'overflow':False,'items':[]},{}))
        self.assertEqual(final,creation());self.assertEqual(api.call_count,3)
        self.assertEqual(api.call_args_list[2].args[2],'agentx_review_repair')
        self.assertEqual(len({c.args[3] for c in api.call_args_list}),1)
        repair_input=json.loads(api.call_args_list[2].args[0][1]['content'])
        self.assertIn('Evidence is not in source',repair_input['candidate_contract_checks']['validation_error'])
        self.assertEqual(meta['reviews'][0]['status'],'invalid')
        self.assertEqual(meta['review']['status'],'corrected')
    def test_legitimate_review_block_does_not_get_semantic_retry(self):
        blocked=dict(decision='block',issues=[dict(item_id=None,field='request',reason='无法确定授权')],corrected_inventory=None,corrected_response=None)
        with patch('agentx_model.base.request_json',side_effect=[({'response':wrong_route()},{}),(blocked,{})]) as api:
            with self.assertRaisesRegex(ValueError,'model_review_blocked'):model.parse(submission(), inventory_model=lambda *_: ({'overflow':False,'items':[]},{}))
        self.assertEqual(api.call_count,2)


if __name__=='__main__':unittest.main()
