#!/usr/bin/env bash
# Запуск конкретной игры: run-game.sh <pack.game_id>
# Пример: run-game.sh jps.tjsp  -> "Смехлыст 3" из Party Starter.
#
# Логика:
#   1. Пак уже распакован в /opt/games/runtime/<pack>? -> запускаем бинарник.
#   2. Нет -> качаем AppImage (install-games.sh) и распаковываем
#      --appimage-extract (надёжнее FUSE-маунта, не требует /dev/fuse).
#   3. Выбор игры внутри пака — клик xdotool по превью (координаты из catalog.json).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME_ID="${1:-}"
FORCE="${2:-}"
[ -z "$GAME_ID" ] && { echo "usage: run-game.sh <pack.game_id>"; exit 1; }

CATALOG=/opt/games/catalog.json
PACK="${GAME_ID%%.*}"
mkdir -p /opt/jbox/state
echo "$GAME_ID" > /opt/jbox/state/current_game

json() { python3 - "$CATALOG" "$@" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
path = sys.argv[2:]
node = c
for k in path:
    node = node[k]
print(node)
PY
}

PACK_FILE="$(json packs "$PACK" file)"
PACK_BIN="$(json packs "$PACK" bin)"
RT="/opt/games/runtime/$PACK"
BIN="$RT/$PACK_BIN"

# --- 1. распаковка при необходимости ---
if [ ! -x "$BIN" ] || [ "$FORCE" = "--force" ]; then
  echo "[run] extracting $PACK"
  bash "$HERE/install-games.sh" "$PACK" || { echo "[run] download failed"; exit 2; }
  rm -rf "$RT" /opt/games/src/"$PACK".squashfs-root
  (cd /opt/games/src && "$PACK.AppImage" --appimage-extract >/dev/null 2>&1) || { echo "[run] extract failed"; exit 3; }
  mv /opt/games/src/squashfs-root "$RT"
fi

# --- 2. убить предыдущую игру (если была) ---
"$HERE/stop-game.sh" >/dev/null 2>&1 || true

# --- 3. запуск на стрим-дисплее, аудио в jbox ---
export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR=/tmp/xdg-jbox
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
export SDL_AUDIODRIVER=pulseaudio

setsid nohup "$BIN" >/tmp/game.log 2>&1 &
GAME_PID=$!
echo "$GAME_PID" > /opt/jbox/state/game.pid
echo "[run] started $GAME_ID (pid $GAME_PID, log /tmp/game.log)"

# --- 4. фокус окна игры ---
sleep "${GAME_START_WAIT:-6}"
WID="$(xdotool search --onlyvisible --class "$PACK_BIN" | head -1 || true)"
[ -n "$WID" ] && xdotool windowactivate --sync "$WID" 2>/dev/null || true
echo "[run] ready (stream: host password / viewer password)"
