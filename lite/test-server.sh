#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
mkdir -p "$tmp/portable" "$tmp/other-cwd"
bin="$tmp/portable/SindreDeskLiteServer-linux-x64"
cp "$root/dist/SindreDeskLiteServer-linux-x64" "$bin"
chmod 755 "$bin"
cd "$tmp/other-cwd"
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" || true; fi
  cat "$tmp/server.log" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
data="$tmp/portable/SindreDeskLiteData"
export SINDREDESK_PUBLIC_IP=127.0.0.1
export SINDREDESK_RELAY=127.0.0.1:22117
url=https://127.0.0.1:22120
cert="$data/api.crt"
start() {
  "$bin" >"$tmp/server.log" 2>&1 &
  pid=$!
  for i in $(seq 1 120); do
    kill -0 "$pid"
    if [[ -s "$cert" ]] && curl -fsS --max-time 2 --cacert "$cert" "$url/health" > "$tmp/health.json"; then
      python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); assert a["status"]=="online" and a["service"]=="sindredesk-lite"' "$tmp/health.json"
      "$bin" status
      ss -H -lun | grep -E ':22116[[:space:]]' >/dev/null
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
  if ss -H -ltn | grep -E ':(22115|22116|22117|22118|22119|22120)[[:space:]]'; then
    echo '端口未释放' >&2; exit 1
  fi
}
post() {
  curl -fsS --max-time 5 --cacert "$cert" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3" "$url/v1/$2"
}
code() {
  python3 -c 'import json,re,sys; v=json.load(sys.stdin)["code"]; assert re.fullmatch("[0-9]{4}",v); print(v)'
}
start
[[ -f "$data/devices.db" && ! -e "$tmp/other-cwd/SindreDeskLiteData" ]]
[[ "$(stat -c %a "$data")" == 700 ]]
key=$("$bin" key)
fingerprint=$(sha256sum "$cert")
"$bin" info > "$tmp/info.json"
python3 - "$tmp/info.json" "$cert" "$key" <<'PY'
import hashlib, json, ssl, sys
with open(sys.argv[1]) as f:
    info = json.load(f)
with open(sys.argv[2]) as f:
    cert = f.read()
assert set(info) == {"ip", "id_server", "relay_server_default", "api_url", "rustdesk_key", "tls_certificate", "tls_sha256"}
assert info["ip"] == "127.0.0.1"
assert info["id_server"] == "127.0.0.1:22116"
assert info["relay_server_default"] == "127.0.0.1:22117"
assert info["api_url"] == "https://127.0.0.1:22120"
assert info["rustdesk_key"] == sys.argv[3]
assert info["tls_certificate"] == cert
assert info["tls_sha256"] == hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest()
assert "PRIVATE KEY" not in json.dumps(info)
PY
a=$(openssl rand -hex 32)
b=$(openssl rand -hex 32)
c1=$(post "$a" register '{"rustdesk_id":"123456789"}' | code)
c2=$(post "$b" register '{"rustdesk_id":"987654321"}' | code)
[[ "$c1" != "$c2" ]]
[[ "$(post "$a" register '{"rustdesk_id":"123456789"}' | code)" == "$c1" ]]
[[ "$(post "$a" lookup "{\"code\":\"$c2\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rustdesk_id"])')" == 987654321 ]]
[[ "$(curl -sS --cacert "$cert" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"code":"0000"}' "$url/v1/lookup")" == 401 ]]
if "$bin" >"$tmp/duplicate.log" 2>&1; then echo '重复启动未被拒绝'; exit 1; fi
grep -q '无法获取数据目录锁' "$tmp/duplicate.log"
stop
if "$bin" status; then echo '停止后错误报告在线'; exit 1; fi
start
[[ "$("$bin" key)" == "$key" ]]
[[ "$(sha256sum "$cert")" == "$fingerprint" ]]
"$bin" info > "$tmp/info-restart.json"
cmp "$tmp/info.json" "$tmp/info-restart.json"
[[ "$(post "$a" register '{"rustdesk_id":"123456789"}' | code)" == "$c1" ]]
[[ "$(post "$b" register '{"rustdesk_id":"987654321"}' | code)" == "$c2" ]]
stop
echo '真实进程、TLS、注册、查询、重启持久化、端口释放测试通过'
