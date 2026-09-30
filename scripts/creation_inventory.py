"""Model-extracted request inventory, independent of the candidate execution plan."""
import copy
import json
import model_contract as base

PROMPT = '''你只清点当前用户实际要求新增到日历的事项，不生成时间字段、不选择工具、不执行。
先读当前原文，再用历史补足必要指代；历史已完成事项不是本轮新增清单，历史失败路由不可信。
一条连续跨天活动算一项，一个重复系列算一项（不是按次数展开）。同一天两个不同活动算两项。未知关键时间也必须保留该事项，不能因可能冲突而漏掉。只查询、修改或删除已有事项时新增清单为空；修改不是再创建副本。
按活动而不是句子或字段清点：同一活动的备注、链接、地点、提醒和时间补充都归属该活动，不另算事项。时间未知但用户要求保留的活动仍单列。清单是候选判断，后续可依据原文复核纠正。
items按当前原文顺序列出item_id=i1至i8、自然标题、当前原文连续片段evidence。evidence从schema的原文片段中选，不改写；可以多项引用同一片段。
本轮要求新增超过8项时overflow=true且items=[]，不能截断到8项。否则overflow=false，必须列齐所有新增事项。不要附加说明。'''


def validate_inventory(value, submission):
    if not isinstance(value, dict) or set(value) != {'overflow','items'} or type(value['overflow']) is not bool:
        raise ValueError('Invalid creation inventory')
    items = value['items']
    if not isinstance(items,list) or len(items)>8 or (value['overflow'] and items):
        raise ValueError('Invalid creation inventory count')
    for n,item in enumerate(items,1):
        if not isinstance(item,dict) or set(item)!={'item_id','title','evidence'} or item['item_id']!=f'i{n}':
            raise ValueError('Invalid creation inventory item')
        if not isinstance(item['title'],str) or not 0<len(item['title'])<=200 or not isinstance(item['evidence'],str) or not item['evidence'] or item['evidence'] not in submission['text']:
            raise ValueError('Creation inventory must cite current input')
    return value


def inventory_schema():
    return base.obj({'overflow':{'type':'boolean'},'items':{'type':'array','maxItems':8,
        'items':base.obj({'item_id':{'type':'string','enum':[f'i{i}' for i in range(1,9)]},
                          'title':{'type':'string','minLength':1,'maxLength':200},'evidence':{'$ref':'#/$defs/source_quote'}})}})


def extract_inventory(submission, deadline):
    definitions=base.schema_for_text(submission['text'])['$defs']
    schema=inventory_schema()
    schema['$defs']=definitions
    value,meta=base.request_json([{'role':'system','content':PROMPT},{'role':'user','content':json.dumps({
        'current_request':submission['text'],'conversation_context':submission.get('conversation_context',[])},ensure_ascii=False)}],
        schema,'agentx_creation_inventory',deadline)
    validate_inventory(value,submission)
    # Audit activity boundaries before the much larger time/recurrence/routing
    # prompt. A large plan review alone retained a known synthetic overcount.
    audited_inventory_schema=inventory_schema()
    audited_item=audited_inventory_schema['properties']['items']['items']
    del audited_item['properties']['item_id']
    audited_item['required'].remove('item_id')
    audit_schema=base.obj({'overflow':{'type':'boolean'},
        'activities':audited_inventory_schema['properties']['items'],
        'attributes':{'type':'array','maxItems':32,'items':base.obj({
            'activity_index':{'type':'integer','minimum':1,'maximum':8},
            'field':{'type':'string','enum':['notes','url','location','alerts','time','other']},
            'evidence':{'$ref':'#/$defs/source_quote'}})},
        'changes':{'type':'array','maxItems':16,'items':{'type':'string','minLength':1,'maxLength':500}}})
    audit_schema['$defs']=definitions
    audit_prompt=PROMPT.replace('item_id=i1至i8、','').replace('items','activities')
    audited,audit_meta=base.request_json([{'role':'system','content':audit_prompt+'''
你专门复核活动边界，不生成执行计划。先从当前原文理解各个真实活动及附属信息，再对照candidate_inventory；它可能漏掉未知时间的预约，或把某个活动的附属说明拆成多个虚假事项。
activities只放独立活动；附属备注、链接等放attributes，每项用activity_index（从1开始）关联所属活动。绝不能为了保留附属信息而在activities里重复列出它。例如“明天吃饭，备注带伞，链接…”只有一个activity，备注和链接属于它的attributes。
有遗漏就补回，多算就合并或删除，按原文顺序列出，changes说明每处变化的原文依据。此步骤不输出item_id，系统会在执行前给新清单分配ID，不沿用候选的错位ID。无变化changes=[]；超过8项overflow=true且两个数组为空。不是比较两个清单谁更长，不把第一次结果当真，不因为候选已出现就保留错误项。'''},
        {'role':'user','content':json.dumps({'current_request':submission['text'],
            'conversation_context':submission.get('conversation_context',[]),'candidate_inventory':value},ensure_ascii=False)}],
        audit_schema,'agentx_inventory_audit',deadline)
    if not isinstance(audited,dict) or set(audited)!={'overflow','activities','attributes','changes'} or not isinstance(audited['changes'],list) or len(audited['changes'])>16 or any(not isinstance(c,str) or not 0<len(c)<=500 for c in audited['changes']):
        raise ValueError('Invalid inventory audit')
    final={'overflow':audited['overflow'],'items':copy.deepcopy(audited['activities'])}
    # IDs are execution identities, not semantic decisions. Assign only before
    # planning; no persisted or executed item is ever renumbered.
    for index,item in enumerate(final['items'],1):item['item_id']=f'i{index}'
    validate_inventory(final,submission)
    if not isinstance(audited['attributes'],list) or len(audited['attributes'])>32:raise ValueError('Invalid inventory attributes')
    for attribute in audited['attributes']:
        if not isinstance(attribute,dict) or set(attribute)!={'activity_index','field','evidence'} or type(attribute['activity_index']) is not int or not 1<=attribute['activity_index']<=len(final['items']) or attribute['field'] not in ('notes','url','location','alerts','time','other') or not isinstance(attribute['evidence'],str) or not attribute['evidence'] or attribute['evidence'] not in submission['text']:
            raise ValueError('Invalid inventory attribute binding')
    if final!=value and not audited['changes']:raise ValueError('Inventory audit changed activities without reasons')
    return final,{**meta,'initial_inventory':value,'audit':{**audit_meta,**audited}}


def validate_coverage(response, inventory):
    kind=response['route']['kind']
    if kind not in ('calendar','calendar_schedule'):return
    expected=[i['item_id'] for i in inventory['items']]
    if kind=='calendar':
        plan=response['plan']
        if inventory['overflow'] and not plan['overflow']:raise ValueError('Creation inventory exceeds 8; do not truncate')
        if expected and (plan['overflow'] or [i['item_id'] for i in plan['items']]!=expected):
            raise ValueError('Creation plan must cover every inventory item exactly once in order: '+','.join(expected))
    elif expected and [i['item_id'] for i in response['schedule_request']['items']]!=expected:
        raise ValueError('Schedule request must cover every creation inventory item')
