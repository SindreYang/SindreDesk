#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p upstream
checkout() {
  local name="$1" url="$2" rev="$3" dest
  dest="upstream/$name"
  if [[ ! -e "$dest" ]]; then
    git clone --no-checkout "$url" "$dest"
  fi
  [[ "$(git -C "$dest" remote get-url origin)" == "$url" ]] || { echo "上游地址不一致: $dest" >&2; exit 1; }
  [[ -z "$(git -C "$dest" status --porcelain --untracked-files=all)" ]] || { echo "存在未提交改动: $dest" >&2; exit 1; }
  git -C "$dest" fetch origin "$rev"
  git -C "$dest" checkout --detach "$rev"
  git -C "$dest" submodule update --init --recursive
}
checkout rustdesk https://github.com/rustdesk/rustdesk.git 6c578292e8ebbbec708b76986ba8c4bc7c509747
checkout rustdesk-server https://github.com/rustdesk/rustdesk-server.git 73523b31cfd25d77dee862e6fc9f5e1fb5e485ef
