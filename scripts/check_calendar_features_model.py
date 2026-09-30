#!/usr/bin/env python3
"""Synthetic real-model capability probes. Never calls calendar RPC or writes events."""
import argparse
import datetime as dt
import json
import time
from zoneinfo import ZoneInfo
from wellphone_model import load_env, parse
from wellphone_worker import ROOT, atomic

CASES = {
    'weekly': '每周五早上我都要去游泳',
    'multiweek': '从下周开始，每隔两周的周二和周四下午两点到三点练琴，共六次，不用提醒。',
    'dates': '每月最后一天上午九点到十点整理账本；每年公历五月二十日下午三点到四点整理照片；这些都不用提醒。',
    'all_day': '下周六到周日全天参加读书营，备注带纸质书和水杯，资料链接 https://example.com/reading ，不用提醒。',
    'overnight': '后天晚上十点到大后天早上六点值班，备注带充电器；从明天起每天早上七点到七点半慢跑，截止今年十二月三十一日。这些都不用提醒。',
    'unsupported': '每年农历八月十五全天家庭聚会；每个法定工作日上午九点到十点复习，需要按中国节假日和调休变化。这些都不用提醒。',
}


def assess(name, plan, submitted_at=None):
    items=plan['items']; errors=[]
    def check(condition, message):
        if not condition:errors.append(message)
    if name=='weekly':
        check(len(items)==1,'expected one series')
        if not items:return errors
        item=items[0];r=item['calendar']['recurrence'];f=item['fields']
        check((r['mode'],r['frequency'],r['interval'],r['weekdays'],r['end_type'])==('repeat','weekly',1,[5],'never'),'weekly Friday intent lost')
        check(not item['calendar']['is_all_day'],'morning became all-day')
        start=dt.datetime.fromisoformat(f['start_at']['value']);end=dt.datetime.fromisoformat(f['end_at']['value'])
        check(start.isoweekday()==5 and 5<=start.hour<12,'Friday morning anchor wrong')
        check(f['start_at']['source']=='defaulted' and f['end_at']['source']=='defaulted','suggested clock not labeled')
        check(0<(end-start).total_seconds()<=10800,'invalid suggested duration')
    elif name=='multiweek':
        r=items[0]['calendar']['recurrence']
        check(len(items)==1 and r['frequency']=='weekly' and r['interval']==2 and sorted(r['weekdays'])==[2,4] and r['count']==6 and r['end_type']=='count','biweekly multi-day/count lost')
    elif name=='dates':
        rules=[i['calendar']['recurrence'] for i in items]
        check(any(r['frequency']=='monthly' and r['month_days']==[-1] for r in rules),'month-end lost')
        check(any(r['frequency']=='yearly' and r['months']==[5] and r['month_days']==[20] for r in rules),'yearly civil date lost')
    elif name=='all_day':
        item=items[0];f=item['fields'];c=item['calendar'];start=dt.datetime.fromisoformat(f['start_at']['value']);end=dt.datetime.fromisoformat(f['end_at']['value'])
        check(c['is_all_day'] and start.hour==end.hour==0 and start.isoweekday()==6 and (end.date()-start.date()).days==2,'all-day exclusive end wrong')
        if submitted_at:
            current=dt.datetime.fromisoformat(submitted_at).date()
            expected=current+dt.timedelta(days=7-current.weekday()+5)
            check(start.date()==expected,'next calendar week date wrong')
        check(c['url']=='https://example.com/reading' and '纸质书' in (c['notes'] or '') and '水杯' in (c['notes'] or ''),'notes/link lost')
    elif name=='overnight':
        check(len(items)==2,'expected two items')
        f=items[0]['fields'];start=dt.datetime.fromisoformat(f['start_at']['value']);end=dt.datetime.fromisoformat(f['end_at']['value'])
        check((end-start).total_seconds()==8*3600 and not items[0]['calendar']['is_all_day'],'cross-midnight lost')
        r=items[1]['calendar']['recurrence'];check(r['frequency']=='daily' and r['end_type']=='until' and r['until'].endswith('-12-31'),'daily until lost')
    else:
        check(len(items)==2 and all(i['calendar']['recurrence']['mode']=='unresolved' for i in items),'unsupported silently downgraded')
    return errors


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--only',choices=list(CASES));args=p.parse_args()
    load_env(ROOT/'.env'); now=dt.datetime.now(ZoneInfo('Asia/Shanghai'));failed=False
    for name,text in CASES.items():
        if args.only and name!=args.only:continue
        job=dict(version=3,text=text,submitted_at=now.isoformat(),time_zone='Asia/Shanghai')
        doc={'request':job,'calendar_execution':'not_requested_model_only'};started=time.monotonic()
        try:
            doc['plan'],doc['model']=parse(job)
            doc['semantic_errors']=assess(name,doc['plan'],job['submitted_at'])
            doc['status']='passed' if not doc['semantic_errors'] else 'semantic_failed'
        except Exception as e:
            doc['status']='failed';doc['error']=str(e)
            if hasattr(e,'rejected_plan'):doc['rejected_plan']=e.rejected_plan
        doc['seconds']=round(time.monotonic()-started,3)
        atomic(ROOT/'calendar-features-artifacts'/f'model-{name}.json',doc)
        print(json.dumps({k:doc.get(k) for k in ['status','seconds','error','semantic_errors']}|{'probe':name},ensure_ascii=False),flush=True)
        failed |= doc['status']!='passed'
    return int(failed)
if __name__=='__main__':raise SystemExit(main())
