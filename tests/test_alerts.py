import copy
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from alert_contract import validate_alerts
from wellphone_model import validate, schema_for_text
from wellphone_worker import markdown
from test_day3 import plan, job


def alerts(mode='explicit', offsets=(-86400, -7200)):
    return dict(mode=mode, evidence='要求' if mode != 'suggested' else None, reason='测试理由',
                count_limit=0 if mode == 'disabled' else None, no_extra=True, overflow=False,
                items=[dict(alert_id=f'a{i+1}', trigger_type='relative', offset_seconds=o, at=None,
                            source='defaulted' if mode == 'suggested' else 'explicit', evidence='要求', reason='测试理由') for i,o in enumerate(offsets)])


class AlertsContractTests(unittest.TestCase):
    def test_explicit_one_two_none_suggested(self):
        for mode, values in [('explicit', (-86400,)), ('explicit', (-7200,)), ('explicit', (-86400,-7200)), ('disabled',()), ('suggested',()), ('suggested',(-600,)), ('suggested',(-86400,-600)), ('unresolved',())]:
            with self.subTest(mode=mode, values=values): validate_alerts(alerts(mode,values), '要求')
    def test_provenance_and_shape(self):
        for mutation in [{'no_extra':False}, {'evidence':'虚假引文'}, {'mode':'disabled'}, {'overflow':True}, {'count_limit':True}]:
            a=alerts(); a.update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): validate_alerts(a,'要求')
        a=alerts(); a['items'][0]['source']='defaulted'
        with self.assertRaises(ValueError): validate_alerts(a,'要求')
        a=alerts(); a['items'][1]['alert_id']='a1'
        with self.assertRaises(ValueError): validate_alerts(a,'要求')
    def test_absolute_and_excess_requests_retained_for_phone_policy(self):
        a=alerts(offsets=(-1,-2,-3)); validate_alerts(a,'要求')
        a['items'][0].update(trigger_type='absolute',offset_seconds=None,at='2030-09-28T09:00:00+08:00')
        validate_alerts(a,'要求')
    def test_v1_v2_and_missing_event_time(self):
        p=plan(); j=job(); validate(p,j)
        j.update(version=2, text='要求')
        with self.assertRaises(ValueError): validate(p,j)
        p['items'][0]['alerts']=alerts(); validate(p,j)
        p['items'][0]['fields']['start_at'].update(value=None,source='unresolved',blocks_creation=True)
        validate(p,j) # reminder intention retained, event stays blocked
        j['version']=1
        with self.assertRaises(ValueError): validate(p,j) # no new reminders in legacy jobs
    def test_schema_quotes_new_only(self):
        legacy=schema_for_text('要求')
        current=schema_for_text('要求',include_alerts=True)
        self.assertNotIn('alerts',legacy['properties']['items']['items']['properties'])
        a=current['properties']['items']['items']['properties']['alerts']
        self.assertEqual(a['properties']['items']['maxItems'],16)
        self.assertIn('$ref',a['properties']['evidence'])
    def test_report_cannot_claim_partial_is_complete(self):
        j=job('partial');j['plan']['items'][0]['alerts']=alerts()
        j['execution']={'items':[{'item_id':'i1','status':'partial','save_status':'saved','verification_status':'verified', 'event_verification_status':'verified',
            'alerts':{'requested':alerts(),'configured':[],'decisions':[{'code':'past_reminder'}], 'verification_status':'verified','user_requirement_status':'unmet'}}]}
        text=markdown({'phone':j})
        self.assertIn('用户提醒要求满足：unmet',text)
        self.assertIn('提醒配置成功不等于未来通知已送达',text)
        self.assertIn('past_reminder',text)
    def test_legacy_report_labels_history(self):
        self.assertIn('历史无提醒计划', markdown({'phone':job()}))
