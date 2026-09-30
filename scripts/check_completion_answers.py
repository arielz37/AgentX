#!/usr/bin/env python3
"""Synthetic post-execution reports -> model; no phone access or calendar writes."""
import argparse
import json
import time
from agentx_config import ROOT, load_model_env
from tool_answer import answer_from_tool


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--live',action='store_true');args=parser.parse_args()
    if not args.live:raise SystemExit('Use --live for a synthetic OpenAI API test.')
    load_model_env();results=[]
    titles=['读书','线上面试','讨论方案','整理照片','整理旧资料','整理录像','游泳','练琴']
    for case in ['all_verified','partial_with_saved_unverified']:
        rows=[]
        for index,title in enumerate(titles,1):
            verified=case=='all_verified' or index<=4;saved=verified or index==5
            row=dict(item_id=f'i{index}',title=title,status='verified' if verified else 'saved_unverified' if saved else 'failed',
                     save_status='saved' if saved else 'not_attempted',verification_status='verified' if verified else 'failed' if saved else 'not_attempted')
            if saved:row['saved_at']='2030-09-30T10:00:00Z'
            if verified:row['verified_at']='2030-09-30T10:00:01Z';row['readback']={'title':title,'start_at':f'2030-10-{index+1:02d}T08:00:00+08:00','end_at':f'2030-10-{index+1:02d}T09:00:00+08:00'}
            else:row['error']={'message':'保存后查询不到，不能重复创建' if saved else '日历接口本次未返回可读取日历'}
            rows.append(row)
        result=dict(status='verified' if case=='all_verified' else 'partial',items=rows)
        job=dict(version=8,text='帮我把读书、线上面试、讨论方案、整理照片、整理旧资料、整理录像、游泳和练琴这八件事记到日历里。办完告诉我哪些好了，哪些没好。',
                 state=result['status'],time_zone='Asia/Shanghai',completion_source_id='synthetic-'+case,execution=result)
        context=dict(source_id=job['completion_source_id'],tool_name='calendar_execution',status=result['status'],time_zone=job['time_zone'],result=result)
        started=time.monotonic();answer,meta=answer_from_tool(job,context)
        row=dict(case=case,elapsed_seconds=round(time.monotonic()-started,3),answer=answer['text'],review_decision=meta['review']['decision'])
        results.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
    (ROOT/'evidence/completion-answer-model-probes.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
