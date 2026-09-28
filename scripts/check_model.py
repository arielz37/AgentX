#!/usr/bin/env python3
"""Real GPT acceptance probes using synthetic plans only. NEVER executes calendars."""
import datetime as dt
import json
import time
from pathlib import Path
from zoneinfo import ZoneInfo
from wellphone_model import load_env, parse
from wellphone_worker import atomic, ROOT

def assess(name, items, day):
    # These labels belong only to these fixed synthetic test cases, not production parsing.
    errors=[]
    if len(items)!=4: return ['Expected four candidates']
    def named(word):
        matches=[i for i in items if word in (i['fields']['title']['value'] or '')]
        if len(matches)!=1: raise ValueError('Probe cannot identify expected candidate: '+word)
        return matches[0]
    if name=='complete-four':
        for word,start_hour,end_hour in [('书架',9,10),('练琴',11,12),('笔记',14,15),('散步',16,17)]:
            fields=named(word)['fields']
            if fields['start_at']['value']!=f'{day}T{start_hour:02}:00:00+08:00' or fields['end_at']['value']!=f'{day}T{end_hour:02}:00:00+08:00': errors.append('Explicit time mismatch: '+word)
            if any(f['blocks_creation'] for f in fields.values()): errors.append('Complete item unexpectedly blocked')
    else:
        fixed=named('早餐')['fields'];f=named('整理')['fields']
        if fixed['location']['value'] is not None: errors.append('Unknown location invented')
        if any(v['blocks_creation'] for v in fixed.values()): errors.append('Optional location blocked creation')
        if not f['start_at']['value'] or not f['end_at']['value']: errors.append('Flexible item not scheduled')
        elif fixed['start_at']['value'] and fixed['end_at']['value']:
            start=dt.datetime.fromisoformat(f['start_at']['value']);end=dt.datetime.fromisoformat(f['end_at']['value'])
            if not 0 < (end-start).total_seconds() <=10800: errors.append('Unreasonable default duration')
            a=dt.datetime.fromisoformat(fixed['start_at']['value']);b=dt.datetime.fromisoformat(fixed['end_at']['value'])
            if start<b and a<end: errors.append('Default conflicts with explicit appointment')
        else: errors.append('Explicit breakfast time missing')
        if f['start_at']['source']!='defaulted' or f['end_at']['source']!='defaulted': errors.append('Defaults disguised as facts')
        for item in [named('项目'),named('钢琴')]:
            if item['fields']['start_at']['value'] is not None or not item['fields']['start_at']['blocks_creation']: errors.append('Critical time invented')
    return errors


def main():
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', choices=['complete-four','mixed'])
    args=parser.parse_args()
    load_env(ROOT / '.env')
    now=dt.datetime.now(ZoneInfo('Asia/Shanghai'))
    day=(now+dt.timedelta(days=1)).strftime('%Y-%m-%d')
    samples={
      'complete-four':f'{day}上午9点到10点整理书架，11点到12点练琴，下午14点到15点写读书笔记，16点到17点散步。',
      'mixed':f'{day}上午9点到10点和小丽吃早餐，餐厅还没定；{day}找时间整理房间，时间随便安排；那个项目快截止了，具体哪天我不记得了；{day}有已经预约的钢琴课，准确开始时间我不知道。'
    }
    for name,text in samples.items():
        if args.only and args.only != name: continue
        job={'text':text,'submitted_at':now.isoformat(),'time_zone':'Asia/Shanghai'}
        doc={'request':job,'calendar_execution':'not_requested_model_only'}
        monotonic_started=time.monotonic()
        try:
            doc['plan'],doc['model']=parse(job)
            errors=assess(name,doc['plan']['items'],day)
            doc['semantic_errors']=errors
            doc['status']='model_probe_passed' if not errors else 'semantic_failed'
        except Exception as e:
            doc['status']='model_failed';doc['error']=str(e)
            if hasattr(e,'rejected_plan'): doc['rejected_plan']=e.rejected_plan;doc['model']=e.model_metadata
        doc['model_elapsed_seconds']=round(time.monotonic()-monotonic_started,3)
        atomic(ROOT/'day3-artifacts'/('model-'+name+'.json'),doc)
        print(json.dumps({'probe':name,'status':doc['status'],'seconds':doc['model_elapsed_seconds'],
                          'items':[{ 'id':i['item_id'], 'title':i['fields']['title']['value'],
                          'blocked':any(f['blocks_creation'] for f in i['fields'].values()),
                          'defaulted':[k for k,f in i['fields'].items() if f['source']=='defaulted'],
                          'unresolved':[k for k,f in i['fields'].items() if f['source']=='unresolved']}
                          for i in doc.get('plan',{}).get('items',[])], 'error':doc.get('error'), 'semantic_errors':doc.get('semantic_errors')},ensure_ascii=False),flush=True)

if __name__=='__main__': main()
