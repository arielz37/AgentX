#!/usr/bin/env python3
"""Bounded real-model semantic probes. Synthetic input only; NEVER calendar RPC."""
import argparse
import datetime as dt
import json
import time
from zoneinfo import ZoneInfo
from wellphone_model import load_env, parse
from wellphone_worker import ROOT, atomic


def samples(day):
    return {
        'explicit': f'{day}上午9点到10点练琴，只提前一天提醒一次；下午2点到3点线上讨论，提前两小时提醒；晚上7点到8点准备面试，提前一天和提前两小时各提醒一次。',
        'scope': f'{day}上午9点到10点整理书架，下午2点到3点散步，晚上7点到8点面试。这些都不用提醒，面试除外，提前一天提醒一次。',
        'absolute_count': f'{day}下午2点到3点练琴，当天上午9点提醒我；晚上7点到8点线上讨论，提前一天、提前两小时、提前十分钟各提醒一次；已经预约的钢琴课准确开始时间不知道，要求提前两小时提醒。',
        'suggested': f'{day}上午9点到10点整理书架，下午2点到3点线上会议。',
    }


def assess(name, plan, day):
    errors = []
    items = plan['items']
    def named(word):
        matches = [i for i in items if word in (i['fields']['title']['value'] or '')]
        if len(matches) != 1: raise ValueError('Synthetic fixture candidate missing/ambiguous: ' + word)
        return matches[0]
    def check(word, mode, offsets):
        a = named(word)['alerts']
        if a['mode'] != mode or sorted(x['offset_seconds'] for x in a['items']) != sorted(offsets): errors.append(word + ': reminder mode/count/offset mismatch')
        if mode == 'explicit' and not a['no_extra']: errors.append(word + ': extra reminders allowed')
    if name == 'explicit':
        check('练琴','explicit',[-86400]);check('讨论','explicit',[-7200]);check('面试','explicit',[-86400,-7200])
    elif name == 'scope':
        check('书架','disabled',[]);check('散步','disabled',[]);check('面试','explicit',[-86400])
    elif name == 'absolute_count':
        a=named('练琴')['alerts']
        if a['mode']!='explicit' or len(a['items'])!=1 or a['items'][0]['at']!=f'{day}T09:00:00+08:00': errors.append('Absolute reminder changed')
        check('讨论','explicit',[-86400,-7200,-600])
        course=named('钢琴课')
        if course['fields']['start_at']['value'] is not None: errors.append('Unknown appointment time invented')
        if course['alerts']['mode']!='explicit' or [x['offset_seconds'] for x in course['alerts']['items']] != [-7200]: errors.append('Unknown-start relative intention lost')
    else:
        for item in items:
            a=item['alerts']
            if a['mode']!='suggested' or len(a['items'])>2 or any(x['source']!='defaulted' for x in a['items']): errors.append('Suggestions disguised or overfilled')
    return errors


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=['explicit','scope','absolute_count','suggested']);args=p.parse_args()
    load_env(ROOT/'.env')
    now=dt.datetime.now(ZoneInfo('Asia/Shanghai'));day=(now+dt.timedelta(days=4)).date().isoformat()
    failed=False
    for name,text in samples(day).items():
        if args.only and name!=args.only:continue
        job=dict(version=2,text=text,submitted_at=now.isoformat(),time_zone='Asia/Shanghai')
        doc={'request':job,'calendar_execution':'not_requested_model_only'};started=time.monotonic()
        try:
            doc['plan'],doc['model']=parse(job)
            doc['semantic_errors']=assess(name,doc['plan'],day)
            doc['status']='passed' if not doc['semantic_errors'] else 'semantic_failed'
        except Exception as e:
            doc['status']='failed';doc['error']=str(e)
            if hasattr(e,'rejected_plan'):doc['rejected_plan']=e.rejected_plan
        doc['seconds']=round(time.monotonic()-started,3)
        atomic(ROOT/'alert-artifacts'/f'model-{name}.json',doc)
        print(json.dumps({k:doc.get(k) for k in ['status','seconds','error','semantic_errors']}|{'probe':name},ensure_ascii=False),flush=True)
        failed |= doc['status']!='passed'
    return int(failed)

if __name__=='__main__':raise SystemExit(main())
