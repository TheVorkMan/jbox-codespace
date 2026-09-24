#!/usr/bin/env bash
# Старт Selkies + окружение. Идемпотентен: если жив и слушает порт — пропускаем.
# В Codespaces порт 8080 публикуется автоматически (forwardPorts + public).
#
# Почему живость по pid-файлу, а не по порту:
#   - pkill -f '/opt/selkies/selkies' НЕ матчит реальный процесс AppImage;
#   - "умирающий" selkies ещё держит порт -> скрипт считает его живым и
#     уходит, оставляя стрим в состоянии "Waiting for stream...".
set -uo pipefail
PORT="${PORT:-8080}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE=/opt/jbox/state/selkies.pid

[ -f /opt/jbox/env.sh ] && source /opt/jbox/env.sh
mkdir -p /opt/jbox/state

# --- X: Xvfb 1920x1080 + openbox ---
# 1920x1080: веб-клиент запрашивает ресайз под своё окно (~1920x966).
export DISPLAY="${DISPLAY:-:99}"
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  DISPNUM="${DISPLAY#:}"; DISPNUM="${DISPNUM%%.*}"
  # stale-локи после падения Xvfb — без их очистки новый Xvfb не поднимется
  rm -f "/tmp/.X${DISPNUM}-lock" "/tmp/.X11-unix/X${DISPNUM}"
  echo "[start] starting Xvfb $DISPLAY (1920x1080)"
  Xvfb "$DISPLAY" -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
  sleep 1
  if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "[start] Xvfb FAILED — /tmp/xvfb.log:" >&2
    tail -10 /tmp/xvfb.log >&2 || true
  fi
  setsid nohup openbox >/tmp/openbox.log 2>&1 &
  sleep 0.5
fi

# --- audio: pulseaudio user-инстанс + null-sink jbox (монитор читает Selkies) ---
export XDG_RUNTIME_DIR=/tmp/xdg-jbox
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
if ! pactl info >/dev/null 2>&1; then
  rm -rf "$XDG_RUNTIME_DIR/pulse"
  pulseaudio -k >/dev/null 2>&1 || true
  pulseaudio --daemonize=yes --exit-idle-time=-1 \
    --load="module-null-sink sink_name=jbox rate=48000 channels=2" \
    >/tmp/pulse.log 2>&1
  for i in $(seq 1 20); do pactl info >/dev/null 2>&1 && break; sleep 0.5; done
fi
pactl set-default-sink jbox >/dev/null 2>&1 || true

# --- Selkies ---
PID="$(cat "$PIDFILE" 2>/dev/null || true)"
PORT_UP=no
ss -tln 2>/dev/null | grep -q ":$PORT " && PORT_UP=yes

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && [ "$PORT_UP" = yes ]; then
  echo "[start] selkies already running (pid $PID) on :$PORT"
else
  [ -n "$PID" ] && { kill "$PID" 2>/dev/null || true; echo "[start] stale selkies pid $PID — restarting"; }
  rm -f "$PIDFILE"
  # порт мог остаться занят мёртвым/"умирающим" процессом (fuser матчит по порту)
  if [ "$PORT_UP" = yes ]; then
    echo "[start] port $PORT busy without live pid — freeing (fuser)"
    fuser -k "$PORT"/tcp >/dev/null 2>&1 || true
    sleep 1
  fi
  echo "[start] launching selkies on :$PORT (websockets, h264enc/CPU)"
  setsid nohup /opt/selkies/selkies \
    --addr 0.0.0.0 \
    --port "$PORT" \
    --mode websockets \
    --encoder h264enc \
    --use-cpu=true \
    --framerate "30,8-60" \
    --video-bitrate "6000,100-8000" \
    --audio-enabled=true \
    --audio-device-name jbox.monitor \
    --enable-basic-auth="${SELKIES_ENABLE_BASIC_AUTH:-true}" \
    --basic-auth-user "${SELKIES_BASIC_AUTH_USER:-host}" \
    --basic-auth-password "${SELKIES_BASIC_AUTH_PASSWORD:?run bootstrap first}" \
    --basic-auth-viewonly-password "${SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD:-}" \
    --enable-sharing=true \
    --enable-shared=true \
    --enable-collab=false \
    --ui-title "Jackbox Stream" \
    --subfolder "${SELKIES_SUBFOLDER:-/stream}" \
    --use-browser-cursors=true \
    --run-after-connect "${SELKIES_RUN_AFTER_CONNECT:-/opt/jbox/on-connect.sh}" \
    --run-after-disconnect "${SELKIES_RUN_AFTER_DISCONNECT:-/opt/jbox/on-disconnect.sh}" \
    >/tmp/selkies.log 2>&1 &
  echo $! > "$PIDFILE"
  for i in $(seq 1 45); do
    ss -tln 2>/dev/null | grep -q ":$PORT " && break
    sleep 1
  done
  if ss -tln 2>/dev/null | grep -q ":$PORT "; then
    echo "[start] selkies UP on :$PORT (pid $(cat "$PIDFILE"), log /tmp/selkies.log)"
  else
    echo "[start] selkies FAILED — see /tmp/selkies.log:" >&2
    tail -20 /tmp/selkies.log >&2 || true
  fi
fi

echo "[start] done"
