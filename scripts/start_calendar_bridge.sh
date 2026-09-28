#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PHONEAGENT_RUNNER_PREPARE_SCRIPT="$ROOT/scripts/prepare_calendar_runner.py"
cd "$ROOT/PhoneAgent"
exec bash .agents/skills/phoneagent/scripts/start_rpc_bridge_local.sh
