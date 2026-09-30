"""Bounded query contract. Initial parsing has no events; a separate answer call consumes actual tool results."""
import datetime as dt
import calendar
from zoneinfo import ZoneInfo
from model_contract import obj

QUERY_PROMPT = '''
新增只读能力：calendar_query。supported=["calendar"],unsupported=[],plan=null，query填写范围。
“明天有哪些安排”使用events；“明天14点到15点有没有冲突”使用conflicts；“下周什么时候有空/找一小时空档”使用free_slots。
query包含mode(events/conflicts/free_slots)、start_at/end_at（带秒和时区偏移ISO8601，end为不含的边界）、time_zone、duration_minutes、day_start_minute、day_end_minute、assumptions。
日期字符串必须用time_zone当地偏移表示，例如Asia/Shanghai用+08:00，不用Z表示当地时间。禁止24:00，整天结束写次日00:00。
day_start_minute/day_end_minute的单位是分钟，不是小时！14点=840，18点=1080；09:30=570。每日14–18点必须写840和1080，不能写14和18。查询周一到周五可用周一00:00到周六00:00作为外层范围，每日时段另填。
依据冻结提交时间推导“本周/下周”，周一开始。整日范围是当地0点到次日0点。一次最多一个日历年，限制的是查询起止之间的跨度（end_at <= start_at加一个日历年），不是只能查提交日起未来一年！用户可以查询过去或未来任意一个完整公历年，不得因查询结束晚于提交日一年而拒绝；1月1日至次年1月1日恰好一年，允许等于上限。超出跨度或无法判断日期时clarify，不截断后宣称已查全部。
仅查询未指定日期时默认今天并在assumptions说明；“最近”可默认未来7天并说明。空闲建议默认60分钟、每日09:00–21:00，每项默认都在assumptions用中文注明；明确给出的时长和时段必须遵循。duration_minutes为15到480整数分钟，day_start/end为当地午夜起的分钟数(0...1440)，同日结束大于开始；无法支持的跨午夜每日窗口应clarify，不擅自改成白天。
查询已有日程是真正支持的能力；你只是生成查询参数，尚未读取日历。禁止虚构事件或空闲，禁止在route.message宣称查到结果。
创建仍为calendar，不携带query；手机会对新提交的事项作写入前冲突检查，有冲突不写入、不自动改期。
当前不支持一步“查询空闲并自动选时创建”、复杂条件筛选、修改或删除。此类请求请说明先查询、再由用户提交具体创建请求；不能忽略这些条件直接猜时间创建。单纯请求列出空闲建议应直接calendar_query。
例如“找明天空闲并自动安排练琴”必须返回clarify、plan=null、query=null，message说明先单独查询空闲再选择时间创建；不能只做查询却暗示即将自动安排。“查询未来两年所有日程”超过一年必须clarify，不截断后宣称完整。
非查询路由query=null；本阶段还没有已有日历数据；读取后将由另一次模型请求基于接口结果回答。复核必须同时核对查询模式、日期范围、星期、时区及用户明确的时长/每日窗口。查询计划不适用“items非空”规则。
'''

def schema(extended=False):
    result = obj({'mode':{'type':'string','enum':['events','conflicts','free_slots']},
        'start_at':{'type':'string','description':'Inclusive local ISO8601 timestamp with seconds and the actual offset for time_zone, e.g. 2030-09-30T00:00:00+08:00'},'end_at':{'type':'string','description':'Exclusive local timestamp; maximum one calendar year after start. Friday inclusive ends Saturday 00:00.'},'time_zone':{'type':'string'},
        'duration_minutes':{'type':'integer','minimum':15,'maximum':480},
        'day_start_minute':{'type':'integer','minimum':0,'maximum':1439,'description':'MINUTES since local midnight: 14:00 = 840, 09:30 = 570. Never hours.'},
        'day_end_minute':{'type':'integer','minimum':1,'maximum':1440,'description':'MINUTES since local midnight: 18:00 = 1080, end of day = 1440. Never hours.'},
        'assumptions':{'type':'array','maxItems':8,'items':{'type':'string','minLength':1,'maxLength':300}}})
    if extended:
        result['properties'].update(slot_kind={'type':'string','enum':['timed','all_day']},duration_days={'type':'integer','minimum':1,'maximum':366},target_history_refs={'type':'array','maxItems':8,'items':{'type':'string'}})
        result['required']+=['slot_kind','duration_days','target_history_refs']
    return result

