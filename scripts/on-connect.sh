#!/usr/bin/env bash
# Хук Selkies: кто-то подключился — фиксируем время (для автостоп-логики).
set -uo pipefail
mkdir -p /opt/jbox/state
date -u +%s > /opt/jbox/state/last_connect
echo "[hook] viewer connected"
