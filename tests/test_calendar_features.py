import copy
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from calendar_features import validate
from wellphone_model import schema_for_text, validate as validate_plan
from test_day3 import plan, job

TEXT = '每周五早上游泳，共四次，带泳镜，https://example.com/swim'

def features():
    return dict(is_all_day=False, notes='带泳镜', url='https://example.com/swim', reason='来自原文', unsupported=[],
        recurrence=dict(mode='repeat', frequency='weekly', interval=1, weekdays=[5], month_days=[], months=[],
            end_type='count', count=4, until=None, evidence='每周五早上游泳', reason='每周五，共四次'))

class CalendarFeaturesTests(unittest.TestCase):
    def test_weekly_and_multiple_days_and_until(self):
        validate(features(), TEXT)
        f=features();r=f['recurrence'];r.update(interval=2,weekdays=[2,4],end_type='until',count=None,until='2030-12-31')
        validate(f,TEXT)

    def test_frequency_shapes(self):
        for frequency, days, months in [('daily',[],[]),('monthly',[-1],[]),('yearly',[29],[2])]:
            f=features();f['recurrence'].update(frequency=frequency,weekdays=[],month_days=days,months=months)
            validate(f,TEXT)

    def test_reject_invalid_or_ambiguous_rules(self):
        for changes in [dict(weekdays=[]),dict(weekdays=[5,5]),dict(weekdays=[0]),dict(interval=True),
                        dict(month_days=[1]),dict(count=0),dict(until='2030-01-01'),dict(evidence=None),
                        dict(end_type='until',count=None,until='2030-02-30'),dict(mode='none'),dict(frequency='lunar')]:
            f=features();f['recurrence'].update(changes)
            with self.subTest(changes=changes),self.assertRaises(ValueError): validate(f,TEXT)

    def test_url_cannot_be_invented_or_launch_another_app(self):
        for url in ['https://invented.example.com', 'shortcuts://run-shortcut', 'https://user:pass@example.com', 'https://example.com/a b']:
            f=features();f['url']=url
            with self.subTest(url=url),self.assertRaises(ValueError): validate(f,TEXT+' '+url if 'invented' not in url else TEXT)

    def test_none_and_unsupported_do_not_create_a_fake_rule(self):
        for mode in ('none','unresolved'):
            f=features();f['recurrence'].update(mode=mode,frequency=None,interval=1,weekdays=[],end_type='never',count=None)
            validate(f,TEXT)

    def test_schema_version_and_legacy_plan(self):
        self.assertNotIn('calendar', schema_for_text(TEXT,True)['properties']['items']['items']['properties'])
        self.assertIn('calendar', schema_for_text(TEXT,True,True)['properties']['items']['items']['required'])
        validate_plan(plan(),job())
        p=plan();p['items'][0]['calendar']=features()
        with self.assertRaises(ValueError):validate_plan(p,job())

if __name__=='__main__':unittest.main()
