def field(value, source='inferred', blocks=False):
    return dict(value=value, source=source, evidence=None, reason='测试上下文', critical=False, blocks_creation=blocks)

def plan():
    return dict(overflow=False,items=[dict(item_id='i1',kind='flexible',fields=dict(
        title=field('整理书架'),start_at=field('2030-09-28T14:00:00+08:00','defaulted'),
        end_at=field('2030-09-28T15:00:00+08:00','defaulted'),time_zone=field('Asia/Shanghai'),location=field(None,'unresolved')),
        alerts=dict(mode='disabled',evidence='不用提醒',reason='用户要求',count_limit=0,no_extra=True,overflow=False,items=[]),
        calendar=dict(is_all_day=False,notes=None,url=None,unsupported=[],reason='单次定时',recurrence=dict(mode='none',frequency=None,interval=1,weekdays=[],month_days=[],months=[],end_type='never',count=None,until=None,evidence=None,reason='未要求重复')))])

def route(kind='calendar'):
    return dict(kind=kind,message='测试范围判断',supported=['calendar'] if kind in ('calendar','mixed') else [],unsupported=['发送邮件'] if kind in ('mixed','unsupported') else [])

def envelope(kind='calendar'):
    return dict(route=route(kind),plan=plan() if kind=='calendar' else None)

def job(state='planned'):
    j=dict(submission_id='ax-test',task_id='ax-test',version=3,assistant_id='auto',text='明天下午整理书架，不用提醒',submitted_at='2030-09-27T12:00:00Z',time_zone='Asia/Shanghai',test_mode=True,lease_id='lease1',state=state,message='测试')
    if state=='planned':j.update(plan=plan(),route=route(),review_status='passed')
    return j
