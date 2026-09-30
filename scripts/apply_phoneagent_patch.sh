#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/phoneagent-calendar-features.patch"
cd "$ROOT/PhoneAgent"
EXPECTED=4f0e201572c2cc6f36bab1e1f80c61878b4a90b7
[[ "$(git rev-parse HEAD)" == "$EXPECTED" ]] || { echo 'Unexpected PhoneAgent revision; review patch manually.' >&2; exit 1; }
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo 'Calendar capabilities patch already applied.'
else
  APPLIED=false
  for CANDIDATE in "$PATCH" "$ROOT/patches/phoneagent-alerts-to-calendar-features.patch" "$ROOT/patches/phoneagent-day3-to-calendar-features.patch" "$ROOT/patches/phoneagent-day2-to-calendar-features.patch"; do
    if git apply --check "$CANDIDATE" 2>/dev/null; then
      git apply "$CANDIDATE"
      APPLIED=true
      echo 'Applied calendar capabilities extension; signing preserved.'
      break
    fi
  done
  if [[ "$APPLIED" != true ]]; then
    echo 'Local source differs; stopped without overwriting. Review changes manually.' >&2
    exit 1
  fi
fi
python3 "$ROOT/scripts/configure_native_host.py"
