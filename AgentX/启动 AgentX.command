#!/bin/zsh
cd -- "${0:A:h}" || exit 1
python3 scripts/start_agentx.py
result=$?
if (( result != 0 )); then
  printf '\n启动失败。按回车关闭窗口。'
  read -r
fi
exit $result
