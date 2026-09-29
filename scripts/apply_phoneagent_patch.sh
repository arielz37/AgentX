#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/phoneagent-alerts.patch"
cd "$ROOT/PhoneAgent"
EXPECTED=4f0e201572c2cc6f36bab1e1f80c61878b4a90b7
[[ "$(git rev-parse HEAD)" == "$EXPECTED" ]] || { echo 'Unexpected PhoneAgent revision; review patch manually.' >&2; exit 1; }
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo 'Adaptive alerts patch already applied.'
elif git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo 'Applied Wellphone adaptive alerts extension; existing signing configuration preserved.'
elif git apply --check "$ROOT/patches/phoneagent-day3-to-alerts.patch" 2>/dev/null; then
  git apply "$ROOT/patches/phoneagent-day3-to-alerts.patch"
  echo 'Upgraded Day 3 sources to adaptive alerts; signing preserved.'
elif git apply --check "$ROOT/patches/phoneagent-day2-to-alerts.patch" 2>/dev/null; then
  git apply "$ROOT/patches/phoneagent-day2-to-alerts.patch"
  echo 'Upgraded exact Day 2 source to adaptive alerts; signing preserved.'
else
  echo 'Local source differs; stopped without overwriting. Review changes manually.' >&2
  exit 1
fi

python3 "$ROOT/scripts/configure_native_host.py"
