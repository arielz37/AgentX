#!/usr/bin/env python3
"""Fresh synthetic model probes only: no historical records, RPC or calendar access."""
import argparse
import copy
import json
import time
from pathlib import Path
from wellphone_model import load_env, parse, review_plan
from wellphone_worker import atomic
ROOT=Path(__file__).resolve().parents[1]


def fixture():
    # Deliberately fictional 2030 schedule, built here without reading user data.
    text='每周二下午14点到15点执行测试任务甲，共三次。下周六上午10点到11点执行测试任务乙。不用提醒。'
    job={'version':3,'text':text,'submitted_at':'2030-01-01T01:00:00Z','time_zone':'Asia/Shanghai'}
    def f(value,source='inferred'):
        return dict(value=value,source=source,evidence=None,reason='测试上下文推导',critical=False,blocks_creation=False)
    items=[]
    for i,(title,start,end) in enumerate([('执行测试任务甲','2030-01-01T14:00:00+08:00','2030-01-01T15:00:00+08:00'),('执行测试任务乙','2030-01-05T10:00:00+08:00','2030-01-05T11:00:00+08:00')],1):
        rule=dict(mode='repeat' if i==1 else 'none',frequency='weekly' if i==1 else None,interval=1,weekdays=[2] if i==1 else [],month_days=[],months=[],end_type='count' if i==1 else 'never',count=3 if i==1 else None,until=None,evidence='每周二下午14点到15点执行测试任务甲' if i==1 else None,reason='每周二三次' if i==1 else '无重复')
        fields=dict(title=f(title),start_at=f(start),end_at=f(end),time_zone=f('Asia/Shanghai'),location=f(None,'unresolved'))
        items.append(dict(item_id=f'i{i}',kind='flexible',fields=fields,
            calendar=dict(is_all_day=False,notes=None,url=None,recurrence=rule,reason='明确钟点',unsupported=[]),
            alerts=dict(mode='disabled',evidence='不用提醒',reason='明确不用提醒',count_limit=0,no_extra=True,overflow=False,items=[])))
    return job,dict(overflow=False,items=items)


def run(name):
    submission,draft=fixture()
    if name=='correct_plan':
        fields=draft['items'][1]['fields']
        fields['start_at']['value']='2030-01-12T10:00:00+08:00'
        fields['end_at']['value']='2030-01-12T11:00:00+08:00'
    if name=='end_to_end':
        submission['text']='下周六上午10点到11点执行测试任务丙，提前两小时提醒。'
    doc={'probe':name,'submission':submission,'calendar_execution':'not_requested_model_only'}
    start=time.monotonic()
    try:
        if name=='end_to_end':
            final,meta=parse(submission);review=meta['review'];doc['model']=meta
        else:
            final,review=review_plan(copy.deepcopy(draft),submission)
            doc['draft']=draft;doc['review']=review
        doc['final_plan']=final
        target=final['items'][0 if name=='end_to_end' else 1]['fields'];errors=[]
        if target['start_at']['value']!='2030-01-12T10:00:00+08:00':errors.append('wrong next-Saturday date')
        if target['end_at']['value']!='2030-01-12T11:00:00+08:00':errors.append('wrong end time')
        if name=='wrong_week' and review['status']!='corrected':errors.append('wrong draft not corrected')
        if name=='correct_plan' and (review['status']!='passed' or final!=draft):errors.append('correct draft changed')
        if name=='end_to_end':
            alerts=final['items'][0]['alerts']
            if not any(a.get('offset_seconds')==-7200 for a in alerts['items']):errors.append('explicit reminder lost')
        else:
            r=final['items'][0]['calendar']['recurrence']
            if (r['frequency'],r['weekdays'],r['count'])!=('weekly',[2],3):errors.append('unrelated series lost')
            if final['items'][0]['fields']['start_at']['value']!='2030-01-01T14:00:00+08:00':errors.append('correct future-today series wrongly changed')
        doc.update(status='passed' if not errors else 'failed',errors=errors,review_status=review['status'])
    except Exception as e:
        doc.update(status='failed',error=str(e))
        if hasattr(e,'model_metadata'):doc['model']=e.model_metadata
        if hasattr(e,'review_metadata'):doc['review']=e.review_metadata
    doc['seconds']=round(time.monotonic()-start,3)
    atomic(ROOT/'model-review-artifacts'/f'{name}.json',doc)
    print(json.dumps({k:doc.get(k) for k in ['probe','status','seconds','review_status','errors','error']},ensure_ascii=False),flush=True)
    return doc['status']=='passed'

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--only',choices=['wrong_week','correct_plan','end_to_end'])
    args=parser.parse_args();load_env(ROOT/'.env')
    outcomes=[run(name) for name in ([args.only] if args.only else ['wrong_week','correct_plan','end_to_end'])]
    raise SystemExit(0 if all(outcomes) else 1)
