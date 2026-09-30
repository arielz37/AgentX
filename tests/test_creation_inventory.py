import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import agentx_model as model
from creation_inventory import extract_inventory, validate_coverage
from fixtures import job, envelope


def inventory():
    return dict(overflow=False,items=[dict(item_id=f'i{i}',title=f'事项{i}',evidence='整理书架') for i in range(1,9)])


def eight():
    r=envelope();r['plan']['items']=[copy.deepcopy(r['plan']['items'][0]) for _ in range(8)]
    for i,item in enumerate(r['plan']['items'],1):item['item_id']=f'i{i}'
    return r


class InventoryTests(unittest.TestCase):
    def test_plan_cannot_silently_drop_seven_items(self):
        with self.assertRaisesRegex(ValueError,'every inventory item'):validate_coverage(envelope(),inventory())
        validate_coverage(eight(),inventory())
    def test_wrong_initial_count_does_not_lock_generation_or_review_schema(self):
        j={**job(),'_creation_inventory':inventory()}
        for s in [model.envelope_schema(j)['properties']['response'],model.review_schema(j)['properties']['corrected_response']]:
            creation=next(v for v in s['anyOf'] if v.get('properties',{}).get('route',{}).get('properties',{}).get('kind',{}).get('enum')==['calendar'])
            items=creation['properties']['plan']['properties']['items']
            self.assertEqual(items['maxItems'],8)
            self.assertLess(items.get('minItems',0),8)
    def test_false_pass_on_missing_items_returns_error_to_model_once(self):
        corrected=dict(decision='correct',issues=[dict(item_id=None,field='items',reason='恢复全部事项')],corrected_inventory=None,corrected_response=eight())
        with patch('agentx_model.base.request_json',side_effect=[({'response':envelope()},{}),
                   (dict(decision='pass',issues=[],corrected_inventory=None,corrected_response=None),{}),(corrected,{})]) as api:
            result,meta=model.parse(job(),inventory_model=lambda *_:(inventory(),{}))
        self.assertEqual(len(result['plan']['items']),8)
        self.assertEqual(api.call_count,3)
        for n in (1,2):
            payload=json.loads(api.call_args_list[n].args[0][1]['content'])
            self.assertIn('every inventory item',payload['candidate_contract_checks']['validation_error'])
        self.assertEqual(meta['creation_inventory'],inventory())
    def test_reviewer_can_merge_attributes_and_restore_missing_activity(self):
        initial=inventory();corrected_inventory=dict(overflow=False,items=initial['items'][:5])
        corrected_plan=eight();corrected_plan['plan']['items']=corrected_plan['plan']['items'][:5]
        review=dict(decision='correct',issues=[dict(item_id=None,field='inventory',reason='备注链接归活动，补回时间未知事项')],
                    corrected_response=corrected_plan,corrected_inventory=corrected_inventory)
        with patch('agentx_model.base.request_json',side_effect=[({'response':eight()},{}),(review,{})]):
            result,meta=model.parse(job(),inventory_model=lambda *_:(initial,{}))
        self.assertEqual(len(result['plan']['items']),5)
        self.assertEqual(meta['creation_inventory'],initial)
        self.assertEqual(meta['final_creation_inventory'],corrected_inventory)
    def test_corrected_inventory_cannot_hide_omitted_plan_items(self):
        revised=inventory();revised['items']=revised['items'][:5]
        bad=dict(decision='correct',issues=[dict(item_id=None,field='inventory',reason='修订')],
                 corrected_inventory=revised,corrected_response=envelope())
        fixed=copy.deepcopy(bad);fixed['corrected_response']=eight();fixed['corrected_response']['plan']['items']=fixed['corrected_response']['plan']['items'][:5]
        with patch('agentx_model.base.request_json',side_effect=[({'response':eight()},{}),(bad,{}),(fixed,{})]) as api:
            result,meta=model.parse(job(),inventory_model=lambda *_:(inventory(),{}))
        self.assertEqual(len(result['plan']['items']),5)
        self.assertEqual(meta['reviews'][0]['status'],'invalid')
        self.assertEqual(api.call_count,3)
    def test_inventory_is_generated_without_a_candidate_to_bias_count(self):
        with patch('creation_inventory.base.request_json',side_effect=[(inventory(),{}),({'overflow':False,'activities':inventory()['items'],'attributes':[],'changes':[]},{})]) as api:
            value,_=extract_inventory(job(),123)
        payload=json.loads(api.call_args_list[0].args[0][1]['content'])
        self.assertEqual(set(payload),{'current_request','conversation_context'})
        self.assertEqual(value,inventory())
        self.assertEqual(api.call_count,2)
        self.assertEqual(len({c.args[3] for c in api.call_args_list}),1)
        schema=api.call_args.args[1]
        self.assertTrue(all(quote in job()['text'] for quote in schema['$defs']['source_quote']['enum']))
    def test_inventory_audit_can_reduce_wrong_count_before_planning(self):
        corrected=inventory();corrected['items']=corrected['items'][:5]
        with patch('creation_inventory.base.request_json',side_effect=[(inventory(),{}),({'overflow':False,'activities':corrected['items'],'attributes':[],'changes':['合并活动附属说明，保留未知时间活动']},{})]):
            value,meta=extract_inventory(job(),123)
        self.assertEqual(len(value['items']),5)
        self.assertEqual(len(meta['initial_inventory']['items']),8)
    def test_audit_attributes_bind_to_activity_without_creating_more_items(self):
        activity={'title':'整理书架','evidence':'整理书架'}
        audited=dict(overflow=False,activities=[activity],attributes=[dict(activity_index=1,field='alerts',evidence='不用提醒')],changes=['纠正活动清单'])
        with patch('creation_inventory.base.request_json',side_effect=[(inventory(),{}),(audited,{})]):
            result,_=extract_inventory(job(),123)
        self.assertEqual(result['items'],[dict(activity,item_id='i1')])
        audited['attributes'][0]['activity_index']=2
        with patch('creation_inventory.base.request_json',side_effect=[(inventory(),{}),(audited,{})]):
            with self.assertRaisesRegex(ValueError,'attribute binding'):extract_inventory(job(),123)
    def test_invalid_review_inventory_ids_get_targeted_repair(self):
        invalid=inventory();invalid['items'][3]['item_id']='i3'
        first=dict(decision='correct',issues=[dict(item_id=None,field='inventory',reason='修复清单')],corrected_inventory=invalid,corrected_response=eight())
        second=copy.deepcopy(first);second['corrected_inventory']=inventory()
        with patch('agentx_model.base.request_json',side_effect=[({'response':eight()},{}),(first,{}),(second,{})]) as api:
            result,meta=model.parse(job(),inventory_model=lambda *_:(inventory(),{}))
        self.assertEqual(len(result['plan']['items']),8)
        sent=json.loads(api.call_args_list[-1].args[0][1]['content'])
        self.assertEqual(sent['previous_invalid_review']['validation_error'],'Invalid creation inventory item')
        self.assertEqual(meta['reviews'][0]['status'],'invalid')


if __name__=='__main__':unittest.main()
