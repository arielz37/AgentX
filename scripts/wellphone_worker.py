#!/usr/bin/env python3
"""Mac GPT worker. Reuses PhoneAgent rpc.py; every calendar write stays on iPhone."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
from calendar_task import call, ROOT, timestamp
from wellphone_model import load_env, parse


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
    return {key: job[key] for key in ('submission_id', 'task_id', 'version')}


def markdown(doc):
    job = doc.get('phone', {})
    lines = ['# Wellphone 执行报告', '', '任务：' + job.get('submission_id', '—'),
             '手机状态：' + job.get('state', '尚未读取'), job.get('message', ''), '',
             '模型解析耗时（Mac）：' + str(doc.get('model_elapsed_seconds', '未测量')) + ' 秒',
             '执行发送记录：' + json.dumps(doc.get('attempts', {}), ensure_ascii=False), '']
    plan = job.get('plan') or doc.get('plan') or {}
    rows = {r['item_id']: r for r in job.get('execution', {}).get('items', [])}
    for item in plan.get('items', []):
        fields = item['fields']; row = rows.get(item['item_id'], {})
        lines += ['## ' + (fields['title']['value'] or '标题空缺'),
                  '执行：' + row.get('status', '结果未知，等待核验' if job.get('state') in ('unknown', 'executing') else '未执行'),
                  '保存：' + row.get('save_status', '未知' if job.get('state') in ('unknown', 'executing') else '未尝试') + '；独立读回：' + row.get('verification_status', '未知' if job.get('state') in ('unknown', 'executing') else '未尝试')]
        for name, f in fields.items():
            lines.append(f"- {name}：{f['value'] or '空缺'} [{f['source']}]；{f['reason']}；阻止创建={f['blocks_creation']}")
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
        doc = json.loads(path.read_text()) if path.exists() else {'request': {k: job[k] for k in ('submission_id', 'task_id', 'version', 'text', 'submitted_at', 'time_zone', 'test_mode')}, 'attempts': {}}
        if any(job[k] != v for k, v in doc['request'].items()): raise ValueError('Submission content conflict')
        doc['phone'] = job; doc['observed_at'] = timestamp(); self.save(path, doc)
        params = identity(job)
        if job.get('execution') or job['state'] in ('verified', 'partial', 'not_completed', 'unknown', 'failed'): return
        if not job.get('plan') and not doc.get('plan') and job['state'] in ('queued', 'parsing'):
            if doc.get('parse_started'):
                doc.setdefault('model_error', 'worker_restarted_during_parse; no automatic retry')
            elif not os.environ.get('OPENAI_API_KEY'):
                return
            else:
                # Local input is durable before acknowledging handoff.
                self.rpc('plan_claim', params)
                doc['parse_started'] = timestamp(); self.save(path, doc)
                started = time.monotonic()
                try:
                    doc['plan'], doc['model'] = self.model(job)
                except Exception as error:
                    # Do not include arbitrary provider response/header contents.
                    doc['model_error'] = str(error) if isinstance(error, (RuntimeError, ValueError)) else type(error).__name__
                    if hasattr(error, 'rejected_plan'): doc['rejected_plan'] = error.rejected_plan
                doc['model_elapsed_seconds'] = round(time.monotonic() - started, 3)
                self.save(path, doc)
        if doc.get('model_error') and not job.get('plan'):
            self.rpc('plan_fail', {**params, 'message': '模型未完成，日历未执行：' + doc['model_error']})
            return
        if doc.get('plan') and not job.get('plan'):
            job = self.rpc('plan_store', {**params, 'plan': doc['plan']})
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
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'wellphone-data')
    args = parser.parse_args()
    os.umask(0o077)
    load_env(ROOT / '.env')
    # Exclusive worker lock avoids two model parsers racing the same submission.
    import fcntl
    args.data_dir.mkdir(parents=True, exist_ok=True)
    lock = (args.data_dir / '.worker.lock').open('w')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('A worker already uses this data directory.')
    worker = Worker(args.data_dir)
    print('Wellphone worker ready; model key configured=' + str(bool(os.environ.get('OPENAI_API_KEY'))), flush=True)
    last_status = None
    while True:
        try:
            result = rpc('plan_poll', {'model_ready': bool(os.environ.get('OPENAI_API_KEY'))})
            for job in result['jobs']: worker.process(job, result['host'])
            status = 'connected (no phone UI automation)'
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            status = 'disconnected or rejected: ' + type(error).__name__ + '; waiting, no execution replay'
        if status != last_status: print(status, flush=True); last_status = status
        time.sleep(0.7)


if __name__ == '__main__':
    try: main()
    except KeyboardInterrupt: pass
