#!/usr/bin/env python3
"""Replay the reported eight-event case and its frozen history; no phone tools."""
import argparse
import copy
import datetime as dt
import json
from pathlib import Path
import time
from unittest.mock import patch
from agentx_config import ROOT, load_model_env
import agentx_model
from model_transport import request_journal


def checks_for(result, metadata):
    items=(result.get('plan') or {}).get('items',[])
    expected=[('2026-10-05T08:00:00+08:00','2026-10-05T09:00:00+08:00'),
              ('2026-10-05T10:00:00+08:00','2026-10-05T11:00:00+08:00'),
              ('2026-10-06T14:00:00+08:00','2026-10-06T15:00:00+08:00'),
              ('2026-10-07T00:00:00+08:00','2026-10-08T00:00:00+08:00'),
              ('2026-10-08T00:00:00+08:00','2026-10-10T00:00:00+08:00'),
              ('2026-10-10T23:00:00+08:00','2026-10-11T01:00:00+08:00'),
              ('2026-10-05T07:00:00+08:00','2026-10-05T08:00:00+08:00'),
              ('2026-10-11T15:00:00+08:00','2026-10-11T16:00:00+08:00')]
    checks={'creation_route':result['route']['kind']=='calendar','all_eight_items':len(items)==8,
            'review_passed':metadata['review']['status'] in ('passed','corrected')}
    if len(items)==8:
        stamp=lambda s:dt.datetime.fromisoformat(s.replace('Z','+00:00'))
        checks['specified_dates_times_kept']=all(stamp(i['fields']['start_at']['value'])==stamp(a) and stamp(i['fields']['end_at']['value'])==stamp(b) for i,(a,b) in zip(items,expected))
        checks['all_day_and_two_day_span']=[i['calendar']['is_all_day'] for i in items]==[False,False,False,True,True,False,False,False]
        series=items[6]['calendar']['recurrence']
        checks['weekly_four_occurrences']=series['mode']=='repeat' and series['frequency']=='weekly' and series['count']==4
        checks['interview_two_reminders']=sorted(i['offset_seconds'] for i in items[1]['alerts']['items'])==[-86400,-7200]
        checks['other_six_no_reminders']=all(items[i]['alerts']['mode']=='disabled' for i in [0,2,3,4,5,6])
        checks['piano_adaptive_reminder']=items[7]['alerts']['mode']=='suggested'
        checks['notes_and_link']='项目演示' in (items[1]['calendar']['notes'] or '') and items[2]['calendar']['url']=='https://example.com/project'
    return checks


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--record',type=Path,required=True);p.add_argument('--live',action='store_true');args=p.parse_args()
    if not args.live:raise SystemExit('Use --live to send this task and its already-shared history to the configured model.')
    record=json.loads(args.record.read_text());job=copy.deepcopy(record['request'])
    job['conversation_context']=record['phone'].get('conversation_context',[])
    old_draft=record['model']['draft'];load_model_env();rows=[]
    original=agentx_model.base.request_json
    for case in ['recorded_wrong_draft','full_actual_context_1','full_actual_context_2']:
        checkpoints={};started=time.monotonic()
        def request(messages,schema,name,deadline):
            if case=='recorded_wrong_draft' and name=='agentx_routed_plan':
                return {'response':copy.deepcopy(old_draft)},{'replayed_recorded_draft':True}
            return original(messages,schema,name,deadline)
        try:
            with patch('agentx_model.base.request_json',side_effect=request),request_journal(checkpoints,lambda:None):
                result,meta=agentx_model.parse(job)
            checks=checks_for(result,meta)
            row=dict(case=case,passed=all(checks.values()),checks=checks,elapsed_seconds=round(time.monotonic()-started,3),
                     initial_route=meta['draft']['route']['kind'],final_route=result['route']['kind'],review_status=meta['review']['status'],review_rounds=len(meta['reviews']))
            private=dict(request=job,result=result,metadata=meta)
        except Exception as e:
            row=dict(case=case,passed=False,error=str(e),elapsed_seconds=round(time.monotonic()-started,3))
            private=dict(request=job,metadata=getattr(e,'model_metadata',{}),
                         request_error=getattr(e,'request_metadata',{}),error=str(e))
        private['model_checkpoints']=checkpoints
        # Raw local artifacts contain real conversation context; never Git.
        (ROOT/'artifacts'/('routing-replay-'+case+'.json')).write_text(json.dumps(private,ensure_ascii=False,indent=2)+'\n')
        rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
        (ROOT/'evidence/context-routing-replay.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
    if not all(row['passed'] for row in rows):raise SystemExit(1)


if __name__=='__main__':main()
