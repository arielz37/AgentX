import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from test_day3 import job, plan
from wellphone_model import parse, review_plan, reference_context, review_schema, candidate_time_facts
from wellphone_worker import Worker, markdown


def response(value):
    return io.BytesIO(json.dumps({'status': 'completed', 'model': 'test-model', 'output': [
        {'content': [{'type': 'output_text', 'text': json.dumps(value)}]}]}).encode())


def verdict(decision='pass', corrected=None):
    return {'decision': decision, 'issues': [] if decision == 'pass' else [
        {'item_id': 'i1', 'field': 'start_at', 'reason': '按原文日期修正'}], 'corrected_plan': corrected}


class ReviewTests(unittest.TestCase):
    def run_parse(self, review, candidate=None):
        with patch.dict(os.environ, OPENAI_API_KEY='test-placeholder'), patch('urllib.request.urlopen', side_effect=[response(candidate or plan()), response(review)]) as api:
            final, meta = parse(job())
            self.assertEqual(api.call_count, 2)
            sent = [json.loads(c.args[0].data) for c in api.call_args_list]
            self.assertNotIn('previous_response_id', sent[1])
            self.assertEqual(json.loads(sent[1]['input'][1]['content'])['original_text'], job()['text'])
            self.assertLessEqual(api.call_args_list[1].kwargs['timeout'], api.call_args_list[0].kwargs['timeout'])
            return final, meta

    def test_pass_preserves_every_field_and_audits(self):
        final, meta = self.run_parse(verdict())
        self.assertEqual(final, plan()); self.assertEqual(meta['draft'], plan())
        self.assertEqual(meta['review']['status'], 'passed'); self.assertEqual(meta['review']['changes'], [])

    def test_correct_only_changes_proposed_fields(self):
        corrected = plan(); corrected['items'][0]['fields']['start_at']['value'] = '2030-09-28T13:00:00+08:00'
        final, meta = self.run_parse(verdict('correct', corrected))
        self.assertEqual(final, corrected)
        self.assertEqual(meta['review']['changes'][0]['path'], '/items/0/fields/start_at/value')

    def test_block_and_contradictory_verdict_never_return_plan(self):
        for review in [verdict('block'), verdict('pass', plan()), verdict('correct', plan()), verdict('correct'), {'decision': 'pass', 'issues': 'invalid', 'corrected_plan': None}]:
            with self.subTest(review=review), self.assertRaises(ValueError): self.run_parse(review)

    def test_corrected_plan_still_requires_original_contract(self):
        corrected = plan(); corrected['items'][0]['fields']['location']['value'] = 'invented'
        with self.assertRaises(ValueError): self.run_parse(verdict('correct', corrected))

    def test_review_can_fix_invalid_draft_provenance(self):
        draft = plan(); draft['items'][0]['fields']['title']['evidence'] = '不存在的原文'
        final, _ = self.run_parse(verdict('correct', plan()), draft)
        self.assertEqual(final, plan())

    def test_critical_missing_is_not_forced_to_a_date(self):
        corrected = plan()
        for name in ['start_at', 'end_at']:
            corrected['items'][0]['fields'][name].update(value=None, source='unresolved', critical=True, blocks_creation=True)
        final, _ = self.run_parse(verdict('correct', corrected))
        self.assertIsNone(final['items'][0]['fields']['start_at']['value'])

    def test_timeout_failure_preserves_draft_for_diagnosis(self):
        with patch.dict(os.environ, OPENAI_API_KEY='test-placeholder'), patch('urllib.request.urlopen', side_effect=[response(plan()), TimeoutError()]):
            with self.assertRaises(RuntimeError) as caught: parse(job())
        self.assertEqual(caught.exception.rejected_plan, plan())
        self.assertEqual(caught.exception.model_metadata['review']['status'], 'failed')

    def test_budget_expired_never_starts_second_request(self):
        with patch.dict(os.environ, OPENAI_API_KEY='test-placeholder'), patch('urllib.request.urlopen', return_value=response(plan())) as api, patch('wellphone_model.time.monotonic', side_effect=[0, 0, 1, 2, 23, 23, 23, 23]):
            with self.assertRaisesRegex(RuntimeError, 'budget_exhausted'): parse(job(), timeout=22)
        self.assertEqual(api.call_count, 1)

    def test_empty_plan_not_passed(self):
        with self.assertRaisesRegex(ValueError, 'empty_plan'): self.run_parse(verdict(), {'overflow': False, 'items': []})

    def test_reference_uses_local_submission_not_current_date(self):
        j=job();j.update(submitted_at='2026-09-27T16:01:00Z')
        c=reference_context(j)
        self.assertEqual(c['this_week_monday'], '2026-09-28');self.assertEqual(c['next_week_monday'], '2026-10-05')
        j['submitted_at']='2026-09-29T10:32:32Z';c=reference_context(j)
        self.assertEqual(c['next_week_sunday'], '2026-10-11')
        j['submitted_at']='2026-09-29T10:32:32'
        with self.assertRaises(ValueError): reference_context(j)

    def test_same_day_future_fact_and_missing_field(self):
        from check_model_review import fixture
        j,d=fixture();facts=candidate_time_facts(d,j)
        self.assertTrue(facts[0]['start_after_submission'])
        self.assertEqual(facts[0]['seconds_after_submission'],5*3600)
        self.assertEqual(facts[0]['start_iso_weekday'],2)
        d['items'][0]['fields']['start_at']['value']=None
        self.assertIn('unavailable',candidate_time_facts(d,j)[0]['comparison'])

    def test_review_refusal_and_incomplete_never_return_draft(self):
        for second in [{'status':'incomplete'}, {'status':'completed','output':[{'content':[{'type':'refusal'}]}]}]:
            with self.subTest(second=second), patch.dict(os.environ, OPENAI_API_KEY='test-placeholder'), patch('urllib.request.urlopen', side_effect=[response(plan()),io.BytesIO(json.dumps(second).encode())]):
                with self.assertRaises(RuntimeError) as caught:parse(job())
                self.assertEqual(caught.exception.model_metadata['review']['status'],'failed')

    def test_schema_definitions_available_to_nested_plan(self):
        j=job();j['version']=3
        s=review_schema(j)
        self.assertIn('source_quote', s['$defs'])
        props=s['properties']['corrected_plan']['anyOf'][0]['properties']['items']['items']['properties']
        self.assertIn('calendar',props);self.assertIn('alerts',props)
        self.assertNotIn('timing',props)

    def test_worker_never_stores_or_executes_review_failure(self):
        calls=[];queued=job('queued');queued.pop('plan')
        def fail(_):
            error=RuntimeError('model_review_blocked')
            error.model_metadata={'draft':plan(),'review':{'status':'blocked'}}
            error.rejected_plan=plan();raise error
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, OPENAI_API_KEY='test-placeholder'):
            worker=Worker(Path(tmp),model=fail,transport=lambda m,p: calls.append(m) or queued)
            worker.process(queued,{'can_execute':True})
            self.assertEqual(calls,['plan_claim','plan_fail'])
            d=json.loads((Path(tmp)/'task-1.json').read_text());self.assertIn('blocked',markdown(d))
            self.assertNotIn('plan',d)

if __name__=='__main__':unittest.main()
