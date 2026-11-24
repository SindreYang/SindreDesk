#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/dist/SindreDeskServer"
tmp="$(mktemp -d)"
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  cat "$tmp/server.log" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
export SINDREDESK_DATA_DIR="$tmp/state"
export SINDREDESK_RELAY=127.0.0.1:21117
start() {
  "$bin" >"$tmp/server.log" 2>&1 &
  pid=$!
  for i in $(seq 1 100); do
    kill -0 "$pid"
    if grep -q 'TCP 21115–21117 已就绪' "$tmp/server.log"; then
      ss -H -lun | grep -E ':21116[[:space:]]' >/dev/null
      return 0
    fi
    sleep .25
  done
  return 1
}
stop() {
  kill -TERM "$pid"
  wait "$pid"
  pid=""
  if ss -H -ltn | grep -E ':(21115|21116|21117)[[:space:]]'; then
    echo '端口未释放' >&2; return 1
  fi
}
start
key="$("$bin" key)"
[[ -n "$key" ]]
[[ "$key" == "$(cat "$SINDREDESK_DATA_DIR/id_ed25519.pub")" ]]
[[ "$(stat -c %a "$SINDREDESK_DATA_DIR/id_ed25519")" == 600 ]]
if "$bin" >"$tmp/duplicate.log" 2>&1; then
  echo '重复启动未被拒绝' >&2; exit 1
fi
grep -q '无法获取数据目录锁' "$tmp/duplicate.log"
stop
start
[[ "$("$bin" key)" == "$key" ]]
stop
echo '服务端实际进程启动、UDP/TCP、重复实例、退出和密钥持久化测试通过'
