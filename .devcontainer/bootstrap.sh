#!/usr/bin/env bash
# Провижининг codespace: зависимости + Selkies + паки + каталоги.
# Идемпотентен: повторный запуск пропускает готовое. Лог: /tmp/bootstrap.log
set -euo pipefail
exec > /tmp/bootstrap.log 2>&1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[$(date +%H:%M:%S)] == apt deps =="
export DEBIAN_FRONTEND=noninteractive
# "Reading package lists..." может висеть вечно, если лок держит параллельный
# процесс (unattended-upgrades/apt-daily в codespace включён systemd) либо VM утонула в троттлинге.
wait_apt_locks() {
  local i
  command -v fuser >/dev/null 2>&1 || return 0
  for i in $(seq 1 60); do
    sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 || return 0
    echo "[$(date +%H:%M:%S)] [bootstrap] apt/dpkg locks held — waiting ($i/60)"
    sleep 5
  done
  echo "[bootstrap] WARN: apt locks still held after 5 min — continuing"
}
wait_apt_locks
sudo systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

# debconf: заранее отвечаем на вопросы, которые иначе выскакивают диалогом
# (раскладка клавиатуры и пр.) — export DEBIAN_FRONTEND через sudo НЕ проходит,
# поэтому ниже каждый apt-get запускается через `sudo env ...`
sudo debconf-set-selections <<'SEEDS' 2>/dev/null || true
keyboard-configuration keyboard-configuration/layout select English (US)
keyboard-configuration keyboard-configuration/layoutcode select us
keyboard-configuration keyboard-configuration/variant select English (US)
keyboard-configuration keyboard-configuration/variantcode select
keyboard-configuration keyboard-configuration/model select Generic 105-key PC (intl)
console-setup console-setup/ask_detect boolean false
console-setup console-setup/detected_note note
SEEDS

