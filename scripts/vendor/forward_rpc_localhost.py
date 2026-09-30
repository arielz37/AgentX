#!/usr/bin/env python3
"""
Bind a TCP port on 127.0.0.1 and forward each connection to the AgentX RPC
server running inside the UI test on an iPhone.

Connection strategies:
1) CoreDevice tunnel hostnames (*.coredevice.local) when available (Wi-Fi debugging).
2) usbmuxd forwarding (USB) via pymobiledevice3 if installed.

This keeps the host-side listening port off the LAN.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import select
from typing import List, Optional, Tuple


from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentx_config import PORT as RPC_PORT
_SUCCESSFUL_HOSTS = {}
_HOST_LOCK = threading.Lock()


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


def _devicectl_potential_hostnames(udid: str, timeout: float = 8.0) -> List[str]:
    # devicectl only supports JSON to a file.
    out_path = None
    try:
        fd, out_path = tempfile.mkstemp(prefix="agentx_devicectl_devices_", suffix=".json")
        os.close(fd)
        # devicectl rejects timeout < 5 seconds (Xcode 16+).
        timeout_s = max(5, int(timeout))
        cmd = [
            "xcrun",
            "devicectl",
            "--timeout",
            str(timeout_s),
            "list",
            "devices",
            "--json-output",
            out_path,
        ]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        with open(out_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        devices = (data.get("result") or {}).get("devices") or []
        udid_l = udid.lower()
        for dev in devices:
            identifier = str(dev.get("identifier") or "").lower()
            hw_udid = str(((dev.get("hardwareProperties") or {}).get("udid")) or "").lower()
            hostnames = ((dev.get("connectionProperties") or {}).get("potentialHostnames")) or []
            hostnames_l = [str(h).lower() for h in hostnames]

            if udid_l in (identifier, hw_udid) or any(udid_l in h for h in hostnames_l):
                return [str(h) for h in hostnames if str(h).endswith(".coredevice.local")]
    except Exception:
        return []
    finally:
        if out_path:
            try:
                os.unlink(out_path)
            except OSError:
                pass
    return []


def _coredevice_candidates(udid: str) -> List[str]:
    out: List[str] = []
    if udid.endswith(".coredevice.local"):
        out.append(udid)
    else:
        out.append(f"{udid}.coredevice.local")
    out.extend(_devicectl_potential_hostnames(udid))
    # Dedup preserving order.
    seen = set()
    deduped: List[str] = []
    for h in out:
        if h not in seen:
            seen.add(h)
            deduped.append(h)
    return deduped


def _try_connect(host: str, port: int, timeout: float) -> Optional[socket.socket]:
    try:
        return socket.create_connection((host, port), timeout=timeout)
    except OSError:
        return None


def connect_remote(udid: str, device_port: int, timeout: float) -> Tuple[Optional[socket.socket], str]:
    # Reuse an observed successful route; rediscover only after a failure.
    # Avoid invoking devicectl on every short RPC connection.
    with _HOST_LOCK:
        cached = _SUCCESSFUL_HOSTS.get((udid, device_port))
    if cached:
        s = _try_connect(cached, device_port, timeout)
        if s is not None:
            return s, f"coredevice({cached})"
        with _HOST_LOCK:
            _SUCCESSFUL_HOSTS.pop((udid, device_port), None)
    # 1) Prefer CoreDevice tunnel if available.
    for host in _coredevice_candidates(udid):
        s = _try_connect(host, device_port, timeout)
        if s is not None:
            with _HOST_LOCK:
                # Cache the observed numeric peer, not its DNS name: CoreDevice
                # hostname resolution can itself take ~5 seconds on every call.
                peer = s.getpeername()
                address = peer[0]
                if len(peer) == 4 and peer[3] and "%" not in address:
                    address += f"%{peer[3]}"
                _SUCCESSFUL_HOSTS[(udid, device_port)] = address
            return s, f"coredevice({host})"

    # 2) Fallback to usbmux (USB) if pymobiledevice3 is installed.
    try:
        from pymobiledevice3 import usbmux  # type: ignore
    except Exception:
        return None, "unavailable(no coredevice hostname, no pymobiledevice3)"

    try:
        mux_device = usbmux.select_device(udid)
        if mux_device is None:
            return None, "usbmux(device not found)"
        s = mux_device.connect(device_port)
        return s, "usbmux"
    except Exception as e:
        return None, f"usbmux(connect failed: {type(e).__name__}: {e})"


def pump(a: socket.socket, b: socket.socket) -> None:
    # Simple bidirectional pump. One direction closes the whole bridge.
    a.setblocking(False)
    b.setblocking(False)
    sockets = [a, b]
    try:
        while True:
            r, _, _ = select.select(sockets, [], sockets, 1.0)
            for s in r:
                try:
                    data = s.recv(65536)
                except BlockingIOError:
                    continue
                if not data:
                    return
                other = b if s is a else a
                other.sendall(data)
    finally:
        try:
            a.close()
        except OSError:
            pass
        try:
            b.close()
        except OSError:
            pass


def handle_client(client: socket.socket, udid: str, device_port: int, timeout: float) -> None:
    remote, via = connect_remote(udid, device_port, timeout)
    if remote is None:
        eprint(f"[forward] drop: unable to connect to device:{device_port} ({via})")
        try:
            client.close()
        except OSError:
            pass
        return

    eprint(f"[forward] connected via {via}")
    pump(client, remote)


def main() -> None:
    ap = argparse.ArgumentParser(description="Forward localhost TCP to AgentX RPC on iPhone (CoreDevice tunnel or USB).")
    ap.add_argument("--udid", required=True, help="Device UDID or CoreDevice identifier")
    ap.add_argument("--connect-timeout", type=float, default=2.0, help="Remote connect timeout (seconds)")
    args = ap.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", RPC_PORT))
    server.listen(64)

    eprint(f"Forwarding 127.0.0.1:{RPC_PORT} -> <device>:{RPC_PORT} (udid={args.udid})")
    eprint("Strategies: CoreDevice tunnel (*.coredevice.local) then usbmux (pymobiledevice3).")

    try:
        while True:
            client, _ = server.accept()
            t = threading.Thread(
                target=handle_client,
                args=(client, args.udid, RPC_PORT, args.connect_timeout),
                daemon=True,
            )
            t.start()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            server.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()
