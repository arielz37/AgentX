#!/bin/bash
# Finder double-click entry. Resolve paths relative to this file, including spaces.
cd "$(dirname "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TASK_PYTHON="$(command -v python3)"
if [ -z "$TASK_PYTHON" ] || ! "$TASK_PYTHON" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo '需要 Python 3.10 或更高版本，请安装后再启动。'
  read -r -p '按回车关闭窗口…' _
  exit 1
fi
"$TASK_PYTHON" scripts/start_wellphone.py "$@"
TASK_EXIT=$?
if [ -t 0 ]; then
  read -r -p '按回车关闭窗口…' _
fi
exit "$TASK_EXIT"
