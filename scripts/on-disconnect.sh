#!/usr/bin/env bash
# Хук Selkies: последний зритель отключился -> ждём JBOX_STOP_TIMEOUT сек
# и глушим codespace (gh codespace stop). Экономия core-часов.
set -uo pipefail
TIMEOUT="${JBOX_STOP_TIMEOUT:-20}"
mkdir -p /opt/jbox/state
date -u +%s > /opt/jbox/state/last_disconnect
echo "[hook] last viewer disconnected — auto-stop in ${TIMEOUT}s (touch /opt/jbox/state/keepalive to cancel)"

sleep "$TIMEOUT"

# кто-то снова подключился или отмена запрошена?
if [ -f /opt/jbox/state/keepalive ]; then
  echo "[hook] keepalive present — skip stop"; exit 0
fi
AC=$(cat /opt/jbox/state/active_connections 2>/dev/null || echo 0)
if [ "$AC" -gt 0 ] 2>/dev/null; then
  echo "[hook] viewer reconnected — skip stop"; exit 0
fi
LD=$(cat /opt/jbox/state/last_disconnect 2>/dev/null || echo 0)
NOW=$(date -u +%s)
if [ $((NOW - LD)) -lt "$TIMEOUT" ]; then
  echo "[hook] newer connection happened — skip stop"; exit 0
fi

echo "[hook] stopping codespace"
# Останавливаем именно текущий codespace; если не codespace — просто exit.
if command -v gh >/dev/null 2>&1; then
  CS_NAME="${CODESPACE_NAME:-}"
  [ -n "$CS_NAME" ] && gh codespace stop "$CS_NAME" 2>/dev/null || true
fi
exit 0
