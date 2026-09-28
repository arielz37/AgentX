#!/usr/bin/env python3
"""Small report adapter around upstream rpc.py; never writes calendars on the Mac."""
import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("phoneagent_rpc", ROOT / "PhoneAgent/.agents/skills/phoneagent/scripts/rpc.py")
rpc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rpc)


def call(method, params, timeout=30):
    return rpc.rpc_call("127.0.0.1", 45678, rpc.build_request(1, method, params),
                        connect_timeout_s=5, read_timeout_s=timeout, max_bytes=1024 * 1024)


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def report(document):
    lines = ["# Wellphone 日历执行报告", "", f"Mac 发送：{document['mac_sent_at']}",
             f"Mac 返回：{document['mac_received_at']}", ""]
    if "not_sent_error" in document:
        return "\n".join(lines + ["状态：not_sent（本次任务尚未发送）", document["not_sent_error"]])
    if "transport_error" in document:
        return "\n".join(lines + ["状态：unknown（通信失败，不代表手机未保存）", document["transport_error"],
                                      "不要生成新 ID 重试；确认同一进程会话后原样重试。"])
    response = document["rpc_response"]
    if "error" in response:
        return "\n".join(lines + ["RPC 拒绝：" + json.dumps(response["error"], ensure_ascii=False)])
    result = response["result"]
    lines += [f"执行位置：{result.get('execution_location', '未提供')}"]
    if result.get("host"):
        host = result["host"]
        lines += [f"宿主状态：{host['application_state']}；系统剩余后台预算：{host['background_budget_seconds']:.2f} 秒"]
    lines += [f"任务：{result.get('task_id', '—')}；状态：{result.get('status', '—')}",
              "", "| 项目 | 状态 | 保存 | 读回验证 | 去重 |", "|---|---|---|---|---|"]
    for item in result.get("items", []):
        lines.append(f"| {item['item_id']} | {item['status']} | {item['saved_at']} | {item['verified_at']} | {item['deduplicated']} |")
    for item in result.get("items", []):
        lines += ["", f"项目 {item['item_id']}：{item['request'].get('title', '—')}"]
        if item.get("readback"):
            readback = item["readback"]
            lines.append(f"实际读回：{readback['start_at']} → {readback['end_at']}（{readback['time_zone']}）")
        if item.get("error"):
            lines.append("错误：" + item["error"]["message"])
    lines += ["", "完整请求、事件标识、实际读回字段和错误见同名 JSON。",
              "去重仅限同一进程会话；重放记录保留原验证时间，不代表再次读回。",
              "Mac 与 iPhone 使用各自的时钟，未校准；不要用跨设备时间戳计算耗时。",
              "此报告只证明数据执行结果，不自动证明画面、输入或帧率未受影响。"]
    return "\n".join(lines) + "\n"


def wait_for_background(request, document):
    # Observe only OUR host lifecycle, never the human's app/UI/screen.
    deadline = time.monotonic() + 180
    print("Waiting for the user to arm the native host and switch to the prepared game/text app...", flush=True)
    while True:
        response = call("calendar_status", {})
        current = response.get("result", {})
        if current.get("session_id") != request.get("session_id"):
            raise RuntimeError("Session changed; old task was NOT sent. Reconcile before retrying.")
        host = current.get("host", {})
        if host.get("import_armed") and host.get("application_state") == "background":
            document["background_observed_at"] = timestamp()
            document["background_observation"] = host
            print("Host is background; waiting 8 seconds for the user to start interacting.", flush=True)
            time.sleep(8)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Timed out waiting for background; task was NOT sent.")
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("prepare", help="May show permission prompt; before gaming only")
    sub.add_parser("lock", help="Irreversibly disable UI RPCs for this runner session")
    run = sub.add_parser("run")
    run.add_argument("file", type=Path)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--wait-for-background", action="store_true",
                     help="Native host only: wait for manual arm + background, then 8s before sending")
    args = parser.parse_args()
    if args.command != "run":
        method = "calendar_" + args.command
        params = {"allow_permission_prompt": True} if args.command == "prepare" else {}
        response = call(method, params, 120 if args.command == "prepare" else 30)
        print(json.dumps(response, ensure_ascii=False, indent=2))
        return int("error" in response)
    request = json.loads(args.file.read_text())
    document = {"request": request, "mac_sent_at": None}
    if args.wait_for_background:
        try:
            wait_for_background(request, document)
        except Exception as error:
            document["not_sent_error"] = str(error)
    # Exactly one attempt. No UI fallback or reconnect/restart loop.
    if "not_sent_error" not in document:
        document["mac_sent_at"] = timestamp()
        try:
            document["rpc_response"] = call("calendar_execute", request)
        except Exception as error:
            document["transport_error"] = str(error)
    document["mac_received_at"] = timestamp()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    markdown = report(document)
    args.output.with_suffix(".md").write_text(markdown)
    print(markdown)
    return int(document.get("rpc_response", {}).get("result", {}).get("status") != "verified")


if __name__ == "__main__":
    sys.exit(main())
