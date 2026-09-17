#!/usr/bin/env bash
# Быстрая диагностика стрима. Запуск в codespace:
#   bash .devcontainer/doctor.sh   (или bash /opt/jbox/doctor.sh)
# Собирает всё, что нужно для разбора "Waiting for stream..." в один вывод.
set -uo pipefail
section() { echo; echo "=== $1 ==="; }

section "processes (Xvfb/openbox/pulseaudio/selkies)"
ps aux | grep -E '[X]vfb|[o]penbox|[p]ulseaudio|[s]elkies' || echo "NONE RUNNING"

section "ports 8080/8081"
ss -tln 2>/dev/null | grep -E ':(8080|8081) ' || echo "no listeners"

section "X display"
DISPLAY="${DISPLAY:-:99}"
if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "X $DISPLAY OK: $(xdpyinfo -display "$DISPLAY" | grep dimensions)"
else
  echo "X $DISPLAY DEAD — /tmp/xvfb.log:"
  tail -5 /tmp/xvfb.log 2>/dev/null || echo "  (no log)"
fi

section "pulseaudio + null-sink"
export XDG_RUNTIME_DIR=/tmp/xdg-jbox
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
if pactl info >/dev/null 2>&1; then
  echo "-- sinks:";    pactl list short sinks
  echo "-- monitors:"; pactl list short sources | grep -i monitor || echo "  NO MONITOR SOURCE"
else
  echo "PULSE DEAD — /tmp/pulse.log:"
  tail -5 /tmp/pulse.log 2>/dev/null || echo "  (no log)"
fi

section "selkies log (last 40)"
tail -40 /tmp/selkies.log 2>/dev/null || echo "(no /tmp/selkies.log)"

section "selkies errors"
grep -iE 'error|traceback|exception|failed|fatal' /tmp/selkies.log 2>/dev/null | tail -10 || true

section "game log (last 10)"
tail -10 /tmp/game.log 2>/dev/null || echo "(no game started)"

section "state"
ls -la /opt/jbox/state 2>/dev/null
cat /opt/jbox/state/current_game 2>/dev/null || echo "(no current game)"

echo
echo "Подсказка: полный вывод пришли в чат — по нему видно, кто именно не поднялся."
