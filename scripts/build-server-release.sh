#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl --fail --location --retry 3 https://github.com/rustdesk/rustdesk-server/releases/download/1.1.16/rustdesk-server-linux-amd64.zip -o "$tmp/server.zip"
printf '%s  %s\n' 0565c41affe6c3f409b0bddfaf5a24ccbf3f64f5f8e3fec250b69a0d5f6bdbcf "$tmp/server.zip" | sha256sum -c -
unzip -q "$tmp/server.zip" -d "$tmp/unpacked"
hbbs="$(find "$tmp/unpacked" -type f -name hbbs -print)"
hbbr="$(find "$tmp/unpacked" -type f -name hbbr -print)"
[[ -f "$hbbs" && -f "$hbbr" ]]
chmod 0755 "$hbbs" "$hbbr"
bash "$root/scripts/build-server.sh" "$hbbs" "$hbbr"
