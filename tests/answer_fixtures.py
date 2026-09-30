from copy import deepcopy

def query_job():
    query=dict(mode='free_slots',start_at='2030-10-02T14:00:00+08:00',end_at='2030-10-02T18:00:00+08:00',time_zone='Asia/Shanghai',duration_minutes=60,day_start_minute=840,day_end_minute=1080,assumptions=[])
    return dict(submission_id='ax-answer-test',task_id='ax-answer-test',version=5,assistant_id='calendar',text='10月2日下午两点到六点，找至少一小时的空档。',submitted_at='2030-09-30T12:00:00Z',time_zone='Asia/Shanghai',test_mode=True,lease_id='lease1',state='answer_pending',message='日历已读取',query=query,query_result_id='snapshot-1',execution={'status':'query_complete','items':[]})

def tool_context():
    return dict(source_id='snapshot-1',tool_name='calendar_query',status='query_complete',result=dict(
        request=deepcopy(query_job()['query']),queried_at='2030-09-30T12:00:10Z',event_count=2,busy_count=1,calendar_count=2,
        events=[dict(title='国庆假期',start_at='2030-10-01T16:00:00Z',end_at='2030-10-02T16:00:00Z',is_all_day=True,calendar_name='中国大陆节假日',blocks_time=False,occupancy_reason='只读节假日订阅仅展示，不占时'),
                dict(title='整理书架',start_at='2030-10-02T07:00:00Z',end_at='2030-10-02T08:00:00Z',is_all_day=False,calendar_name='个人',blocks_time=True,occupancy_reason='个人安排')],
        events_truncated=False,free_slots=[dict(start_at='2030-10-02T06:00:00Z',end_at='2030-10-02T07:00:00Z'),dict(start_at='2030-10-02T08:00:00Z',end_at='2030-10-02T10:00:00Z')],slots_truncated=False,scope_note='当前手机日历快照；空档没有预留。'))

def model_answer():
    return dict(text='模型生成的回答正文',source_id='snapshot-1',model='test-model',generated_at='2030-09-30T12:00:12Z')