echo "[$(date +%H:%M:%S)] == apt update =="
# пустые Post-Invoke отключают хуки apt (в контейнерах они умеют зависать),
# timeout не даст молча висеть вечно; при сбое — сброс списков и повтор
sudo env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
  timeout 900 apt-get \
  -o APT::Update::Post-Invoke= -o APT::Update::Post-Invoke-Success= \
  -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
  update -q || { echo "[bootstrap] apt update failed — resetting lists and retrying"; sudo rm -rf /var/lib/apt/lists/*; sudo env DEBIAN_FRONTEND=noninteractive timeout 900 apt-get update -q; }
echo "[$(date +%H:%M:%S)] == apt install =="
# --force-confold: не спрашивать про изменённые конфиги; noninteractive + seen=true: не спрашивать вообще ничего
sudo env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
  timeout 900 apt-get -o Dpkg::Options::=--force-confold \
  install -y -q --no-install-recommends \
  python3 python3-pip curl ca-certificates \
  xvfb openbox xdotool x11-utils x11-xserver-utils \
  xserver-xorg-core \
  xfonts-base \
  age zstd xz-utils \
  libgl1 libegl1 libgbm1 libxkbcommon0 \
  libpulse0 pulseaudio pulseaudio-utils \
  fonts-dejavu-core
# ALSA: в Ubuntu 24.04 (noble) пакет называется libasound2t64, в 22.04 (jammy) — libasound2
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q libasound2t64 2>/dev/null \
  || sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q libasound2 2>/dev/null || true
# ALSA-приложения (FMOD-фолбэк игры) направляем в pulse: без этого — тишина
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q libasound2-plugins 2>/dev/null || true
if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q libasound2-plugins >/dev/null 2>&1; then
  sudo tee /etc/asound.conf >/dev/null <<'ASOUND' || true
pcm.!default { type pulse hint.description "PulseAudio" }
ctl.!default { type pulse }
ASOUND
fi
# xserver-xorg-core: cvt/gtf для modeline (см. блок install выше); xfonts-base — шрифты для Xvfb/openbox. FUSE: noble — libfuse2t64, jammy — libfuse2
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q libfuse2t64 2>/dev/null || sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q libfuse2 2>/dev/null || true

# --- alt-игры: Wine (Windows-игры, например Godot-игры вроде Dub Together) ---
# wine64 тянет 32-битные компоненты по зависимостям; xkb-data/x11 libs —
# часто отсутствуют у Godot/X11-приложений внутри Wine.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q wine64 2>/dev/null \
  || echo "[bootstrap] WARN: wine64 не установился — alt-игры под Wine будут недоступны"
if command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1; then
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    libxkbcommon-x11-0 libxkbcommon0 libxinerama1 libxcursor1 libxrandr2 libxi6 \
    libxss1 libxxf86vm1 libxfixes3 libxrender1 libxext6 libx11-xcb1 \
    fonts-wine 2>/dev/null || true
  echo "[bootstrap] wine: $(command -v wine64 || command -v wine)"
else
  echo "[bootstrap] wine not available — alt/wine games disabled"
fi

# --- каталоги ---
# /opt принадлежит root; отдаём рабочие каталоги пользователю, чтобы все
# скрипты (install-selkies, install-games, run-game, api_server) писали без sudo.
echo "== dirs =="
sudo mkdir -p /opt/selkies /opt/jbox/state /opt/jbox-unified /opt/jbox-alt
sudo chown -R "$(id -u):$(id -g)" /opt/selkies /opt/jbox /opt/jbox-unified /opt/jbox-alt

# --- python deps для API (aiohttp) ---
sudo pip3 install --quiet --break-system-packages aiohttp 2>/dev/null \
  || pip3 install --quiet --break-system-packages aiohttp \
  || echo "[bootstrap] WARN: aiohttp not installed — API won't start"

echo "== selkies =="
bash "$HERE/install-selkies.sh"

echo "== games =="
# Единый бандл игр (copper+gold, ~4.2 GB) ставится стримингом; повторный
# запуск ничего не перекачивает. JBOX_PRELOAD=0 — отложить установку.
if [ "${JBOX_PRELOAD:-1}" = "1" ]; then
  bash "$HERE/install-games.sh" || echo "[bootstrap] bundle install failed — can be re-run manually: bash .devcontainer/install-games.sh"
else
  echo "[bootstrap] JBOX_PRELOAD=0 — bundle will be installed on first game launch"
fi

echo "== env file =="
# Пароли: host из Codespaces Secret (JBOX_HOST_PW) или случайный.
# Оба пароля НЕпустые: браузерный промпт исключён тем, что прокси (api_server)
# инжектит Basic сам — host-пароль для хоста, viewonly для зрителей/гостей.
# Роль (контроллер/только-просмотр) принуждает сам Selkies по паролю.
if [ ! -f /opt/jbox/env.sh ]; then
  HOSTPW="${JBOX_HOST_PW:-$(head -c16 /dev/urandom | md5sum | cut -c1-10)}"
  VIEWPW="${JBOX_VIEW_PW:-$(head -c16 /dev/urandom | md5sum | cut -c1-10)}"
  # SECURITY: равные пароли = гость через прокси получает host-пароль и
  # полный контроль стрима. Перегенерируем viewer.
  if [ "$HOSTPW" = "$VIEWPW" ]; then
    VIEWPW="$(head -c16 /dev/urandom | md5sum | cut -c1-10)"
    echo "[bootstrap] WARN: JBOX_HOST_PW == JBOX_VIEW_PW — viewer password regenerated"
  fi
  sudo tee /opt/jbox/env.sh >/dev/null <<EOF
export SELKIES_BASIC_AUTH_USER=host
export SELKIES_BASIC_AUTH_PASSWORD=$HOSTPW
export SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD=$VIEWPW
export SELKIES_ENABLE_BASIC_AUTH=true
export SELKIES_STOP_TIMEOUT=\${JBOX_STOP_TIMEOUT:-20}
export JBOX_STOP_TIMEOUT=\${JBOX_STOP_TIMEOUT:-20}
export JBOX_VIEW_PW=$VIEWPW
export JBOX_AGE_PASS=\${JBOX_AGE_PASS:-lickmaballs}
export JBOX_OPEN_VIEWER=1
EOF
  sudo chown "$(id -u):$(id -g)" /opt/jbox/env.sh
  echo "[bootstrap] host password: $HOSTPW (in /opt/jbox/env.sh); viewers enter without a password"
fi

echo "== web client =="
sudo cp -f "$HERE/../web/index.html" /opt/jbox/index.html
sudo chown "$(id -u):$(id -g)" /opt/jbox/index.html

sudo chmod +x "$HERE"/../scripts/*.sh 2>/dev/null || true
echo "BOOTSTRAP-DONE"
