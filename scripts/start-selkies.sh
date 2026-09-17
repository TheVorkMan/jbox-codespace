#!/usr/bin/env bash
# Старт Selkies + окружение. Идемпотентен: если порт уже слушается — выходим.
# В Codespaces порт 8080 публикуется автоматически (forwardPorts + public).
#
# Selkies v2: encoder=h264enc (x264 soft на CPU), mode=websockets (работает за
# HTTPS-прокси Codespaces, где UDP/WebRTC недоступен). X-сервер поднимаем сами
# (Xvfb), Selkies подключается к нему через DISPLAY.
set -uo pipefail
PORT="${PORT:-8080}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f /opt/jbox/env.sh ] && source /opt/jbox/env.sh
mkdir -p /opt/jbox/state

# --- X: Xvfb 1280x720 + openbox ---
export DISPLAY="${DISPLAY:-:99}"
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo "[start] starting Xvfb $DISPLAY (1280x720)"
  Xvfb "$DISPLAY" -screen 0 1280x720x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
  sleep 1
  setsid nohup openbox >/tmp/openbox.log 2>&1 &
  sleep 0.5
fi

# --- audio: pulseaudio user-инстанс + null-sink jbox (монитор слушает Selkies) ---
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
if ! ss -tln 2>/dev/null | grep -q ":$PORT "; then
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
    --use-browser-cursors=true \
    --run-after-connect "${SELKIES_RUN_AFTER_CONNECT:-/opt/jbox/on-connect.sh}" \
    --run-after-disconnect "${SELKIES_RUN_AFTER_DISCONNECT:-/opt/jbox/on-disconnect.sh}" \
    >/tmp/selkies.log 2>&1 &
  for i in $(seq 1 45); do
    ss -tln 2>/dev/null | grep -q ":$PORT " && break
    sleep 1
  done
  if ss -tln 2>/dev/null | grep -q ":$PORT "; then
    echo "[start] selkies UP on :$PORT"
  else
    echo "[start] selkies FAILED — see /tmp/selkies.log:" >&2
    tail -20 /tmp/selkies.log >&2 || true
  fi
else
  echo "[start] selkies already running on :$PORT"
fi

echo "[start] done"
