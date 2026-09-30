#!/usr/bin/env python3
"""Opt-in synthetic model probes: never connects to a phone or modifies calendars."""
import argparse
import copy
import json
import sys
import time
from agentx_config import ROOT,load_model_env
from agentx_model import parse
from calendar_mutation import decide
from calendar_schedule import schedule_from_tool
sys.path.insert(0,str(ROOT/'tests'))
from test_calendar_v7 import job,context

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--live',action='store_true');args=p.parse_args()
    if not args.live:p.error('Use --live to call the configured model with synthetic data')
    load_model_env();rows=[]
    def record(label,fn,check):
        start=time.monotonic()
        try:
            value,meta=fn();row=dict(case=label,passed=bool(check(value)),result=value,model=meta.get('model'),elapsed=round(time.monotonic()-start,2))
        except Exception as e:row=dict(case=label,passed=False,error=str(e),review=getattr(e,'model_metadata',{}).get('review',{}).get('result'),draft=getattr(e,'model_metadata',{}).get('draft'))
        rows.append(row);print(json.dumps({k:v for k,v in row.items() if k!='result'},ensure_ascii=False),flush=True)
        (ROOT/'evidence/calendar-v7-model-probes.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
        return row.get('result')
    j=job()
    record('followup_route_old_date',lambda:parse(j),lambda r:r['route']['kind']=='calendar_mutation' and r['query']['start_at'][:10]<='2030-10-02'<r['query']['end_at'][:10])
    record('followup_minimal_move',lambda:decide(j,context()),lambda r:r['decision']=='execute' and r['actions'][0]['patch']['start_at']=='2030-10-02T16:00:00+08:00' and r['actions'][0]['patch']['end_at']=='2030-10-02T17:00:00+08:00' and r['actions'][0]['patch']['notes'] is None)
    j2=copy.deepcopy(j);j2['text']='删掉刚才那个'
    record('delete_actual_target',lambda:decide(j2,context()),lambda r:r['decision']=='execute' and r['actions'][0]['operation']=='delete' and r['actions'][0]['scope']=='this_event')
    j3=copy.deepcopy(j);j3.update(text='把整理书架删掉',conversation_context=[])
    c=context();other=copy.deepcopy(c['candidates'][0]);other.update(target_ref='candidate-2',start_at='2030-10-02T17:00:00+08:00',end_at='2030-10-02T18:00:00+08:00');c['candidates'].append(other)
    record('ambiguous_target_no_write',lambda:decide(j3,c),lambda r:r['decision']=='needs_clarification' and not r['actions'])
    j4=copy.deepcopy(j);j4.update(text='查询2031年全年的日程',conversation_context=[])
    record('one_year_route',lambda:parse(j4),lambda r:r['route']['kind']=='calendar_query' and r['query']['start_at']=='2031-01-01T00:00:00+08:00' and r['query']['end_at']=='2032-01-01T00:00:00+08:00')
    j5=copy.deepcopy(j);j5.update(text='下周找一个完整空闲日帮我安排整理资料，全天，不用提醒。',conversation_context=[])
    route=record('all_day_route',lambda:parse(j5),lambda r:r['route']['kind']=='calendar_schedule' and r['query']['slot_kind']=='all_day' and r['query']['duration_days']==1)
    if route and route['route']['kind']=='calendar_schedule':
        j5.update(route=route['route'],query=route['query'],schedule_request=route['schedule_request'])
        ctx=dict(source_id=j5['query_result_id'],tool_name='calendar_query',status='query_complete',result=dict(request=route['query'],queried_at='2030-09-30T12:00:10Z',event_count=0,busy_count=0,calendar_count=1,events=[],events_truncated=False,free_slots=[dict(start_at='2030-10-08T00:00:00+08:00',end_at='2030-10-09T00:00:00+08:00')],slots_truncated=False,scope_note='Synthetic whole-day availability'))
        record('all_day_placement',lambda:schedule_from_tool(j5,ctx),lambda r:r['decision']=='scheduled' and r['plan']['items'][0]['calendar']['is_all_day'])
    if not all(r['passed'] for r in rows):raise SystemExit(1)
if __name__=='__main__':main()
