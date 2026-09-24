#!/usr/bin/env bash
# Остановка текущей игры (группы процессов) и чистка состояния.
set -uo pipefail
STATE=/opt/jbox/state
LOG=/tmp/game.log

PID="$(cat "$STATE/game.pid" 2>/dev/null || true)"
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  # setsid -> у игры свой pgid = pid: валим всю группу
  kill -- -"$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true
  sleep 1
  kill -9 -- -"$PID" 2>/dev/null || true
fi
rm -f "$STATE/game.pid"
echo "stopped" > "$STATE/game_status" 2>/dev/null || true

# Подстраховка: убьём осиротевшие процессы игры на дисплее (не трогая X/pulse)
pkill -f 'TJPP7_OpenGL|TJPP11_OpenGL' 2>/dev/null || true
echo "[run] game stopped"
