#!/usr/bin/env bash
# Запуск конкретной игры: run-game.sh <pack.game_id>
# Пример: run-game.sh jpp2.bomb -> "Бомб-корп" из Party Pack 2.
#
# Структура распакованного AppImage (из старого jps-docker):
#   <pack>/AppRun, <pack>/bin/<ПАК>_OpenGL, <pack>/bin/lib/...
# Бинарник ищется в корне, bin/ и глубже; запуск — из его каталога
# с LD_LIBRARY_PATH=<каталог>/lib (как было в jps-docker/start.sh).
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
STATUS=/opt/jbox/state/game_status

# --- поиск бинарника игры в распакованном паке ---
resolve_bin() {
  local cand
  for cand in "$RT/$PACK_BIN" "$RT/bin/$PACK_BIN" "$RT/usr/bin/$PACK_BIN"; do
    [ -x "$cand" ] && { echo "$cand"; return 0; }
  done
  # последний шанс: поиск по всему паку (исполняемый файл с таким именем)
  find "$RT" -type f -name "$PACK_BIN" -perm -u+x 2>/dev/null | head -1
}

BIN="$(resolve_bin)"

# --- 1. распаковка при необходимости ---
# Логи: /tmp/run-game-<pack>.log (загрузка), /tmp/extract-<pack>.log (распаковка).
if [ -z "$BIN" ] || [ "$FORCE" = "--force" ]; then
  echo "$GAME_ID starting" > "$STATUS"
  if [ ! -f "/opt/games/src/$PACK.AppImage" ]; then
    echo "[run] downloading $PACK (log: /tmp/run-game-$PACK.log)"
    bash "$HERE/install-games.sh" "$PACK" > "/tmp/run-game-$PACK.log" 2>&1
    rc=$?
    tail -3 "/tmp/run-game-$PACK.log" | sed 's/^/[run] /'
    if [ $rc -ne 0 ]; then
      echo "[run] download FAILED (rc=$rc) — полный лог: /tmp/run-game-$PACK.log"
      echo "$GAME_ID failed" > "$STATUS"; rm -f /opt/jbox/state/current_game; exit 2
    fi
  else
    echo "[run] AppImage уже скачан: /opt/games/src/$PACK.AppImage"
  fi
  echo "[run] extracting (log: /tmp/extract-$PACK.log)"
  rm -rf "$RT"
  (cd /opt/games/src && "./$PACK.AppImage" --appimage-extract >"/tmp/extract-$PACK.log" 2>&1) \
    || { echo "[run] extract failed — /tmp/extract-$PACK.log"; echo "$GAME_ID failed" > "$STATUS"; rm -f /opt/jbox/state/current_game; exit 3; }
  mv /opt/games/src/squashfs-root "$RT"
  echo "[run] extracted to $RT"
  BIN="$(resolve_bin)"
  if [ -z "$BIN" ]; then
    echo "[run] FAILED: бинарник '$PACK_BIN' не найден в $RT"
    find "$RT" -maxdepth 3 -type f \( -name "*OpenGL*" -o -name "AppRun" \) 2>/dev/null | head -5 | sed 's/^/[run]   нашёл: /'
    echo "[run] поправьте 'bin' в catalog.json под реальное имя файла"
    echo "$GAME_ID failed" > "$STATUS"; rm -f /opt/jbox/state/current_game; exit 4
  fi
fi

echo "[run] binary: $BIN"

# --- 2. убить предыдущую игру (если была) ---
"$HERE/stop-game.sh" >/dev/null 2>&1 || true

# --- 3. запуск на стрим-дисплее, аудио в jbox ---
# Как в jps-docker: cwd = каталог бинарника, LD_LIBRARY_PATH = <cwd>/lib
export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR=/tmp/xdg-jbox
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
export SDL_AUDIODRIVER=pulseaudio
GDIR="$(dirname "$BIN")"
export LD_LIBRARY_PATH="$GDIR/lib:${LD_LIBRARY_PATH:-}"
chmod +x "$BIN" 2>/dev/null || true

(
  cd "$GDIR" || exit 1
  setsid nohup "$BIN" >/tmp/game.log 2>&1 &
  echo $! > /opt/jbox/state/game.pid
)
GAME_PID="$(cat /opt/jbox/state/game.pid 2>/dev/null || echo "")"
echo "$GAME_ID running" > "$STATUS"
echo "[run] started $GAME_ID (pid $GAME_PID, log /tmp/game.log)"

# --- 4. проверка живости + фокус окна ---
sleep "${GAME_START_WAIT:-6}"
if [ -n "$GAME_PID" ] && ! kill -0 "$GAME_PID" 2>/dev/null && ! pgrep -f "$PACK_BIN" >/dev/null 2>&1; then
  echo "[run] FAILED: процесс умер сразу после старта — /tmp/game.log:"
  tail -15 /tmp/game.log 2>/dev/null | sed 's/^/[run]   /'
  echo "$GAME_ID failed" > "$STATUS"
  exit 5
fi
WID="$(xdotool search --onlyvisible --class "$PACK_BIN" | head -1 || true)"
[ -n "$WID" ] && xdotool windowactivate --sync "$WID" 2>/dev/null || true
echo "[run] ready (stream: host password / viewer password)"
