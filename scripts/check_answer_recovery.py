#!/usr/bin/env python3
"""Synthetic model regressions only: no device, records directory, or calendar writes."""
import argparse
import copy
import json
import time
from unittest.mock import patch
from agentx_config import ROOT, load_model_env
import agentx_model
from tool_answer import answer_from_tool


def planning_case():
    # Entirely fabricated input and intentionally wrong first-pass inventory.
    text='2030年10月7日早上九点到十点看书，10月8日一整天整理相册。10月9日晚上十一点整理视频，到10月10日凌晨一点。10月11日看牙医，但忘记几点了，先别填时间。10月12日下午三点到四点讨论出游，备注带地图，链接 https://example.com/map 。这些都不用提醒。'
    quotes=['2030年10月7日早上九点到十点看书','10月8日一整天整理相册','10月9日晚上十一点整理视频',
            '10月12日下午三点到四点讨论出游','备注带地图','链接 https://example.com/map']
    inventory=dict(overflow=False,items=[dict(item_id=f'i{i}',title=q,evidence=q) for i,q in enumerate(quotes,1)])
    submission=dict(version=8,assistant_id='calendar',text=text,submitted_at='2030-10-01T08:00:00Z',time_zone='Asia/Shanghai',test_mode=True,conversation_context=[])
    original=agentx_model.base.request_json
    def request(messages,schema,name,deadline):
        if name=='agentx_creation_inventory':return inventory,{'synthetic_wrong_inventory':True}
        return original(messages,schema,name,deadline)
    with patch('creation_inventory.base.request_json',side_effect=request):result,meta=agentx_model.parse(submission)
    (ROOT/'artifacts/answer-recovery-planning-probe.json').write_text(json.dumps(dict(result=result,metadata=meta),ensure_ascii=False,indent=2))
    items=result['plan']['items'];final=meta['final_creation_inventory']
    assert len(items)==len(final['items'])==5, 'Wrong activity count survived review'
    assert items[3]['fields']['start_at']['value'] is None and items[3]['fields']['start_at']['blocks_creation'], 'Unknown dentist time was invented'
    assert '带地图' in (items[4]['calendar']['notes'] or '') and items[4]['calendar']['url']=='https://example.com/map', 'Attributes lost or split'
    return dict(case='six_to_five_inventory_repair',passed=True,initial_count=6,final_count=5,review_status=meta['review']['status'])


def answer_case(broken_review=False):
    titles=['看书','整理相册','整理视频','看牙医','讨论出游']
    states=['verified','not_created_conflict','not_created_conflict','not_created_missing_information','not_created_conflict']
    rows=[dict(item_id=f'i{i+1}',title=t,status=s,save_status='saved' if i==0 else 'not_attempted',verification_status='verified' if i==0 else 'not_attempted') for i,(t,s) in enumerate(zip(titles,states))]
    rows[0]['readback']=dict(title='看书',start_at='2030-10-07T09:00:00+08:00',end_at='2030-10-07T10:00:00+08:00')
    for i in (1,2,4):rows[i]['error']={'message':'与已有安排重叠，本项未保存'}
    rows[3]['error']={'message':'用户未提供关键时间'}
    j=dict(version=8,text='这五件事处理得怎么样了？出游的备注和链接保存了吗？',state='partial',completion_source_id='synthetic-mixed',execution=dict(status='partial',items=rows))
    c=dict(source_id=j['completion_source_id'],tool_name='calendar_execution',status='partial',time_zone='Asia/Shanghai',result=copy.deepcopy(j['execution']))
    original=agentx_model.base.request_json
    def request(messages,schema,name,deadline):
        if broken_review and name=='agentx_tool_answer':return {'answer':'五件事都保存了，出游备注链接也保存了。'},{'model':'synthetic-fault-injection'}
        if broken_review and name=='agentx_answer_review':return {'review':dict(decision='correct',reason='没有问题',corrected_answer=None,claims=[])},{}
        return original(messages,schema,name,deadline)
    with patch('tool_answer.base.request_json',side_effect=request):answer,meta=answer_from_tool(j,c)
    assert len(meta['review']['claims'])==5
    if broken_review:assert len(meta['reviews'])==2 and meta['review']['decision']=='correct'
    return dict(case='malformed_review_recovery' if broken_review else 'one_saved_three_conflicts_one_unknown',passed=True,answer=answer['text'],review_decision=meta['review']['decision'])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--live',action='store_true');parser.add_argument('--case',choices=['all','inventory'],default='all');args=parser.parse_args()
    if not args.live:raise SystemExit('Use --live for synthetic model requests; never reads real records.')
    load_model_env();results=[]
    for fn in ((planning_case,) if args.case=='inventory' else (planning_case,answer_case,lambda:answer_case(True))):
        start=time.monotonic()
        try:row=fn()
        except Exception as error:
            row=dict(case=fn.__name__,passed=False,error=str(error))
            (ROOT/'artifacts/answer-recovery-probe-error.json').write_text(json.dumps(getattr(error,'model_metadata',{}),ensure_ascii=False,indent=2))
        row['elapsed_seconds']=round(time.monotonic()-start,3);results.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
        (ROOT/'evidence'/('answer-recovery-inventory-probe.json' if args.case=='inventory' else 'answer-recovery-model-probes.json')).write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    if not all(r['passed'] for r in results):raise SystemExit(1)


if __name__=='__main__':main()
