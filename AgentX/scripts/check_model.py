#!/usr/bin/env python3
"""Opt-in real model test using synthetic text only. Never connects to an iPhone."""
import argparse
import json
from pathlib import Path
import time
from agentx_config import ROOT, load_model_env
from agentx_model import parse

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live',action='store_true',help='Allow billable model calls on the synthetic fixtures')
    args=parser.parse_args()
    if not args.live:parser.error('Add --live to authorize model calls; no phone RPC is used')
    load_model_env()
    cases=[
        ('auto','帮我发一封邮件约明天下午开会','unsupported'),
        ('auto','明天下午两点到三点提醒我给同事发邮件，不用额外提醒。','calendar'),
        ('calendar','帮我写一封求职邮件','unsupported'),
        ('calendar','帮我安排一次练琴，不用提醒。','calendar'),
        ('auto','明天下午两点到三点练琴，不用提醒。再帮我发送一封邮件。','mixed'),
        ('auto','帮我弄一下吧','clarify')]
    results=[]
    for scope,text,expected in cases:
        submission=dict(assistant_id=scope,version=3,text=text,submitted_at='2030-09-27T12:00:00Z',time_zone='Asia/Shanghai')
        started=time.monotonic()
        try:
            response,meta=parse(submission)
            row=dict(scope=scope,text=text,expected=expected,actual=response['route']['kind'],
                passed=response['route']['kind']==expected,plan_present=response['plan'] is not None,
                review_status=meta['review']['status'],elapsed_seconds=round(time.monotonic()-started,2),response=response)
        except Exception as error:
            row=dict(scope=scope,text=text,expected=expected,passed=False,error=str(error),elapsed_seconds=round(time.monotonic()-started,2))
        results.append(row)
        print(json.dumps({k:v for k,v in row.items() if k!='response'},ensure_ascii=False),flush=True)
        output=ROOT/'evidence/model-probes.json';output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps({'synthetic_only':True,'phone_rpc_calls':0,'cases':results},ensure_ascii=False,indent=2)+'\n')
    return 0 if all(r['passed'] for r in results) else 1
if __name__=='__main__':raise SystemExit(main())
