"""Reminder schema/provenance only; the iPhone owns time policy and side effects."""
import copy
import re


def obj(properties):
    return dict(type='object', properties=properties, required=list(properties), additionalProperties=False)


ALERT_ITEM = obj({
    'alert_id': {'type': 'string', 'pattern': r'^a([1-9]|1[0-6])$'},
    'trigger_type': {'type': 'string', 'enum': ['relative', 'absolute']},
    'offset_seconds': {'type': ['integer', 'null']},
    'at': {'type': ['string', 'null']},
    'source': {'type': 'string', 'enum': ['explicit', 'defaulted']},
    'evidence': {'type': ['string', 'null']}, 'reason': {'type': 'string'},
})
ALERT_SCHEMA = obj({
    'mode': {'type': 'string', 'enum': ['explicit', 'disabled', 'suggested', 'unresolved']},
    'evidence': {'type': ['string', 'null']}, 'reason': {'type': 'string'},
    'count_limit': {'type': ['integer', 'null']}, 'no_extra': {'type': 'boolean'},
    'overflow': {'type': 'boolean'}, 'items': {'type': 'array', 'maxItems': 16, 'items': ALERT_ITEM},
})

PROMPT = '''
本次新增alerts字段。提醒是事件的一部分，不是独立待办或通知；只生成候选，不宣称已经配置。
逐事项解析整段及单项提醒指令：明确的单项例外优先于一般要求。同一作用域内无法解释的矛盾mode=unresolved、items=[]，reason说明；不阻止其他事项。
mode=disabled：用户明确不用提醒，items=[]、count_limit=0、no_extra=true、evidence选相关原文。
mode=explicit：用户指定提醒。严格保留时间、次数，只说一次就只输出一次，不追加第二次；no_extra=true。
mode=suggested：没有指定提醒时根据语义建议0到2次，优先一次；两次必须分别有准备和临近检查等理由。不得编造通勤、作息、准备耗时或称为最佳时间。不用预设关键词表。
每条alert_id为a1,a2等，trigger_type=relative时offset_seconds为相对事件开始的秒数（提前为负、开始时为0），at=null；absolute时at为事件时区一致的带秒和偏移ISO8601，offset_seconds=null。
提前一天就是-86400秒；前一天上午九点必须按事件时区的前一个自然日09:00生成absolute，注意夏令时。不可把未知事件时间补成日期只为生成提醒。开始未知时可保留明确relative意图；无法确定absolute日期时用unresolved。
source在explicit模式下为explicit，在suggested下为defaulted。envelope和每条明确提醒的evidence都要从schema中的原文片段选取；建议可用null。reason只写简短原因。
count_limit仅记录用户明确的次数上限，否则null；不要把“两次相同时间”写成必须触发两次。no_extra表示禁止额外提醒，明确指令始终true。
超过两次明确提醒不能静默截断：最多保留16条原要求交手机判定；超过16条时overflow=true且items=[]，原因说明。不因当前时间过滤或替换用户明确要求，由手机保存前按当前时间过滤。系统建议尽量选提交时刻5分钟之后的触发时间。
不支持事件开始之后的提醒。用户要求无法满足时仍保留原要求；手机会报告未配置，不换成即时提醒。不设位置/邮件提醒。不要输出任何成功状态。
'''


def schema_with_quotes():
    schema = copy.deepcopy(ALERT_SCHEMA)
    schema['properties']['evidence'] = {'$ref': '#/$defs/optional_quote'}
    schema['properties']['items']['items']['properties']['evidence'] = {'$ref': '#/$defs/optional_quote'}
    return schema


def validate_alerts(alerts, text):
    def reject(): raise ValueError('Invalid reminder contract or provenance')
    def quote(q): return q is None or (isinstance(q, str) and bool(q) and q in text)
    if not isinstance(alerts, dict) or set(alerts) != set(ALERT_SCHEMA['properties']): reject()
    mode = alerts['mode']
    if mode not in ('explicit', 'disabled', 'suggested', 'unresolved'): reject()
    if not isinstance(alerts['reason'], str) or not 0 < len(alerts['reason']) <= 500 or not quote(alerts['evidence']): reject()
    if type(alerts['no_extra']) is not bool or type(alerts['overflow']) is not bool: reject()
    limit = alerts['count_limit']
    if limit is not None and (type(limit) is not int or not 0 <= limit <= 10000): reject()
    rows = alerts['items']
    if not isinstance(rows, list) or len(rows) > 16 or (alerts['overflow'] and rows): reject()
    if mode in ('explicit', 'disabled') and (alerts['evidence'] is None or not alerts['no_extra']): reject()
    if mode in ('disabled', 'unresolved') and (rows or alerts['overflow']): reject()
    if mode == 'disabled' and limit != 0: reject()
    if mode == 'explicit' and not rows and not alerts['overflow']: reject()
    ids = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != set(ALERT_ITEM['properties']): reject()
        aid = row['alert_id']
        if not isinstance(aid, str) or not re.fullmatch(r'a([1-9]|1[0-6])', aid) or aid in ids: reject()
        ids.add(aid)
        if row['trigger_type'] not in ('relative', 'absolute'): reject()
        if row['source'] != ('explicit' if mode == 'explicit' else 'defaulted'): reject()
        if not quote(row['evidence']) or (row['source'] == 'explicit' and row['evidence'] is None): reject()
        if not isinstance(row['reason'], str) or not 0 < len(row['reason']) <= 500: reject()
        if row['offset_seconds'] is not None and (type(row['offset_seconds']) is not int or abs(row['offset_seconds']) > 2**53): reject()
        if row['at'] is not None and (not isinstance(row['at'], str) or len(row['at']) > 100): reject()
    return alerts
