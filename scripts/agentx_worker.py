#!/usr/bin/env python3
"""Mac GPT worker. Reuses PhoneAgent rpc.py; every calendar write stays on iPhone."""
import argparse
import hashlib
import json
import os
import shutil
import errno
from pathlib import Path
import time
import threading
from model_transport import request_journal
from calendar_task import call, ROOT, timestamp
from agentx_config import load_model_env
from agentx_model import parse
from tool_answer import answer_from_tool, bounded_context, bounded_execution_context
from calendar_schedule import schedule_from_tool, validate as validate_schedule
from calendar_mutation import decide as decide_mutation, validate as validate_mutation


def atomic(path, document):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = json.dumps(document, ensure_ascii=False, indent=2) + '\n'
    tmp = path.with_suffix('.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(data); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)


def rpc(method, params):
    response = call(method, params, timeout=8)
    if 'error' in response: raise RuntimeError(response['error']['message'])
    return response['result']


def identity(job):
    return {key: job[key] for key in ('submission_id', 'task_id', 'version', 'assistant_id')}


def failure_reason(code):
    if 'answer_review' in code: return '答复的事实复核未能完成，已保留实际接口结果；可以重新生成答复。'
    if 'model_quota_exhausted' in code: return '模型账户额度不足，需检查 API 账户。'
    if 'model_http_401' in code or 'model_http_403' in code: return '模型服务拒绝授权，请检查本机 API 配置。'
    if 'model_http_429' in code: return '模型服务限流，有限重试后仍未恢复。'
    if any(c in code for c in ('model_request_timeout', 'model_stage_timeout', 'budget_exhausted')): return '模型处理超过等待时限，已停止本阶段。'
    if any(c in code for c in ('model_network_error', 'model_connection_interrupted', 'timeout_or_network', 'model_http_5', 'model_provider_temporary_error')): return '模型网络或服务暂时不可用，有限重试后仍未恢复。'
    if 'model_provider_failed' in code: return '模型服务返回处理失败，未取得完整结果。'
    if 'model_output_limit' in code: return '模型输出达到长度上限，未使用截断的计划。'
    if 'model_refused' in code or 'model_filtered' in code: return '模型服务未接受本次请求。'
    if 'interrupted' in code: return 'Mac 模型处理被中断，恢复次数已用完或旧任务没有恢复记录。'
    if 'model_review_contract_invalid' in code: return '模型纠正后的结果仍不符合执行要求，已停止执行；具体校验原因已记录在 Mac。'
    if 'review' in code.lower(): return '模型复核未通过，请查看报告并补充或调整需求。'
    return '模型输出未通过校验，具体原因已记录在 Mac。'


def failure_message(code):
    if 'timeout_or_network' in code: return '模型服务暂时无法连接，本次没有写入日历。请稍后重新提交。'
    if 'parse_interrupted' in code: return 'Mac 解析被中断或结果未保存，本次没有进入手机执行。请检查 Mac 服务和磁盘空间。'
    if 'budget_exhausted' in code: return '模型处理超时，本次没有写入日历。请稍后重新提交。'
    if 'model_review_blocked' in code: return '模型复核未通过，本次没有写入日历。请补充或调整需求后提交。'
    return failure_reason(code) + ' 本次没有写入日历。'


def markdown(doc):
    job = doc.get('phone', {})
    lines = ['# AgentX 执行报告', '', '任务：' + job.get('submission_id', '—'),
             '手机状态：' + job.get('state', '尚未读取'), job.get('message', ''), '',
             '理解与计划复核耗时（Mac）：' + str(doc.get('model_elapsed_seconds', '未测量')) + ' 秒',
             '执行发送记录：' + json.dumps(doc.get('attempts', {}), ensure_ascii=False), '']
    review = doc.get('model', {}).get('review')
    if review:
        lines += ['模型复核：' + review.get('status', '未知'),
                  '复核耗时：' + str(doc.get('model', {}).get('review_seconds', '未测量')) + ' 秒',
                  '复核发现：' + json.dumps(review.get('result', {}).get('issues', []), ensure_ascii=False),
                  '实际修改：' + json.dumps(review.get('changes', []), ensure_ascii=False),
                  '复核是模型检查，不能代替手机保存与独立读回，也不保证理解绝对正确。', '']
    else: lines += ['模型复核：历史任务未记录；不自动重新解析或执行。', '']
    if doc.get('route'): lines += ['能力判断：' + json.dumps(doc['route'], ensure_ascii=False), '']
    plan = job.get('plan') or doc.get('plan') or {}
    if job.get('query'):
        lines += ['查询参数：' + json.dumps(job['query'], ensure_ascii=False), '查询摘要：' + json.dumps(job.get('execution', {}), ensure_ascii=False),
                  '本任务的查询数据经 Mac 发给模型回答。' if job.get('version',0)>=5 else '历史任务：已有事件详情仅保存在手机，没有自动上传。', '']
    if doc.get('answer'):lines += ['模型回答：',doc['answer']['text'],'', '回答依据：'+doc['answer']['source_id']]
    if doc.get('answer_elapsed_seconds') is not None:lines += ['回答及事实复核耗时：'+str(doc['answer_elapsed_seconds'])+' 秒']
    if doc.get('answer_error'):lines += ['答复生成失败；实际日历执行结果单独保留，没有使用模板兜底。', '答复错误：'+doc['answer_error']]
    if job.get('schedule') or doc.get('schedule'):
        decision=job.get('schedule') or doc['schedule']
        lines += ['模型排程说明：'+decision['message'], '排程依据快照：'+decision['source_id'], '排程决策不等于保存成功，实际执行以下方为准。', '排程与复核耗时：'+str(doc.get('schedule_elapsed_seconds','未测量'))+' 秒']
    if doc.get('schedule_error'):lines += ['排程失败：'+doc['schedule_error']]
    if job.get('mutation'):
        lines += ['修改/删除决策：'+job['mutation']['message'],'实际执行：'+json.dumps(job.get('execution',{}),ensure_ascii=False)]
    rows = {r['item_id']: r for r in job.get('execution', {}).get('items', [])}
    for item in plan.get('items', []):
        fields = item['fields']; row = rows.get(item['item_id'], {})
        lines += ['## ' + (fields['title'].get('value') or '标题空缺'),
                  '执行：' + row.get('status', '结果未知，等待核验' if job.get('state') in ('unknown', 'executing') else '未执行'),
                  '保存：' + row.get('save_status', '未知' if job.get('state') in ('unknown', 'executing') else '未尝试') + '；独立读回：' + row.get('verification_status', '未知' if job.get('state') in ('unknown', 'executing') else '未尝试')]
        for name, f in fields.items():
            lines.append(f"- {name}：{f.get('value') or '空缺'} [{f['source']}]；{f['reason']}；阻止创建={f['blocks_creation']}")
        features = item.get('calendar')
        if features:
            lines += ['日历要求（实际结果以下方读回为准）：' + json.dumps(features, ensure_ascii=False),
                      '全天事件的结束日期为排他边界；重复是一条系列，未来发生由系统日历生成。']
            if features['unsupported'] or features['recurrence']['mode'] == 'unresolved':
                lines.append('日历要求未解决，本项不降级为单次事件。')
        alerts = item.get('alerts')
        if alerts is None:
            lines.append('历史无提醒计划；不作新版提醒验收声明。')
        else:
            lines += ['提醒模式：' + alerts['mode'], '提醒依据：' + alerts['reason'],
                      '原始提醒请求：' + json.dumps(alerts, ensure_ascii=False)]
            actual = row.get('alerts')
            if actual:
                lines += ['事件字段验证：' + row.get('event_verification_status', '未验证'),
                          '提醒配置验证：' + actual['verification_status'],
                          '用户提醒要求满足：' + actual['user_requirement_status'],
                          '实际准备写入：' + json.dumps(actual['configured'], ensure_ascii=False),
                          '逐条处理：' + json.dumps(actual['decisions'], ensure_ascii=False),
                          '策略原因：' + str(actual.get('policy_reason')),
                          '实际提醒读回：' + json.dumps(actual.get('readback'), ensure_ascii=False)]
            else: lines.append('提醒尚未执行，不能将请求或建议当作已配置。')
            lines.append('提醒配置成功不等于未来通知已送达；通知展示受系统日历通知、专注模式等设置影响。')
        if row.get('conflict_check'): lines.append('写入前冲突检查：' + json.dumps(row['conflict_check'], ensure_ascii=False))
        if row.get('readback'): lines.append('实际读回：' + json.dumps(row['readback'], ensure_ascii=False))
        if row.get('error'): lines.append('错误：' + json.dumps(row['error'], ensure_ascii=False))
        lines.append('')
    lines += ['模型只理解请求；查询、冲突检查、保存和验证结果来自手机。旧任务不补做新检查。',
              '断连后的发送状态未知时，不自动重发；恢复连接后只查询真实记录。',
              '本报告不证明游戏帧率或全程画面无干扰。']
    return '\n'.join(lines) + '\n'


class Worker:
    def __init__(self, directory, model=parse, transport=rpc, answer_model=answer_from_tool, schedule_model=schedule_from_tool, mutation_model=decide_mutation, keepalive=False):
        self.directory, self.model, self.rpc = directory, model, transport
        self.answer_model = answer_model
        self.schedule_model = schedule_model
        self.mutation_model = mutation_model
        self.keepalive = keepalive

    def can_resume_model(self, doc, phase):
        # Old interrupted jobs are not silently re-uploaded. New inference-only
        # stages may recover once; RPC delivery/lease journals stay unchanged.
        return 0 < doc.get('model_runs', {}).get(phase, 0) < 2

    def run_model(self, phase, model, args, doc, path):
        runs = doc.setdefault('model_runs', {})
        runs[phase] = runs.get(phase, 0) + 1
        entries = doc.setdefault('model_checkpoints', {}).setdefault(phase, {})
        self.save(path, doc)
        stop = threading.Event()

        def heartbeat():
            while not stop.is_set():
                try:
                    self.rpc('plan_heartbeat', {**identity(doc['phone']), 'model_ready': True, 'phase': phase})
                except Exception:
                    pass  # Disconnect does not cancel or re-execute inference.
                stop.wait(2)

        thread = threading.Thread(target=heartbeat, daemon=True) if self.keepalive else None
        if thread: thread.start()
        try:
            with request_journal(entries, lambda: self.save(path, doc)):
                return model(*args)
        except Exception as error:
            if hasattr(error, 'request_metadata'):
                doc.setdefault('model_request_errors', {})[phase] = error.request_metadata
            raise
        finally:
            stop.set()

    def save(self, path, doc):
        atomic(path, doc)
        # JSON is the execution journal. A secondary human-readable report must
        # not block the next phase after the journal was durably saved.
        try:
            path.with_suffix('.md').write_text(markdown(doc))
        except (KeyError, TypeError, ValueError, OSError) as error:
            doc['report_error'] = type(error).__name__
            atomic(path, doc)
        else:
            if doc.pop('report_error', None) is not None:
                atomic(path, doc)

    def process(self, job, host):
        # IDs originate on the phone but still validate before using as filenames.
        import re
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', job['submission_id']): raise ValueError('Invalid submission ID')
        path = self.directory / (job['submission_id'] + '.json')
        doc = json.loads(path.read_text()) if path.exists() else {'request': {k: job[k] for k in ('submission_id', 'task_id', 'version', 'text', 'submitted_at', 'time_zone', 'test_mode', 'assistant_id')}, 'attempts': {}}
        if any(job[k] != v for k, v in doc['request'].items()): raise ValueError('Submission content conflict')
        doc['phone'] = job; doc['observed_at'] = timestamp(); self.save(path, doc)
        params = identity(job)
        if job.get('version',0)>=8 and job.get('completion_source_id'):
            self.process_answer(job,doc,path,completion=True);return
        if job.get('version',0)>=7 and job.get('route',{}).get('kind')=='calendar_mutation' and job.get('mutation_source_id'):
            self.process_mutation(job,host,doc,path);return
        if job.get('version',0)>=6 and job.get('route',{}).get('kind')=='calendar_schedule' and job.get('query_result_id'):
            self.process_schedule(job,host,doc,path); return
        if job.get('version',0)>=5 and job.get('query_result_id'):
            self.process_answer(job,doc,path); return
        if job.get('execution') or job['state'] in ('verified', 'partial', 'not_completed', 'unknown', 'failed', 'unsupported', 'scope_mismatch', 'needs_clarification', 'mixed', 'query_complete'): return
        if not (job.get('plan') or job.get('query')) and not doc.get('route') and job['state'] in ('queued', 'parsing'):
            if doc.get('parse_started') and not self.can_resume_model(doc, 'parse'):
                doc.setdefault('model_error', 'parse_interrupted_or_result_not_durable; no automatic retry')
            elif not os.environ.get('OPENAI_API_KEY'):
                return
            else:
                # Fail before model work if a durable result cannot reasonably fit.
                if shutil.disk_usage(self.directory).free < 32 * 1024 * 1024:
                    self.rpc('plan_fail', {**params, 'message': 'Mac 磁盘空间不足，日历未执行。请先释放空间。'})
                    return
                # Local input is durable before acknowledging handoff.
                self.rpc('plan_claim', params)
                doc['parse_started'] = timestamp(); self.save(path, doc)
                started = time.monotonic()
                try:
                    response, doc['model'] = self.run_model('parse', self.model, (job,), doc, path)
                    doc['plan'] = response['plan']; doc['route'] = response['route']; doc['query'] = response.get('query'); doc['schedule_request'] = response.get('schedule_request')
                except Exception as error:
                    # Do not include arbitrary provider response/header contents.
                    doc['model_error'] = str(error) if isinstance(error, (RuntimeError, ValueError)) else type(error).__name__
                    if hasattr(error, 'rejected_plan'): doc['rejected_plan'] = error.rejected_plan
                    if hasattr(error, 'model_metadata'): doc['model'] = error.model_metadata
                doc['model_elapsed_seconds'] = round(time.monotonic() - started, 3)
                self.save(path, doc)
        if doc.get('model_error') and not (job.get('plan') or job.get('query')):
            self.rpc('plan_fail', {**params, 'message': failure_message(doc['model_error'])})
            return
        if doc.get('route') and not doc.get('plan') and not doc.get('query'):
            doc['phone'] = self.rpc('plan_route', {**params, 'route': doc['route'], 'review_status': doc['model']['review']['status']})
            self.save(path, doc); return
        if (doc.get('plan') or doc.get('query')) and not (job.get('plan') or job.get('query')):
            job = self.rpc('plan_store', {**params, 'plan': doc['plan'], 'route': doc['route'], 'review_status': doc['model']['review']['status'], 'query': doc.get('query'), 'schedule_request': doc.get('schedule_request')})
            doc['phone'] = job; self.save(path, doc)
            # The host snapshot predates the model request: refresh before any execution.
            return
        if (job.get('plan') or job.get('query')) and job['state'] == 'planned' and host.get('can_execute'):
            lease = job['lease_id']
            prior = doc['attempts'].get(lease, {})
            if prior and prior.get('status') != 'deferred_no_writes': return
            doc['attempts'][lease] = {**prior, 'sent_at': timestamp(), 'status': 'sent_result_unknown'}
            self.save(path, doc)  # No blind retry even if worker dies before send.
            try:
                response = self.rpc('plan_execute', {**params, 'lease_id': lease})
                if response.get('mutation_context'):doc['mutation_context']=response.pop('mutation_context')
                if response.get('answer_context'):
                    doc['answer_context'] = response.pop('answer_context')
                if response.get('completion_context'):
                    doc['completion_context'] = response.pop('completion_context')
                doc['phone'] = response
                if response.get('execution_deferred') is True and response.get('deferred_reason') == 'application_transition_no_writes':
                    doc['attempts'][lease]['status'] = 'deferred_no_writes'
                    doc['attempts'][lease]['deferrals'] = prior.get('deferrals', 0) + 1
                else:
                    doc['attempts'][lease]['status'] = 'response_received'
            except Exception:
                # Only phone records can resolve this uncertainty; never retry execution.
                doc['attempts'][lease]['status'] = 'sent_result_unknown'
            self.save(path, doc)
            if doc['phone'].get('completion_source_id'):
                self.process_answer(doc['phone'],doc,path,completion=True)
            elif doc['phone'].get('route',{}).get('kind')=='calendar_mutation' and doc['phone'].get('mutation_source_id'):
                self.process_mutation(doc['phone'],host,doc,path)
            elif doc['phone'].get('route',{}).get('kind')=='calendar_schedule' and doc['phone'].get('query_result_id'):
                self.process_schedule(doc['phone'],host,doc,path)
            elif doc['phone'].get('version',0)>=5 and doc['phone'].get('query_result_id'):
                self.process_answer(doc['phone'],doc,path)

    def process_mutation(self,job,host,doc,path):
        params=identity(job)
        if job['state']=='mutation_pending':
            if not doc.get('mutation') and not doc.get('mutation_error'):
                if doc.get('mutation_started') and not self.can_resume_model(doc, 'mutation'):
                    doc['mutation_error']='mutation_interrupted_or_result_not_durable; no automatic retry'
                elif not os.environ.get('OPENAI_API_KEY'):return
                else:
                    if not doc.get('mutation_context'):
                        doc['mutation_context']=self.rpc('plan_mutation_context',params)
                    doc['mutation_started']=timestamp();self.save(path,doc)
                    started=time.monotonic()
                    try:
                        doc['mutation'],doc['mutation_model']=self.run_model('mutation', self.mutation_model, (job,doc['mutation_context']), doc,path)
                        validate_mutation(doc['mutation'],job,doc['mutation_context'])
                    except Exception as error:
                        doc.pop('mutation',None)
                        doc['mutation_error']=str(error) if isinstance(error,(RuntimeError,ValueError)) else type(error).__name__
                        if hasattr(error,'model_metadata'):doc['mutation_model']=error.model_metadata
                    doc['mutation_elapsed_seconds']=round(time.monotonic()-started,3)
                self.save(path,doc)
            if doc.get('mutation_error'):
                response=self.rpc('plan_mutation_fail',{**params,'source_id':job['mutation_source_id'], 'message':failure_reason(doc['mutation_error'])+' 没有修改或删除事件。'})
            else:
                response=self.rpc('plan_mutation_store',{**params,'mutation':doc['mutation']})
            doc['phone']=response;doc['mutation_delivery']='acknowledged';self.save(path,doc)
            # Poll a fresh host budget before the separate write phase.
            return
        if job['state']=='planned' and job.get('mutation',{}).get('decision')=='execute' and host.get('can_execute'):
            key='mutation_write:'+job['lease_id']
            prior=doc['attempts'].get(key,{})
            if prior and prior.get('status')!='deferred_no_writes':return
            doc['attempts'][key]={'sent_at':timestamp(),'status':'sent_result_unknown'};self.save(path,doc)
            try:
                response=self.rpc('plan_execute',{**params,'lease_id':job['lease_id']})
                if response.get('completion_context'):doc['completion_context']=response.pop('completion_context')
                doc['phone']=response
                doc['attempts'][key]['status']='deferred_no_writes' if response.get('execution_deferred') is True and response.get('deferred_reason')=='application_transition_no_writes' else 'response_received'
            except Exception:
                pass # Unknown delivery is reconciled only from the phone, never resent.
            self.save(path,doc)

    def process_schedule(self,job,host,doc,path):
        params=identity(job)
        if job['state']=='schedule_pending':
            if not doc.get('schedule') and not doc.get('schedule_error'):
                if doc.get('schedule_started') and not self.can_resume_model(doc, 'schedule'):
                    doc['schedule_error']='schedule_interrupted_or_result_not_durable; no automatic retry'
                elif not os.environ.get('OPENAI_API_KEY'):return
                else:
                    if not doc.get('answer_context'):
                        doc['answer_context']=self.rpc('plan_answer_context',params)
                    doc['schedule_started']=timestamp();self.save(path,doc)
                    started=time.monotonic()
                    try:
                        doc['schedule'],doc['schedule_model']=self.run_model('schedule', self.schedule_model, (job,doc['answer_context']), doc,path)
                        validate_schedule(doc['schedule'],job,doc['answer_context'])
                    except Exception as error:
                        doc.pop('schedule',None)
                        doc['schedule_error']=str(error) if isinstance(error,(RuntimeError,ValueError)) else type(error).__name__
                        if hasattr(error,'model_metadata'):doc['schedule_model']=error.model_metadata
                    doc['schedule_elapsed_seconds']=round(time.monotonic()-started,3)
                self.save(path,doc)
            if doc.get('schedule_error'):
                response=self.rpc('plan_schedule_fail',{**params,'source_id':job['query_result_id'], 'message':failure_reason(doc['schedule_error'])+' 没有创建事项。'})
            else:
                response=self.rpc('plan_schedule_store',{**params,'schedule':doc['schedule']})
            doc['phone']=response;doc['schedule_delivery']='acknowledged';self.save(path,doc)
            # Poll a fresh host budget before the separate write phase.
            return
        if job['state']=='planned' and job.get('schedule',{}).get('decision')=='scheduled' and host.get('can_execute'):
            key='schedule_write:'+job['lease_id']
            prior=doc['attempts'].get(key,{})
            if prior and prior.get('status')!='deferred_no_writes':return
            doc['attempts'][key]={'sent_at':timestamp(),'status':'sent_result_unknown'};self.save(path,doc)
            try:
                response=self.rpc('plan_execute',{**params,'lease_id':job['lease_id']})
                if response.get('completion_context'):doc['completion_context']=response.pop('completion_context')
                doc['phone']=response
                doc['attempts'][key]['status']='deferred_no_writes' if response.get('execution_deferred') is True and response.get('deferred_reason')=='application_transition_no_writes' else 'response_received'
            except Exception:
                pass # Unknown delivery is reconciled only from the phone, never resent.
            self.save(path,doc)

    def process_answer(self,job,doc,path,completion=False):
        # Reading and answering are distinct. Delivery may resume after the phone's
        # finite window ends, but neither EventKit nor the model is blindly replayed.
        if job.get('answer') or (job.get('completion_answer_state')=='failed' if completion else job['state']=='answer_failed'):return
        if (job.get('completion_answer_state') if completion else job['state'])!=('pending' if completion else 'answer_pending'):return
        params=identity(job);source=job['completion_source_id' if completion else 'query_result_id']
        prefix='plan_completion' if completion else 'plan_answer'
        context_key='completion_context' if completion else 'answer_context'
        phase='completion_answer' if completion else 'answer'
        retry_id=job.get('answer_retry_id')
        if retry_id != doc.get('answer_retry_id'):
            if not isinstance(retry_id,str) or not 0<len(retry_id)<=80:raise ValueError('Invalid answer retry ID')
            # Only a new phone-persisted user action opens a new inference budget.
            # Archive failed attempts. Keep the immutable result and write journal.
            keys=('answer','answer_error','answer_started','answer_elapsed_seconds','answer_model','answer_delivery')
            archived={k:doc.pop(k) for k in keys if k in doc}
            archived['retry_id']=doc.get('answer_retry_id')
            archived['checkpoints']=doc.get('model_checkpoints',{}).pop(phase,{})
            archived['model_runs']=doc.get('model_runs',{}).pop(phase,0)
            archived['request_errors']=doc.get('model_request_errors',{}).pop(phase,None)
            doc.setdefault('answer_attempt_history',[]).append(archived)
            doc['answer_retry_id']=retry_id
            self.save(path,doc)
        if retry_id:params['answer_retry_id']=retry_id
        if not doc.get('answer') and not doc.get('answer_error'):
            if doc.get('answer_started') and not self.can_resume_model(doc, phase):
                doc['answer_error']='answer_interrupted_or_result_not_durable; no automatic retry'
            elif not os.environ.get('OPENAI_API_KEY'):return
            else:
                if not doc.get(context_key):
                    doc[context_key]=self.rpc(prefix+'_context',params)
                doc['answer_started']=timestamp();self.save(path,doc)
                started=time.monotonic()
                try:
                    (bounded_execution_context if completion else bounded_context)(job,doc[context_key])
                    doc['answer'],doc['answer_model']=self.run_model(phase, self.answer_model, (job,doc[context_key]), doc,path)
                    if doc['answer']['source_id']!=source:raise ValueError('Answer source mismatch')
                except Exception as error:
                    doc.pop('answer',None)
                    doc['answer_error']=str(error) if isinstance(error,(RuntimeError,ValueError)) else type(error).__name__
                    if hasattr(error,'model_metadata'):doc['answer_model']=error.model_metadata
                doc['answer_elapsed_seconds']=round(time.monotonic()-started,3)
            self.save(path,doc) # Persist generated answer before any phone delivery.
        if doc.get('answer_error'):
            response=self.rpc(prefix+'_fail',{**params,'source_id':source, 'message':failure_reason(doc['answer_error'])+(' 实际执行记录已保存，可查看详情；没有重复执行日历操作。' if completion else ' 日历已读取，可查看原始结果；没有重新执行日历操作。')})
        else:
            response=self.rpc(prefix+'_store',{**params,'answer':doc['answer']})
        doc['phone']=response;doc['answer_delivery']='acknowledged';self.save(path,doc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'data')
    args = parser.parse_args()
    os.umask(0o077)
    load_model_env()
    # Exclusive worker lock avoids two model parsers racing the same submission.
    import fcntl
    args.data_dir.mkdir(parents=True, exist_ok=True)
    lock = (args.data_dir / '.worker.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('A worker already uses this data directory.')
    worker = Worker(args.data_dir, keepalive=True)
    print('AgentX worker ready; model key configured=' + str(bool(os.environ.get('OPENAI_API_KEY'))), flush=True)
    last_status = None
    while True:
        try:
            result = rpc('plan_poll', {'model_ready': bool(os.environ.get('OPENAI_API_KEY'))})
            for job in result['jobs']: worker.process(job, result['host'])
            status = 'connected (no phone UI automation)'
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            status = ('Mac 磁盘空间不足，暂停处理；未自动重放。' if isinstance(error, OSError) and error.errno == errno.ENOSPC else 'disconnected or rejected: ' + type(error).__name__ + '; waiting, no execution replay')
        if status != last_status: print(status, flush=True); last_status = status
        time.sleep(0.7)


if __name__ == '__main__':
    try: main()
    except KeyboardInterrupt: pass
