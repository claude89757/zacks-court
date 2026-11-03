#!/bin/zsh
# Links the local S家 reference chain into the source tree, or unlinks it (docs/s-reference.md).
#   scripts/reference-chain.sh on      both/sjia builds: link .local/s-chain into the targets
#   scripts/reference-chain.sh off     default and release builds: remove the links
#   scripts/reference-chain.sh status
# The code itself stays in .local/s-chain/ (never in Git). In a git worktree without its own copy,
# the main checkout's .local/s-chain/ is used. COURT_REFERENCE_CHAIN_SOURCE overrides the location.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
links=("Sources/CourtCore/Reference:CourtCore" "Tests/CourtAppTests/Reference:Tests")

source_dir() {
  if [[ -n "${COURT_REFERENCE_CHAIN_SOURCE:-}" ]]; then print -r -- "$COURT_REFERENCE_CHAIN_SOURCE"; return; fi
  if [[ -d "$root/.local/s-chain/CourtCore" ]]; then print -r -- "$root/.local/s-chain"; return; fi
  local common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" && -d "${common:h}/.local/s-chain/CourtCore" ]]; then print -r -- "${common:h}/.local/s-chain"; return; fi
  print -r -- ""
}

case "${1:-status}" in
  on)
    src="$(source_dir)"
    if [[ -z "$src" || ! -d "$src/CourtCore" ]]; then
      echo "没有找到本地的 S家参照链代码（.local/s-chain/CourtCore）。默认构建不需要它；见 docs/s-reference.md。" >&2
      exit 1
    fi
    for pair in $links; do
      link="$root/${pair%%:*}" target="$src/${pair##*:}"
      if [[ -e "$link" && ! -L "$link" ]]; then echo "$link 是普通目录，不是链接；请先手动移走。" >&2; exit 1; fi
      [[ -d "$target" ]] || continue
      ln -sfn "$target" "$link"
    done
    echo "参照链已接入：$src"
    ;;
  off)
    for pair in $links; do
      link="$root/${pair%%:*}"
      if [[ -L "$link" ]]; then rm "$link"
      elif [[ -e "$link" ]]; then echo "$link 是普通目录，不是链接；为免删掉代码，请先手动移到 .local/s-chain/。" >&2; exit 1
      fi
    done
    ;;
  status)
    if [[ -L "$root/Sources/CourtCore/Reference" ]]; then echo "on → $(readlink "$root/Sources/CourtCore/Reference")"; else echo "off"; fi
    ;;
  *) echo "用法：$0 on|off|status" >&2; exit 2 ;;
esac
