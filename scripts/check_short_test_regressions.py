#!/usr/bin/env python3
"""Synthetic replay of the two conversational short tests. No phone RPC or writes."""
import argparse,copy,json,time
from agentx_config import ROOT,load_model_env
from agentx_model import parse
from calendar_mutation import decide

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--live',action='store_true');args=p.parse_args()
    if not args.live:p.error('--live is required')
    load_model_env();rows=[]
    first='下周帮我找一天整理下家里的东西吧，估计得弄一整天。挑个没安排的日子，不用提醒我。'
    second='刚才那个改叫整理书房吧，备注帮我写一下，先收拾书架，再整理电脑里的文件。其他都不变。'
    old=dict(text='下周安排一小时整理学习资料',response='已验证',state='verified',events=[dict(title='AgentX Test 整理学习资料',start_at='2026-10-05T08:00:00+08:00',end_at='2026-10-05T09:00:00+08:00',history_ref='older/i1',source='saved_readback',save_status='saved',verification_status='verified')])
    recent=dict(text=first,response='10月6日全天事项已经保存，但字段验证未通过；不要把保存视为未创建。',state='partial',events=[dict(title='AgentX Test 整理下家里的东西',start_at='2026-10-06T00:00:00+08:00',end_at='2026-10-06T23:59:59+08:00',history_ref='recent/i1',source='saved_readback',save_status='saved',verification_status='failed')])
    base=dict(submission_id='synthetic-short',task_id='synthetic-short',version=7,assistant_id='calendar',text=first,submitted_at='2026-09-30T12:11:03Z',time_zone='Asia/Shanghai',test_mode=True,lease_id='synthetic',state='queued',conversation_context=[old])
    def run(name,fn,check):
        begin=time.monotonic()
        try:
            result,meta=fn();row=dict(case=name,passed=bool(check(result)),result=result,model=meta.get('model'),elapsed=round(time.monotonic()-begin,2))
        except Exception as e:row=dict(case=name,passed=False,error=str(e),review=getattr(e,'model_metadata',{}).get('review'))
        rows.append(row);print(json.dumps({k:v for k,v in row.items() if k not in ('result','review')},ensure_ascii=False),flush=True)
        (ROOT/'evidence/short-test-model-regressions.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
        return row.get('result')
    run('casual_all_day_route',lambda:parse(base),lambda r:r['route']['kind']=='calendar_schedule' and r['query']['slot_kind']=='all_day')
    repeated=copy.deepcopy(base);repeated['conversation_context']=[old,recent]
    run('repeated_request_still_reads_current_availability',lambda:parse(repeated),lambda r:r['route']['kind']=='calendar_schedule' and r['query']['slot_kind']=='all_day')
    follow=copy.deepcopy(repeated);follow.update(text=second,mutation_source_id='snapshot-short')
    routed=run('followup_targets_recent_saved_unverified',lambda:parse(follow),lambda r:r['route']['kind']=='calendar_mutation' and r['query']['start_at'][:10]<='2026-10-06' and r['query']['end_at']>='2026-10-07T00:00:00+08:00' and r['query'].get('target_history_refs')==['recent/i1'])
    follow['query']=(routed or {}).get('query',{'target_history_refs':['recent/i1']})
    c=dict(query=follow['query'],source_id='snapshot-short',tool_name='calendar_mutation_candidates',queried_at='2026-09-30T12:11:10Z',candidates=[dict(target_ref='recent-event',title='AgentX Test 整理下家里的东西',start_at='2026-10-06T00:00:00+08:00',end_at='2026-10-07T00:00:00+08:00',time_zone='Asia/Shanghai',is_all_day=True,calendar_name='Synthetic',writable=True,recurring=False,notes=None,related_history_refs=['recent/i1'])])
    def minimal(r):
        if r['decision']!='execute' or len(r['actions'])!=1:return False
        a=r['actions'][0];patch=a['patch'] or {}
        return a['target_ref']=='recent-event' and a['operation']=='update' and patch.get('title') in ('整理书房','AgentX Test 整理书房') and '书架' in (patch.get('notes') or '') and '电脑' in (patch.get('notes') or '') and all(patch.get(k) is None for k in ('start_at','end_at','time_zone','is_all_day','reminder_offsets_seconds'))
    run('casual_all_day_rename_and_notes_only',lambda:decide(follow,c),minimal)
    deleted=copy.deepcopy(c);deleted['candidates']=[dict(target_ref='older-only',title='AgentX Test 整理学习资料',start_at='2026-10-05T08:00:00+08:00',end_at='2026-10-05T09:00:00+08:00',time_zone='Asia/Shanghai',is_all_day=False,calendar_name='Synthetic',writable=True,recurring=False,notes=None,related_history_refs=['older/i1'])]
    run('manual_deletion_is_normal_not_found',lambda:decide(follow,deleted),lambda r:r['decision']=='not_found' and not r['actions'])
    edited=copy.deepcopy(c);edited['candidates'][0].update(start_at='2026-10-07T00:00:00+08:00',end_at='2026-10-08T00:00:00+08:00',notes='用户手动调整过日期')
    run('manual_date_edit_is_preserved',lambda:decide(follow,edited),minimal)
    duplicate=copy.deepcopy(c);duplicate['candidates'][0]['related_history_refs']=[];extra=copy.deepcopy(duplicate['candidates'][0]);extra['target_ref']='other-event';duplicate['candidates'].append(extra)
    ambiguous=copy.deepcopy(follow);ambiguous['query']['target_history_refs']=[];duplicate['query']=ambiguous['query']
    run('indistinguishable_duplicates_require_clarification',lambda:decide(ambiguous,duplicate),lambda r:r['decision']=='needs_clarification' and not r['actions'])
    if not all(r['passed'] for r in rows):raise SystemExit(1)
if __name__=='__main__':main()
