#!/usr/bin/env bash
# Trivia Murder Party 2 — The Jackbox Party Pack 6
# Auto-generated: relative launcher, walks up to find the game root.
set -u

find_root() {
  local d
  d="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  while [ "$d" != "/" ]; do
    if [ -d "$d/bin" ] && [ -d "$d/shared/games" ]; then
      printf '%s' "$d"; return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

ROOT="$(find_root)" || { echo 'Game root (bin/ + shared/) not found above this script.' >&2; exit 1; }
PACK="$ROOT/bin/jpp7"
[ -f "$PACK/Launcher.sh" ] || { echo "Launcher not found: $PACK/Launcher.sh" >&2; exit 1; }
cd -- "$PACK" || exit 1
mkdir -p tmp 2>/dev/null || true
export RENDERER=OpenGL
./Launcher.sh -launchTo games/TriviaDeath2/TriviaDeath2.swf -jbg.config isBundle=false "$@"
