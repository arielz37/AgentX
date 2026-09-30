#!/usr/bin/env python3
"""Opt-in synthetic model probes, no phone/calendar access."""
import argparse
import json
import time
from agentx_config import ROOT, load_model_env
from agentx_model import parse

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live',action='store_true')
    args=parser.parse_args()
    if not args.live:parser.error('--live permits billable model calls')
    load_model_env()
    cases=[
        ('明天有哪些安排？','events','2030-09-28T00:00:00+08:00','2030-09-29T00:00:00+08:00'),
        ('下周一到周五，每天14点到18点，找至少90分钟的空档。','free_slots','2030-09-30T00:00:00+08:00','2030-10-05T00:00:00+08:00'),
        ('2030年10月2日下午三点到四点有没有安排冲突？','conflicts','2030-10-02T15:00:00+08:00','2030-10-02T16:00:00+08:00'),
        ('查询未来一整年的全部日程。','clarify',None,None),
        ('明天下午两点到三点练琴，不用提醒。','calendar',None,None),
        ('找明天下午空闲时间并自动安排一小时练琴。','unsupported_or_clarify',None,None)]
    results=[]
    for text,expected,start,end in cases:
        started=time.monotonic()
        try:
            r,m=parse(dict(version=4,assistant_id='auto',text=text,submitted_at='2030-09-27T12:00:00Z',time_zone='Asia/Shanghai'))
            q=r.get('query');kind=r['route']['kind']
            if expected in ('events','free_slots','conflicts'):
                passed=kind=='calendar_query' and q['mode']==expected
                # Daily-window free queries may narrow the outer bounds to those windows.
                if expected=='free_slots':
                    passed=passed and q['start_at'][:10]=='2030-09-30' and q['end_at'][:10] in ('2030-10-04','2030-10-05') and q['day_start_minute']==840 and q['day_end_minute']==1080 and q['duration_minutes']==90
                else:passed=passed and q['start_at']==start and q['end_at']==end
            else:passed=kind in ('unsupported','clarify') if expected=='unsupported_or_clarify' else kind==expected
            row=dict(text=text,expected=expected,passed=passed,response=r,review_status=m['review']['status'])
        except Exception as error:row=dict(text=text,expected=expected,passed=False,error=str(error),draft=getattr(error,'rejected_plan',None),metadata=getattr(error,'model_metadata',None))
        row['elapsed_seconds']=round(time.monotonic()-started,2);results.append(row)
        print(json.dumps(row,ensure_ascii=False),flush=True)
        path=ROOT/'evidence/calendar-query-model-probes.json'
        path.write_text(json.dumps(dict(synthetic_only=True,phone_rpc_calls=0,reference='2030-09-27T12:00:00Z',cases=results),ensure_ascii=False,indent=2)+'\n')
    return 0 if all(r['passed'] for r in results) else 1
if __name__=='__main__':raise SystemExit(main())
