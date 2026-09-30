"""PhoneAgent RPC transport excerpt (Rounak, MIT; see LICENSE.PhoneAgent).
Only build_request, line reader and rpc_call are reused verbatim.
UI automation CLI and its legacy default endpoint intentionally excluded.
AgentX calls these through scripts/calendar_task.py with its own port/identity.
"""
from __future__ import annotations
import json
import socket
from typing import Any, Dict, Optional


def build_request(req_id: int, method: str, params: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    p: Dict[str, Any] = dict(params or {})
    return {"id": req_id, "method": method, "params": p}


def _recv_one_line(sock: socket.socket, max_bytes: int) -> bytes:
    buf = bytearray()
    while True:
        if len(buf) > max_bytes:
            raise RuntimeError(f"Response exceeded max size ({max_bytes} bytes).")

        chunk = sock.recv(65536)
        if not chunk:
            break

        nl = chunk.find(b"\n")
        if nl != -1:
            buf.extend(chunk[:nl])
            break

        buf.extend(chunk)
    return bytes(buf)


def rpc_call(
    host: str,
    port: int,
    req: Dict[str, Any],
    *,
    connect_timeout_s: float,
    read_timeout_s: float,
    max_bytes: int,
) -> Dict[str, Any]:
    payload = (json.dumps(req, separators=(",", ":")) + "\n").encode("utf-8")
    try:
        sock = socket.create_connection((host, port), timeout=connect_timeout_s)
    except Exception as e:
        raise RuntimeError(f"Failed to connect to {host}:{port}: {type(e).__name__}: {e}") from e

    try:
        sock.settimeout(read_timeout_s)
        sock.sendall(payload)
        line = _recv_one_line(sock, max_bytes=max_bytes)
    finally:
        try:
            sock.close()
        except OSError:
            pass

    if not line:
        raise RuntimeError("Empty response (server closed the connection).")

    try:
        return json.loads(line.decode("utf-8"))
    except Exception as e:
        head = line[:200].decode("utf-8", errors="replace")
        raise RuntimeError(f"Invalid JSON response: {type(e).__name__}: {e}. Head={head!r}") from e
