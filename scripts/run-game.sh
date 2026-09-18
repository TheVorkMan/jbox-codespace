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
# Лог установки — отдельный файл на пак: /tmp/run-game-<pack>.log
# (curl -# рисует прогресс-полосы; без tty их не будет, но [games]-строки — будут).
# /opt/jbox/state/game_status: starting|running|failed — читается веб-клиентом.
if [ ! -x "$BIN" ] || [ "$FORCE" = "--force" ]; then
  echo "$GAME_ID starting" > /opt/jbox/state/game_status
  echo "[run] downloading/extracting $PACK (log: /tmp/run-game-$PACK.log)"
  bash "$HERE/install-games.sh" "$PACK" > "/tmp/run-game-$PACK.log" 2>&1
  rc=$?
  tail -3 "/tmp/run-game-$PACK.log" | sed 's/^/[run] /'
  if [ $rc -ne 0 ]; then
    echo "[run] download FAILED (rc=$rc) — полный лог: /tmp/run-game-$PACK.log"
    echo "$GAME_ID failed" > /opt/jbox/state/game_status
    rm -f /opt/jbox/state/current_game
    exit 2
  fi
  rm -rf "$RT"
  # AppImage-бинарник нужно вызывать с ./ из его каталога (PATH/текущий-каталог)
  (cd /opt/games/src && "./$PACK.AppImage" --appimage-extract >/tmp/extract-$PACK.log 2>&1) \
    || { echo "[run] extract failed — /tmp/extract-$PACK.log"; echo "$GAME_ID failed" > /opt/jbox/state/game_status; rm -f /opt/jbox/state/current_game; exit 3; }
  mv /opt/games/src/squashfs-root "$RT"
  echo "[run] extracted to $RT"
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
echo "$GAME_ID running" > /opt/jbox/state/game_status
echo "[run] started $GAME_ID (pid $GAME_PID, log /tmp/game.log)"

# --- 4. фокус окна игры ---
sleep "${GAME_START_WAIT:-6}"
WID="$(xdotool search --onlyvisible --class "$PACK_BIN" | head -1 || true)"
[ -n "$WID" ] && xdotool windowactivate --sync "$WID" 2>/dev/null || true
echo "[run] ready (stream: host password / viewer password)"
