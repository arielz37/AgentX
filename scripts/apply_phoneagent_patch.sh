#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/phoneagent-day3.patch"
cd "$ROOT/PhoneAgent"
EXPECTED=4f0e201572c2cc6f36bab1e1f80c61878b4a90b7
[[ "$(git rev-parse HEAD)" == "$EXPECTED" ]] || { echo 'Unexpected PhoneAgent revision; review patch manually.' >&2; exit 1; }
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo 'Day 3 patch already applied.'
elif git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo 'Applied Wellphone Day 3 extension; existing signing configuration preserved.'
elif git apply --check "$ROOT/patches/phoneagent-day2-to-day3.patch" 2>/dev/null; then
  git apply "$ROOT/patches/phoneagent-day2-to-day3.patch"
  echo 'Upgraded exact Day 2 source to Day 3; signing preserved.'
else
  echo 'Local source differs; stopped without overwriting. Review changes manually.' >&2
  exit 1
fi

python3 "$ROOT/scripts/configure_native_host.py"
