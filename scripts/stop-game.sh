#!/usr/bin/env bash
# Остановка текущей игры (группы процессов) и чистка состояния.
# Работает и для Jackbox-игр (run-game.sh), и для альт-игр (run-alt.sh).
set -uo pipefail
STATE_DIR="${JBOX_STATE_DIR:-/opt/jbox/state}"
LOG=/tmp/game.log

# state-каталог мог уехать в /tmp (read-only /opt в docker/vps) — см. run-alt.sh
if [ ! -d "$STATE_DIR" ]; then STATE_DIR=/tmp/jbox-state; fi

PID="$(cat "$STATE_DIR/game.pid" 2>/dev/null || true)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  # setsid -> у игры свой pgid = pid: валим всю группу
  kill -- -"$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true
  sleep 1
  kill -9 -- -"$PID" 2>/dev/null || true
fi
rm -f "$STATE_DIR/game.pid"
echo "stopped" > "$STATE_DIR/game_status" 2>/dev/null || true

# Подстраховка: убьём осиротевшие процессы игр на дисплее (не трогая X/pulse).
# TJPP* — движки Jackbox; wineserver убивает всё wine-дерево (alt-игры через Wine).
pkill -f 'TJPP7_OpenGL|TJPP11_OpenGL' 2>/dev/null || true
if command -v wineserver >/dev/null 2>&1 || pgrep -f wineserver >/dev/null 2>&1; then
  WSPID="$(pgrep -o -f wineserver 2>/dev/null || true)"
  [ -n "$WSPID" ] && kill "$WSPID" 2>/dev/null || true
  pgrep -f '\.exe|wine64|wine ' >/dev/null 2>&1 && pkill -9 -f '\.exe|wine64|wine ' 2>/dev/null || true
fi
echo "[run] game stopped"
