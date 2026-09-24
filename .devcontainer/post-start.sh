#!/usr/bin/env bash
# postStartCommand: выполняется при каждом старте/рестарте codespace.
# Синхронизирует /opt/jbox с репо, стартует стрим + API. Идемпотентен.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- синхронизация файлов из репо (репо живёт дольше контейнера) ---
if [ -d "$HERE/../scripts" ]; then
  sudo mkdir -p /opt/jbox /opt/jbox-unified
  sudo cp -f "$HERE/../scripts/"*.sh /opt/jbox/ 2>/dev/null || true
  sudo cp -f "$HERE/../scripts/age_run.py" /opt/jbox/ 2>/dev/null || true
  sudo cp -f "$HERE/../scripts/api_server.py" /opt/jbox/ 2>/dev/null || true
  sudo cp -f "$HERE/install-games.sh" /opt/jbox/ 2>/dev/null || true
  sudo chmod +x /opt/jbox/*.sh 2>/dev/null || true
  # лаунчеры из репо перекрывают содержимое бандла (там могут быть пропуски)
  if [ -d "$HERE/../launchers" ] && [ -d /opt/jbox-unified/launchers ]; then
    sudo cp -f "$HERE/../launchers/"*.sh /opt/jbox-unified/launchers/ 2>/dev/null || true
    sudo chmod +x /opt/jbox-unified/launchers/*.sh 2>/dev/null || true
  fi
  # скрипты пишут в /opt/* от пользователя — отдать владение
  sudo chown -R "$(id -u):$(id -g)" /opt/jbox /opt/jbox-unified 2>/dev/null || true
fi

# --- SECURITY fixup: равные host/viewonly пароли дают зрителю контроллер ---
# Selkies назначает потолок "viewer" только если viewonly != host-пароль.
# env.sh уже существующий bootstrap не перегенерирует — лечим тут, на каждом старте.
if [ -f /opt/jbox/env.sh ]; then
  # shellcheck disable=SC1091
  . /opt/jbox/env.sh 2>/dev/null || true
  if [ -n "${SELKIES_BASIC_AUTH_PASSWORD:-}" ] \
     && [ "${SELKIES_BASIC_AUTH_PASSWORD}" = "${SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD:-}" ]; then
    NEWV="$(head -c16 /dev/urandom | md5sum | cut -c1-10)"
    sed -i "s|^export SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD=.*|export SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD=$NEWV|" /opt/jbox/env.sh
    sed -i "s|^export JBOX_VIEW_PW=.*|export JBOX_VIEW_PW=$NEWV|" /opt/jbox/env.sh
    echo "[post-start] WARN: host и viewonly пароли были равны — viewonly перегенерирован (зрители теперь без инпута)"
  fi
fi

# --- Selkies ещё не установлен? (после полного rebuild контейнера) ---
if [ ! -x /opt/selkies/selkies ]; then
  echo "[post-start] selkies missing — running bootstrap"
  bash "$HERE/bootstrap.sh" >/tmp/bootstrap.log 2>&1
fi

# --- старт стрима и API ---
nohup bash /opt/jbox/start-selkies.sh >/tmp/start-selkies.out 2>&1 &
nohup python3 /opt/jbox/api_server.py >/tmp/api.log 2>&1 &

echo "[post-start] stream http://localhost:8080  api http://localhost:8081"
