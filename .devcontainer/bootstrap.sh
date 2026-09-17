#!/usr/bin/env bash
# Провижининг codespace: зависимости + Selkies + паки + каталоги.
# Идемпотентен: повторный запуск пропускает готовое. Лог: /tmp/bootstrap.log
set -euo pipefail
exec > /tmp/bootstrap.log 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== apt deps =="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \
  python3 python3-pip curl ca-certificates \
  xvfb openbox xdotool x11-utils x11-xserver-utils \
  libgl1 libegl1 libgbm1 libxkbcommon0 \
  libpulse0 pulseaudio pulseaudio-utils \
  fonts-dejavu-core >/dev/null
# ALSA: в Ubuntu 24.04 (noble) пакет называется libasound2t64, в 22.04 (jammy) — libasound2
sudo apt-get install -y -qq libasound2t64 2>/dev/null \
  || sudo apt-get install -y -qq libasound2 2>/dev/null || true
# FUSE для AppImage: в noble — libfuse2t64, в jammy — libfuse2
sudo apt-get install -y -qq libfuse2t64 2>/dev/null || sudo apt-get install -y -qq libfuse2 2>/dev/null || true

# --- python deps для API (aiohttp) ---
sudo pip3 install --quiet --break-system-packages aiohttp 2>/dev/null \
  || pip3 install --quiet --break-system-packages aiohttp \
  || echo "[bootstrap] WARN: aiohttp not installed — API won't start"

echo "== selkies =="
bash "$HERE/install-selkies.sh"

echo "== games =="
# По умолчанию паки НЕ качаются на провижининге (быстрый старт, качаются при
# первом запуске игры). JBOX_PRELOAD=1 (Codespaces Secret) — качать все сразу.
if [ "${JBOX_PRELOAD:-0}" = "1" ]; then
  bash "$HERE/install-games.sh" || echo "[bootstrap] game download failed — лаунчер докачает при запуске"
else
  echo "[bootstrap] JBOX_PRELOAD=0 — паки скачаются при первом запуске игры"
fi

echo "== env file =="
# Пароли: из Codespaces Secrets (JBOX_HOST_PW / JBOX_VIEW_PW) или случайные.
if [ ! -f /opt/jbox/env.sh ]; then
  HOSTPW="${JBOX_HOST_PW:-$(head -c16 /dev/urandom | md5sum | cut -c1-10)}"
  VIEWPW="${JBOX_VIEW_PW:-$(head -c16 /dev/urandom | md5sum | cut -c1-10)}"
  sudo tee /opt/jbox/env.sh >/dev/null <<EOF
export SELKIES_BASIC_AUTH_USER=host
export SELKIES_BASIC_AUTH_PASSWORD=$HOSTPW
export SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD=$VIEWPW
export SELKIES_ENABLE_BASIC_AUTH=true
export SELKIES_STOP_TIMEOUT=\${JBOX_STOP_TIMEOUT:-20}
export JBOX_STOP_TIMEOUT=\${JBOX_STOP_TIMEOUT:-20}
EOF
  echo "[bootstrap] passwords: host=$HOSTPW viewer=$VIEWPW (also in /opt/jbox/env.sh)"
fi

echo "== web client =="
sudo cp -f "$HERE/../web/index.html" /opt/jbox/index.html

echo "== dirs =="
sudo mkdir -p /opt/games/runtime /opt/jbox/state
sudo chmod +x "$HERE"/../scripts/*.sh 2>/dev/null || true
echo "BOOTSTRAP-DONE"
