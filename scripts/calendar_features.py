"""Version 3 calendar capabilities; no EventKit or side effects on the Mac."""
from urllib.parse import urlsplit
import datetime as dt


def obj(properties):
    return dict(type='object', properties=properties, required=list(properties), additionalProperties=False)


def schema():
    nullable_string = {'type': ['string', 'null']}
    recurrence = obj({
        'mode': {'type': 'string', 'enum': ['none', 'repeat', 'unresolved']},
        'frequency': {'type': ['string', 'null'], 'enum': ['daily', 'weekly', 'monthly', 'yearly', None]},
        'interval': {'type': 'integer', 'minimum': 1, 'maximum': 99},
        'weekdays': {'type': 'array', 'items': {'type': 'integer', 'minimum': 1, 'maximum': 7}, 'maxItems': 7},
        'month_days': {'type': 'array', 'items': {'type': 'integer', 'minimum': -1, 'maximum': 31}, 'maxItems': 31},
        'months': {'type': 'array', 'items': {'type': 'integer', 'minimum': 1, 'maximum': 12}, 'maxItems': 12},
        'end_type': {'type': 'string', 'enum': ['never', 'count', 'until']},
        'count': {'type': ['integer', 'null'], 'minimum': 1, 'maximum': 1000},
        'until': nullable_string,
        'evidence': {'$ref': '#/$defs/optional_quote'},
        'reason': {'type': 'string', 'minLength': 1, 'maxLength': 500},
    })
    return obj({'is_all_day': {'type': 'boolean'}, 'notes': nullable_string, 'url': nullable_string,
                'recurrence': recurrence, 'reason': {'type': 'string', 'minLength': 1, 'maxLength': 500},
                'unsupported': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 8}})


PROMPT = '''
版本3 calendar 是实际日历能力契约，每项都必须输出。不要把重复要求丢弃为单次事件。
先做能力判断：只支持公历简单周期。农历/阴历、法定节假日/调休规则必须recurrence.mode=unresolved、frequency=null、数组全空，且开始/结束时间null、source=unresolved、blocks_creation=true；绝不能把农历八月十五翻译成每年公历8月15日，不推算农历日期。
同一活动、相同钟点、多个星期几只输出一个item，把星期几放在同一weekdays数组。禁止再额外为每个星期几输出第二个包含相同weekdays的系列。例如“每隔两周周二和周四14至15点练琴，共6次”必须只有一个item，weekdays=[2,4]、interval=2、count=6（所有发生合计6次，不是每个星期几各6次）。
所有reason都必须为非空中文；不重复时recurrence.reason写“用户未要求重复”。明确说出的结束钟点属于explicit或inferred，不能标defaulted；只有你自主建议的时间才defaulted。
calendar.is_all_day 仅在用户明确全天、按整日占用或假期日期范围时true；“早上”不是全天。
全天起止使用事件时区当地00:00:00，end_at为最后一天的次日00:00:00（排他结束）。例如周六到周日全天，结束为周一零点。已知日期即可执行全天，不把不需要的钟点当作空缺。
允许明确的跨夜/跨天，持续最多366个当地日；取代前述24小时和不支持全天限制。自主建议的定时事件时长仍至多3小时，不为未知关键约定制造全天事件。
calendar.notes保留用户有用的备注/准备要求，可整理原文但不可虚构事实，不包含内部推理；无则null。calendar.url只复制用户提供的完整http/https链接，不生成或猜测；无则null。calendar.reason说明全天/备注/链接的依据或缺失，不虚称已写入。
calendar.recurrence.mode：没有重复要求none；明确可支持的重复repeat；重复意图含糊/矛盾或超出能力unresolved（整条不创建，不降级成单次）。
repeat.frequency支持daily/weekly/monthly/yearly；interval为每N个频率单位，1..99。weekdays采用ISO周一1至周日7，仅weekly使用且至少一项；工作日=周一至周五，但涉及中国调休/法定节假日例外不支持，必须unresolved。
monthly用month_days（1..31或-1表示月末）；yearly用months(1..12)及month_days正数，表示公历月日；daily其他数组全空。weekly的month_days/months为空；monthly的weekdays/months为空；yearly的weekdays为空。
每周五游泳必须repeat/weekly/interval=1/weekdays=[5]，创建一条带规则的系列，不能展开成多条单次事件。每天/隔周/每周二和周四/每月15号/每月最后一天/每年公历生日同理。首次start_at必须是未来且符合该规则的第一次日期；首次当地钟点供后续重复沿用。
end_type=never（用户未给结束界限时不擅自补一个），count（含首次，共N次，count=1..1000），until（含当天，until=YYYY-MM-DD的当地日期）；count和until互斥，未用字段null。none/unresolved必须frequency=null、interval=1、数组为空、end_type=never、count/until=null。
repeat及unresolved必须evidence引用重复原文，reason说明周期、结束条件、无效日期处理；月31号在无31号的月份跳过，不改到月末。农历/调休排除/某次例外/每月第N个星期几当前不能表达，mode=unresolved。不可猜测不明确的循环间隔。
周期活动“每周五早上我都要去游泳”是可自主建议时段的个人习惯：建议下一次周五早上例如09:00–10:00，start/end标defaulted并解释；明确外部课程预约的未知开始时间依旧留空。
重复系列的提醒优先relative，每次相对当次开始触发；用户明确绝对提醒日期仍保留absolute，不偷换成每次提醒，执行端会报告此组合暂不支持。
calendar.unsupported列出用户要求但此版无法执行的其他操作（修改/删除已有事件、邀请人、选日历、附件、忙闲、位置提醒等），非空会阻止该项创建。未要求则[]。本轮只创建；不要把修改/删除/查空闲等请求伪装成创建。
'''