def validate(query):
    if not isinstance(query,dict) or not set(schema()['properties'])<=set(query)<=set(schema(True)['properties']):raise ValueError('Invalid query envelope')
    if query['mode'] not in ('events','conflicts','free_slots'):raise ValueError('Invalid query mode')
    for key,low,high in [('duration_minutes',15,480),('day_start_minute',0,1439),('day_end_minute',1,1440)]:
        if type(query[key]) is not int or not low<=query[key]<=high:raise ValueError('Invalid query window/duration')
    if query['day_start_minute']>=query['day_end_minute']:raise ValueError('Query daily window must end after start')
    if query.get('slot_kind','timed') not in ('timed','all_day') or type(query.get('duration_days',1)) is not int or not 1<=query.get('duration_days',1)<=366:raise ValueError('Invalid all-day query')
    if query.get('slot_kind')=='all_day' and (query['day_start_minute']!=0 or query['day_end_minute']!=1440):raise ValueError('All-day availability requires full civil days')
    refs=query.get('target_history_refs',[])
    if not isinstance(refs,list) or len(refs)>8 or any(not isinstance(x,str) or not 0<len(x)<=160 for x in refs) or len(set(refs))!=len(refs):raise ValueError('Invalid history reference list')
    a=query['assumptions']
    if not isinstance(a,list) or len(a)>8 or any(not isinstance(x,str) or not 0<len(x)<=300 for x in a):raise ValueError('Invalid query assumptions')
    try:
        zone=ZoneInfo(query['time_zone'])
        def parse(value):
            date=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
            if date.tzinfo is None or date.astimezone(zone).isoformat(timespec='seconds').replace('+00:00','Z') != value.replace('+00:00','Z'):
                raise ValueError('Query time/offset mismatch')
            return date.astimezone(zone)
        start,end=parse(query['start_at']),parse(query['end_at'])
        utc=dt.timezone.utc
        if not start.astimezone(utc) < end.astimezone(utc) <= start.replace(year=start.year+1,day=min(start.day,calendar.monthrange(start.year+1,start.month)[1])).astimezone(utc):raise ValueError('Query range must be at most one calendar year')
    except (TypeError,KeyError,AttributeError) as error:raise ValueError('Invalid query time/zone') from error
    return query

def review_facts(value):
    """Expose the literal executable meaning, without repairing model choices."""
    if not isinstance(value,dict):return None
    facts={}
    try:validate(value)
    except ValueError as error:facts['validation_error']=str(error)
    for key in ('day_start_minute','day_end_minute'):
        minute=value.get(key)
        if type(minute) is int:facts[key+'_as_clock']=f'{minute//60:02d}:{minute%60:02d}'
    try:
        zone=ZoneInfo(value['time_zone'])
        local_values={}
        for key in ('start_at','end_at'):
            instant=dt.datetime.fromisoformat(value[key].replace('Z','+00:00'))
            if instant.tzinfo is not None:
                local=instant.astimezone(zone)
                facts[key+'_local']=local.isoformat(timespec='seconds')
                facts[key+'_iso_weekday']=local.isoweekday()
                local_values[key]=local
        if len(local_values)==2:
            a,b=local_values['start_at'],local_values['end_at']
            allowed=a.replace(year=a.year+1,day=min(a.day,calendar.monthrange(a.year+1,a.month)[1]))
            facts['range_limit_basis']='query_start_not_submission_date'
            facts['maximum_allowed_end_at']=allowed.isoformat(timespec='seconds')
            facts['range_within_one_calendar_year']=a.astimezone(dt.timezone.utc)<b.astimezone(dt.timezone.utc)<=allowed.astimezone(dt.timezone.utc)
            if 0 <= (b.date()-a.date()).days <= 366:
                days=[];day=a.date()
                while day<=b.date():
                    if day<b.date() or b.time().replace(tzinfo=None)>dt.time():
                        days.append(dict(date=day.isoformat(),iso_weekday=day.isoweekday()))
                    day+=dt.timedelta(days=1)
                facts['all_dates_in_outer_range']=days
    except (ValueError,TypeError,KeyError,AttributeError):pass
    return facts
