#!/usr/bin/env python3
"""Synthetic eight-event inference replay. No phone connection or calendar writes."""
import argparse
import json
import time
from unittest.mock import patch
import urllib.request
from agentx_config import ROOT, load_model_env
from agentx_model import parse
from model_transport import request_journal

TEXT = ('帮我把这些事记一下。下周一早上八点到九点读书，十点到十一点线上面试，面试提前一天和两小时各提醒一次，'
        '备注记得准备项目演示。周二下午两点到三点在图书馆二楼讨论方案，链接 https://example.com/project 。'
        '周三全天整理照片，周四周五两天整理旧资料，记成一个连续两天的全天安排。'
        '周六晚上十一点整理录像，到周日凌晨一点。从下周一开始，每周一早上七点到八点游泳，共四次。'
        '下周日下午三点到四点练琴，你觉得什么时候提醒合适就设一下。除了面试和练琴，其他都不用提醒。'
        '跟已有事情撞了就先别加，最后告诉我哪些加上了哪些没加。')


def main():
    p = argparse.ArgumentParser(description=__doc__);p.add_argument('--live',action='store_true');args=p.parse_args()
    if not args.live:raise SystemExit('Add --live to call the configured model with synthetic data only.')
    load_model_env();rows=[]
    original=urllib.request.urlopen
    for interrupted in (False,True):
        checkpoints={};injected=False
        def network(request, **kwargs):
            nonlocal injected
            name=json.loads(request.data)['text']['format']['name']
            if interrupted and name=='agentx_review' and not injected:
                injected=True
                raise ConnectionResetError('synthetic disconnected review')
            return original(request, **kwargs)
        job=dict(submission_id='synthetic-long',task_id='synthetic-long',version=7,assistant_id='calendar',
                 text=TEXT,submitted_at='2026-09-30T12:40:34Z',time_zone='Asia/Shanghai',test_mode=True,conversation_context=[])
        started=time.monotonic()
        try:
            with patch('model_transport.urllib.request.urlopen',side_effect=network),request_journal(checkpoints,lambda:None):
                result,meta=parse(job)
            items=(result.get('plan') or {}).get('items',[])
            checks={'direct_creation_route':result['route']['kind']=='calendar', 'eight_items':len(items)==8,
                    'two_all_day_events':sum(i['calendar']['is_all_day'] for i in items)==2,
                    'four_occurrence_series':any(i['calendar']['recurrence']['mode']=='repeat' and i['calendar']['recurrence']['count']==4 for i in items),
                    'review_passed':meta['review']['status'] in ('passed','corrected')}
            if interrupted:
                checks['injected_failure_recovered']=injected and len(meta['review']['attempts'])==2
                checks['draft_generated_once']=len(meta['attempts'])==1
            row={'case':'long_review_disconnect' if interrupted else 'long_eight_events','passed':all(checks.values()),'checks':checks,
                 'elapsed_seconds':round(time.monotonic()-started,3),'output_tokens':(meta.get('usage') or {}).get('output_tokens'),
                 'model':meta.get('model'),'generation_attempts':len(meta['attempts']),'review_attempts':len(meta['review']['attempts'])}
            # Full synthetic model response remains local; published evidence is aggregate.
            (ROOT/'artifacts'/('model-reliability-'+row['case']+'.json')).write_text(json.dumps({'result':result,'metadata':meta},ensure_ascii=False,indent=2)+'\n')
        except Exception as error:
            row={'case':'long_review_disconnect' if interrupted else 'long_eight_events','passed':False,'error':str(error),
                 'elapsed_seconds':round(time.monotonic()-started,3)}
        rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
        (ROOT/'evidence/model-reliability-live.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
    if not all(row['passed'] for row in rows):raise SystemExit(1)


if __name__=='__main__':main()
