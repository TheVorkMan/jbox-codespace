#!/usr/bin/env bash
# Остановить текущую игру (pid из /opt/jbox/state/game.pid).
set -uo pipefail
PIDFILE=/opt/jbox/state/game.pid
if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE")
  # убить процессную группу (setsid-лидер + дети)
  kill -TERM -"$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
  for i in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -"$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null || true
  rm -f "$PIDFILE"
fi
rm -f /opt/jbox/state/current_game
echo "[stop-game] ok"
