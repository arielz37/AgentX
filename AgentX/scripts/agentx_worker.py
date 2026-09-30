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
from calendar_task import call, ROOT, timestamp
from agentx_config import load_model_env
from agentx_model import parse


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


def failure_message(code):
    if 'timeout_or_network' in code: return '模型服务暂时无法连接，本次没有写入日历。请稍后重新提交。'
    if 'parse_interrupted' in code: return 'Mac 解析被中断或结果未保存，本次没有进入手机执行。请检查 Mac 服务和磁盘空间。'
    if 'budget_exhausted' in code: return '模型处理超时，本次没有写入日历。请稍后重新提交。'
    if 'model_review_blocked' in code: return '模型复核未通过，本次没有写入日历。请补充或调整需求后提交。'
    return '模型未完成或输出未通过校验，本次没有写入日历。详细原因已记录在 Mac。'


def markdown(doc):
    job = doc.get('phone', {})
    lines = ['# AgentX 执行报告', '', '任务：' + job.get('submission_id', '—'),
             '手机状态：' + job.get('state', '尚未读取'), job.get('message', ''), '',
             '模型处理总耗时（Mac，含复核）：' + str(doc.get('model_elapsed_seconds', '未测量')) + ' 秒',
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
    rows = {r['item_id']: r for r in job.get('execution', {}).get('items', [])}
    for item in plan.get('items', []):
        fields = item['fields']; row = rows.get(item['item_id'], {})
        lines += ['## ' + (fields['title']['value'] or '标题空缺'),
                  '执行：' + row.get('status', '结果未知，等待核验' if job.get('state') in ('unknown', 'executing') else '未执行'),
                  '保存：' + row.get('save_status', '未知' if job.get('state') in ('unknown', 'executing') else '未尝试') + '；独立读回：' + row.get('verification_status', '未知' if job.get('state') in ('unknown', 'executing') else '未尝试')]
        for name, f in fields.items():
            lines.append(f"- {name}：{f['value'] or '空缺'} [{f['source']}]；{f['reason']}；阻止创建={f['blocks_creation']}")
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
        if row.get('readback'): lines.append('实际读回：' + json.dumps(row['readback'], ensure_ascii=False))
        if row.get('error'): lines.append('错误：' + json.dumps(row['error'], ensure_ascii=False))
        lines.append('')
    lines += ['模型只理解计划；保存和验证状态来自手机。未查询私人日历空闲时间。',
              '断连后的发送状态未知时，不自动重发；恢复连接后只查询真实记录。',
              '本报告不证明游戏帧率或全程画面无干扰。']
    return '\n'.join(lines) + '\n'


class Worker:
    def __init__(self, directory, model=parse, transport=rpc):
        self.directory, self.model, self.rpc = directory, model, transport

    def save(self, path, doc):
        atomic(path, doc)
        path.with_suffix('.md').write_text(markdown(doc))

    def process(self, job, host):
        # IDs originate on the phone but still validate before using as filenames.
        import re
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', job['submission_id']): raise ValueError('Invalid submission ID')
        path = self.directory / (job['submission_id'] + '.json')
        doc = json.loads(path.read_text()) if path.exists() else {'request': {k: job[k] for k in ('submission_id', 'task_id', 'version', 'text', 'submitted_at', 'time_zone', 'test_mode', 'assistant_id')}, 'attempts': {}}
        if any(job[k] != v for k, v in doc['request'].items()): raise ValueError('Submission content conflict')
        doc['phone'] = job; doc['observed_at'] = timestamp(); self.save(path, doc)
        params = identity(job)
        if job.get('execution') or job['state'] in ('verified', 'partial', 'not_completed', 'unknown', 'failed', 'unsupported', 'scope_mismatch', 'needs_clarification', 'mixed'): return
        if not job.get('plan') and not doc.get('route') and job['state'] in ('queued', 'parsing'):
            if doc.get('parse_started'):
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
                    response, doc['model'] = self.model(job)
                    doc['plan'] = response['plan']; doc['route'] = response['route']
                except Exception as error:
                    # Do not include arbitrary provider response/header contents.
                    doc['model_error'] = str(error) if isinstance(error, (RuntimeError, ValueError)) else type(error).__name__
                    if hasattr(error, 'rejected_plan'): doc['rejected_plan'] = error.rejected_plan
                    if hasattr(error, 'model_metadata'): doc['model'] = error.model_metadata
                doc['model_elapsed_seconds'] = round(time.monotonic() - started, 3)
                self.save(path, doc)
        if doc.get('model_error') and not job.get('plan'):
            self.rpc('plan_fail', {**params, 'message': failure_message(doc['model_error'])})
            return
        if doc.get('route') and not doc.get('plan'):
            doc['phone'] = self.rpc('plan_route', {**params, 'route': doc['route'], 'review_status': doc['model']['review']['status']})
            self.save(path, doc); return
        if doc.get('plan') and not job.get('plan'):
            job = self.rpc('plan_store', {**params, 'plan': doc['plan'], 'route': doc['route'], 'review_status': doc['model']['review']['status']})
            doc['phone'] = job; self.save(path, doc)
            # The host snapshot predates the model request: refresh before any execution.
            return
        if job.get('plan') and job['state'] == 'planned' and host.get('can_execute'):
            lease = job['lease_id']
            prior = doc['attempts'].get(lease, {})
            if prior and prior.get('status') != 'deferred_no_writes': return
            doc['attempts'][lease] = {**prior, 'sent_at': timestamp(), 'status': 'sent_result_unknown'}
            self.save(path, doc)  # No blind retry even if worker dies before send.
            try:
                response = self.rpc('plan_execute', {**params, 'lease_id': lease})
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
    worker = Worker(args.data_dir)
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