def validate(features, text):
    if not isinstance(features, dict) or set(features) != set(schema()['properties']):
        raise ValueError('Invalid calendar capabilities')
    if type(features['is_all_day']) is not bool: raise ValueError('Invalid all-day flag')
    if not isinstance(features['reason'], str) or not 0 < len(features['reason']) <= 500: raise ValueError('Calendar reason required')
    if not isinstance(features['unsupported'], list) or len(features['unsupported']) > 8 or any(not isinstance(x, str) or not 0 < len(x) <= 300 for x in features['unsupported']):
        raise ValueError('Invalid unsupported capabilities')
    notes = features['notes']
    if notes is not None and (not isinstance(notes, str) or not 0 < len(notes) <= 2000): raise ValueError('Invalid notes')
    url = features['url']
    if url is not None:
        if not isinstance(url, str) or len(url) > 2000 or url not in text or any(c.isspace() for c in url): raise ValueError('URL must be copied from source')
        parsed = urlsplit(url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password: raise ValueError('Unsupported URL')
    r = features['recurrence']
    if not isinstance(r, dict) or set(r) != set(schema()['properties']['recurrence']['properties']): raise ValueError('Invalid recurrence fields')
    if r['mode'] not in ('none', 'repeat', 'unresolved') or type(r['interval']) is not int or not 1 <= r['interval'] <= 99: raise ValueError('Invalid recurrence mode/interval')
    if not isinstance(r['reason'], str) or not 0 < len(r['reason']) <= 500: raise ValueError('Recurrence reason required')
    if r['evidence'] is not None and (not isinstance(r['evidence'], str) or not r['evidence'] or r['evidence'] not in text): raise ValueError('Recurrence evidence invalid')
    if r['mode'] != 'none' and r['evidence'] is None: raise ValueError('Recurrence requires evidence')
    for name, allowed in [('weekdays', set(range(1, 8))), ('month_days', {-1, *range(1, 32)}), ('months', set(range(1, 13)))]:
        values = r[name]
        if not isinstance(values, list) or any(type(n) is not int or n not in allowed for n in values) or len(set(values)) != len(values): raise ValueError('Invalid recurrence selectors')
    if r['mode'] != 'repeat':
        if r['frequency'] is not None or r['interval'] != 1 or r['weekdays'] or r['month_days'] or r['months'] or r['end_type'] != 'never' or r['count'] is not None or r['until'] is not None: raise ValueError('Non-repeating contract must be neutral')
        return
    if any(word in (r['evidence'] or '') for word in ('农历', '阴历', '调休', '法定')):
        raise ValueError('Unsupported calendar system cannot become a Gregorian rule')
    frequency = r['frequency']
    if frequency not in ('daily', 'weekly', 'monthly', 'yearly'): raise ValueError('Invalid recurrence frequency')
    if frequency == 'daily' and (r['weekdays'] or r['month_days'] or r['months']): raise ValueError('Daily selectors unsupported')
    if frequency == 'weekly' and (not r['weekdays'] or r['month_days'] or r['months']): raise ValueError('Weekly requires weekdays only')
    if frequency == 'monthly' and (r['weekdays'] or not r['month_days'] or r['months']): raise ValueError('Monthly requires month days only')
    if frequency == 'yearly' and (r['weekdays'] or not r['month_days'] or not r['months'] or -1 in r['month_days']): raise ValueError('Yearly requires months and positive days')
    if r['end_type'] == 'never':
        if r['count'] is not None or r['until'] is not None: raise ValueError('Unexpected recurrence end')
    elif r['end_type'] == 'count':
        if type(r['count']) is not int or not 1 <= r['count'] <= 1000 or r['until'] is not None: raise ValueError('Invalid recurrence count')
    elif r['end_type'] == 'until':
        if r['count'] is not None or not isinstance(r['until'], str): raise ValueError('Invalid recurrence until')
        if dt.date.fromisoformat(r['until']).isoformat() != r['until']: raise ValueError('Use YYYY-MM-DD until')
    else: raise ValueError('Invalid recurrence end type')
