#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { echo "用法: bash lite/build-server.sh /path/hbbs /path/hbbr" >&2; exit 2; }
[[ "$(uname -s):$(uname -m)" == Linux:x86_64 ]] || exit 1
for b in "$@"; do
  [[ -x "$b" ]] && LC_ALL=C file "$b" | grep -q 'ELF 64-bit.*x86-64' || exit 1
done
root="$(cd "$(dirname "$0")/.." && pwd)"
install -m 0755 "$1" "$root/lite/server/payload/hbbs"
install -m 0755 "$2" "$root/lite/server/payload/hbbr"
mkdir -p "$root/dist"
cd "$root/lite/server"
go mod download github.com/mattn/go-sqlite3
CGO_ENABLED=1 go test ./...
CGO_ENABLED=1 go build -trimpath -ldflags='-s -w -linkmode external -extldflags "-static"' -o "$root/dist/SindreDeskLiteServer" .
