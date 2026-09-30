#!/usr/bin/env python3
"""Daily Mac launcher. No build, install, phone launch, calendar write or model probe."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

from agentx_config import ROOT, PORT, load_model_env
RUNTIME = ROOT / '.runtime'
FORWARDER = ROOT / 'scripts/vendor/forward_rpc_localhost.py'
WORKER = ROOT / 'scripts/agentx_worker.py'


class StartupError(Exception):
    pass


def run(args, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=ROOT)


def discover_devices():
    with tempfile.TemporaryDirectory(prefix='agentx-discovery-') as temp:
        path = Path(temp) / 'devices.json'
        result = run(['xcrun', 'devicectl', '--timeout', '15', 'list', 'devices', '--json-output', str(path)])
        if result.returncode or not path.exists():
            raise StartupError('无法读取 Xcode 设备列表。请检查 Xcode 命令行工具及手机连接。')
        devices = json.loads(path.read_text()).get('result', {}).get('devices', [])
    return [d for d in devices if d.get('hardwareProperties', {}).get('deviceType') == 'iPhone'
            and d.get('connectionProperties', {}).get('pairingState') == 'paired'
            and d.get('connectionProperties', {}).get('tunnelState') == 'connected']


def device_ids(device):
    h = device.get('hardwareProperties', {})
    return {str(x).lower() for x in [h.get('udid'), device.get('identifier'),
            *device.get('connectionProperties', {}).get('potentialHostnames', [])] if x}


def select_device(devices, requested=None, interactive=True):
    if requested:
        matches = [d for d in devices if requested.lower() in device_ids(d)]
        if len(matches) == 1: return matches[0]
        raise StartupError('指定的 iPhone 未连接或未配对，未启动任何新服务。')
    if not devices:
        raise StartupError('未发现已连接、配对的 iPhone。请用 USB 连接并解锁，确认“信任此电脑”；必要时在 Xcode → Window → Devices and Simulators 完成配对。')
    if len(devices) == 1: return devices[0]
    print('发现多台 iPhone，请选择：')
    for index, d in enumerate(devices, 1):
        print(f"  {index}. {d.get('deviceProperties', {}).get('name', 'iPhone')} ({d['hardwareProperties']['udid']})")
    if not interactive: raise StartupError('多台设备时请使用 --udid 指定，启动器不会猜测。')
    try: index = int(input('设备编号：')) - 1
    except (ValueError, EOFError): raise StartupError('设备选择无效。') from None
    if not 0 <= index < len(devices): raise StartupError('设备选择无效。')
    return devices[index]


def lock_file(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stream = path.open('a+')
    try: fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        stream.close(); return None
    return stream


def worker_running():
    # Reuse the worker's own flock, not an unreliable PID substring match.
    stream = lock_file(ROOT / 'data/.worker.lock')
    if stream is None: return True
    stream.close(); return False


def is_forwarder_command(command, cwd, expected_script, accepted_ids):
    try: args = shlex.split(command)
    except ValueError: return False
    if '--udid' not in args: return False
    position = args.index('--udid')
    if position + 1 >= len(args) or args[position + 1].lower() not in accepted_ids: return False
    for arg in args[1:position]:
        if not arg.endswith('forward_rpc_localhost.py'): continue
        candidate = Path(arg)
        if not candidate.is_absolute(): candidate = Path(cwd) / candidate
        if candidate.resolve() == expected_script.resolve(): return True
    return False


def forwarder_running(device):
    with socket.socket() as probe:
        try: probe.bind(('127.0.0.1', PORT)); return False
        except OSError: pass
    result = run(['/usr/sbin/lsof', '-nP', f'-iTCP:{PORT}', '-sTCP:LISTEN', '-Fp'])
    pids = [line[1:] for line in result.stdout.splitlines() if line.startswith('p')]
    if len(pids) != 1: raise StartupError(f'{PORT} 端口已占用，无法确认是本项目服务。未结束任何进程。')
    pid = pids[0]
    command = run(['/bin/ps', '-ww', '-p', pid, '-o', 'command=']).stdout.strip()
    cwd_rows = run(['/usr/sbin/lsof', '-a', '-p', pid, '-d', 'cwd', '-Fn']).stdout.splitlines()
    cwd = next((r[1:] for r in cwd_rows if r.startswith('n')), '')
    if is_forwarder_command(command, cwd, FORWARDER, device_ids(device)): return True
    raise StartupError(f'{PORT} 被其他程序、另一份项目或另一台设备的转发器占用。请先在对应终端正常停止它；本入口不会强制结束。')


class Services:
    def __init__(self): self.children = []; self.logs = []
    def start(self, name, command):
        log = (RUNTIME / (name + '.log')).open('a')
        self.logs.append(log)
        log.write('\n--- ' + time.strftime('%Y-%m-%d %H:%M:%S') + ' ---\n'); log.flush()
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        self.children.append((name, process))
        return process
    def close(self):
        # Only Popen children owned by this invocation. Reused services are untouched.
        for _, p in self.children:
            if p.poll() is None:
                try: os.killpg(p.pid, signal.SIGINT)
                except ProcessLookupError: pass
        for _, p in self.children:
            try: p.wait(timeout=4)
            except subprocess.TimeoutExpired:
                try: os.killpg(p.pid, signal.SIGTERM)
                except ProcessLookupError: pass
        for log in self.logs: log.close()


def connection_label():
    from calendar_task import call
    try:
        response = call('calendar_status', {}, timeout=2)
        status = response.get('result', {})
        if status.get('execution_location') != 'iphone_native_app': return '连接到的不是 AgentX 原生宿主，请检查手机 App。'
        if status.get('authorization') != 'full_access': return '手机已连接；请点“准备连接和日历权限”，允许完全访问。'
        return '连接正常，日历权限正常。可在手机输入计划并点击执行。'
    except Exception:
        return 'Mac 服务运行中，等待手机连接。请解锁并打开 AgentX，必要时点“准备连接和日历权限”。'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', help='仅多设备时需要，必须来自实际设备列表')
    parser.add_argument('--check', action='store_true', help='仅检查，不启动服务或访问模型')
    args = parser.parse_args()
    os.umask(0o077)
    if not shutil.which('xcrun'): raise StartupError('未找到 xcrun，请先安装并配置 Xcode。')
    if not FORWARDER.exists(): raise StartupError('缺少 AgentX 的本地转发器快照，请重新获取完整 AgentX 目录。')
    load_model_env()
    if not os.environ.get('OPENAI_API_KEY'):
        raise StartupError('尚未配置模型 Key。请在 Wellphone 根目录运行 python3 scripts/configure_model.py；不要把 Key 发到聊天。')
    device = select_device(discover_devices(), args.udid, sys.stdin.isatty())
    udid = device['hardwareProperties']['udid']
    print('设备：' + device.get('deviceProperties', {}).get('name', 'iPhone'), flush=True)
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    launch_lock = lock_file(RUNTIME / 'launcher.lock')
    if launch_lock is None:
        print('一键启动窗口已经运行，请使用原窗口；没有启动重复服务。'); return 0
    services = Services()
    try:
        forwarding = forwarder_running(device); worker = worker_running()
        print('设备转发器：' + ('已运行，将复用' if forwarding else '未运行'))
        print('模型 worker：' + ('已运行，将复用' if worker else '未运行'), flush=True)
        if args.check:
            print('检查完成；没有启动进程、切换手机画面或执行任务。'); return 0
        if not forwarding:
            p = services.start('forwarder', [sys.executable, str(FORWARDER), '--udid', udid])
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if p.poll() is not None: raise StartupError('转发器启动失败，详情见 .runtime/forwarder.log。')
                if forwarder_running(device): break
                time.sleep(0.2)
            else: raise StartupError('转发器未能在五秒内启动。')
        if not worker:
            p = services.start('worker', [sys.executable, str(WORKER)])
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if p.poll() is not None:
                    if worker_running():
                        # Another worker won the lock; do not supervise our exited loser.
                        services.children.remove(('worker', p))
                        break
                    raise StartupError('worker 启动失败，详情见 .runtime/worker.log。')
                if worker_running(): break
                time.sleep(0.2)
            else: raise StartupError('worker 未能获取运行锁。')
        last = connection_label()
        print('\n' + last, flush=True)
        if not services.children:
            print('两个服务原本已运行，可关闭此窗口；原有服务不会被结束。'); return 0
        print('请保持此窗口开启、Mac 不休眠和设备连接。按 Control+C 停止本窗口启动的服务。', flush=True)
        next_check = time.monotonic() + 10
        while True:
            for name, process in services.children:
                if process.poll() is not None: raise StartupError(f'{name} 已退出。请检查 .runtime/{name}.log；不会自动重启手机或重放任务。')
            if time.monotonic() >= next_check:
                label = connection_label()
                if label != last: print(label, flush=True); last = label
                next_check = time.monotonic() + 10
            time.sleep(1)
    finally:
        services.close(); launch_lock.close()


def handle_shutdown(*_):
    raise KeyboardInterrupt


if __name__ == '__main__':
    # Terminal window close should clean up owned services just like Control+C.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, handle_shutdown)
    try: raise SystemExit(main())
    except KeyboardInterrupt: print('\n已停止本窗口启动的服务；复用的其他服务保持运行。')
    except (StartupError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        print('启动未完成：' + str(error), file=sys.stderr); raise SystemExit(1)
