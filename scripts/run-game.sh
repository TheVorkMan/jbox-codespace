#!/usr/bin/env bash
# =============================================================================
# run-game.sh - запуск игры из единого дерева /opt/jbox-unified.
#
#   run-game.sh <GameName>          # по имени лаунчера (launchers/<GameName>.sh)
#   run-game.sh --list              # список игр
#   run-game.sh --verify            # проверить целостность дерева
#
# Лаунчеры уже знают свой движок (bin/jpp7|jpp11) и путь к swf - просто
# вызываем их. Состояние для UI пишется в /opt/jbox/state/.
# =============================================================================
set -uo pipefail

ROOT="${JBOX_UNIFIED_DIR:-/opt/jbox-unified}"
STATE=/opt/jbox/state
LOG=/tmp/game.log
RUNLOG=/tmp/run-game.log
DISPLAY="${DISPLAY:-:99}"

mkdir -p "$STATE"
log() { echo "[run] $(date +%T) $*"; }

[ -d "$ROOT/bin/jpp7" ] || [ -d "$ROOT/bin/jpp11" ] || {
  log "unified tree missing at $ROOT - run install-games.sh first"
  echo "unified tree missing - run install-games.sh" >&2
  exit 3
}

case "${1:-}" in
  --list)
    for f in "$ROOT"/launchers/*.sh; do
      [ -f "$f" ] || continue
      desc="$(head -2 "$f" | tail -1 | sed 's/^# //')"
      printf '%-24s %s\n' "$(basename "$f" .sh)" "$desc"
    done
    exit 0
    ;;
  --verify)
    ok=0; bad=0
    for f in "$ROOT"/launchers/*.sh; do
      pack="$(grep -o 'PACK="\$ROOT/bin/[^"]*"' "$f" | head -1 | sed 's|.*/bin/||; s|"||')"
      p="$(grep -o '\-launchTo games/[^ ]*\.swf' "$f" | head -1 | cut -d' ' -f2)"
      if [ -f "$ROOT/bin/$pack/$p" ]; then ok=$((ok+1)); else echo "BROKEN: $(basename "$f") ($pack/$p)"; bad=$((bad+1)); fi
    done
    log "verify: OK=$ok BAD=$bad"
    [ "$bad" = 0 ] && exit 0 || exit 1
    ;;
esac

GAME="${1:-}"
[ -n "$GAME" ] || { echo "usage: run-game.sh <GameName>" >&2; exit 2; }
LAUNCHER="$ROOT/launchers/$GAME.sh"
[ -f "$LAUNCHER" ] || { log "no launcher for '$GAME' (see run-game.sh --list)"; exit 2; }

# уже что-то запущено? — остановим (одна игра за раз)
if [ -f "$STATE/game.pid" ]; then
  OLD="$(cat "$STATE/game.pid")"
  if kill -0 "$OLD" 2>/dev/null; then
    log "stopping previous game (pid $OLD)"
    kill -- -"$OLD" 2>/dev/null || kill "$OLD" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$STATE/game.pid"
fi

log "launching $GAME"
echo "$GAME" > "$STATE/current_game"
echo "starting" > "$STATE/game_status"
rm -f "$STATE/keepalive"

export DISPLAY
# --- аудио: игра должна найти pulse-сокет сессии (как в jps-docker) ---
# Без XDG_RUNTIME_DIR/PULSE_SERVER игра валится на ALSA/умолчания и молчит.
export XDG_RUNTIME_DIR=/tmp/xdg-jbox
export PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native
export PULSE_SINK=jbox
export SDL_AUDIODRIVER=pulse
setsid nohup bash "$LAUNCHER" >"$LOG" 2>&1 &
PID=$!
echo "$PID" > "$STATE/game.pid"

# Проверка живости: 8 сек на то, чтобы процесс не умер сразу.
DEAD=0
for _ in $(seq 1 8); do
  sleep 1
  kill -0 "$PID" 2>/dev/null || { DEAD=1; break; }
done
if [ "$DEAD" = 1 ] || ! kill -0 "$PID" 2>/dev/null; then
  echo "failed" > "$STATE/game_status"
  log "game $GAME died immediately - tail of $LOG:"
  tail -15 "$LOG" >&2 || true
  exit 4
fi

echo "running" > "$STATE/game_status"
log "started $GAME (pid $PID, log $LOG)"
exit 0
