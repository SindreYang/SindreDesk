#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo "用法: bash scripts/build-server.sh /path/hbbs /path/hbbr" >&2; exit 2; }
[[ "$(uname -s):$(uname -m)" == Linux:x86_64 ]] || { echo "只支持 Linux x86_64" >&2; exit 1; }
for binary in "$@"; do
  [[ -f "$binary" && -x "$binary" ]] || { echo "缺少可执行文件: $binary" >&2; exit 1; }
  LC_ALL=C file "$binary" | grep -q 'ELF 64-bit.*x86-64' || { echo "不是 Linux x86_64 ELF: $binary" >&2; exit 1; }
done
root="$(cd "$(dirname "$0")/.." && pwd)"
install -m 0755 "$1" "$root/server/payload/hbbs"
install -m 0755 "$2" "$root/server/payload/hbbr"
mkdir -p "$root/dist"
cd "$root/server"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o "$root/dist/SindreDeskServer" .
