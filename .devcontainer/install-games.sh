#!/usr/bin/env bash
# =============================================================================
# install-games.sh - установка единого бандла игр в /opt/jbox-unified.
#
# Источник: github.com/tryanddmca/images (release v1):
#   copper                     - движки (bin/), лаунчеры, индекс
#   gold.partaa|ab|ac          - shared/games (сами игры)
# Все части зашифрованы age и сжаты zstd (tar внутри).
#
# Всё распаковывается СТРИМИНГОМ (decrypt | zstd | tar) - промежуточные
# файлы на диск не пишутся вообще (экономия ~4 ГБ и времени).
# Повторный запуск пропускает готовые этапы (маркеры .done).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${JBOX_IMAGES_URL:-https://github.com/tryanddmca/images/releases/download/v1}"
DEST="${JBOX_UNIFIED_DIR:-/opt/jbox-unified}"
PASS="${JBOX_AGE_PASS:-lickmaballs}"
ERRLOG=/tmp/install-games.err

log() { echo "[games] $(date +%T) $*"; }
fail() { log "FAIL: $*"; exit 1; }

command -v age   >/dev/null || fail "age not installed (see bootstrap)"
command -v zstd  >/dev/null || fail "zstd not installed (see bootstrap)"
# age_run.py лежит рядом (в /opt/jbox) либо в ../scripts (запуск из репо)
AGE_RUN=""
for c in "$HERE/age_run.py" "$HERE/../scripts/age_run.py"; do
  [ -f "$c" ] && { AGE_RUN="$c"; break; }
done
[ -n "$AGE_RUN" ] || fail "age_run.py not found next to install-games.sh"

mkdir -p "$DEST"

# Готовность бандла: лаунчеры + оба движка + хоть одна игра.
bundle_ready() {
  local n
  n=$(ls "$DEST/launchers"/*.sh 2>/dev/null | wc -l)
  [ "$n" -ge 20 ] \
    && [ -f "$DEST/bin/jpp7/TJPP7_OpenGL" ] \
    && [ -f "$DEST/bin/jpp11/TJPP11_OpenGL" ] \
    && [ -d "$DEST/shared/games" ] \
    && [ -n "$(ls "$DEST/shared/games" 2>/dev/null | head -1)" ]
}

if bundle_ready; then
  log "bundle already complete at $DEST - nothing to do"
  exit 0
fi

# --- 1. copper: движки + лаунчеры -------------------------------------------
if [ -f "$DEST/.copper.done" ] || [ -d "$DEST/bin/jpp7" ]; then
  log "copper: already installed, skip"
else
  log "copper: downloading + extracting (streaming, ~55 MB)..."
  set -o pipefail
  curl -fL --retry 4 --retry-delay 3 "$BASE_URL/copper" 2>>"$ERRLOG" \
    | AGE_PASS="$PASS" python3 "$AGE_RUN" -d 2>>"$ERRLOG" \
    | zstd -dc 2>>"$ERRLOG" \
    | tar -xpf - -C "$DEST"
  rc=$?
  set +o pipefail
  [ "$rc" = 0 ] || fail "copper: pipeline failed (rc=$rc), see $ERRLOG"
  touch "$DEST/.copper.done"
  log "copper: extracted OK"
fi

# --- 2. gold: игры (3 части конкатенируются в пайпе) --------------------------
if [ -f "$DEST/.gold.done" ] && [ -n "$(ls "$DEST/shared/games" 2>/dev/null | head -1)" ]; then
  log "gold: already installed, skip"
else
  log "gold: downloading 3 parts (~4.1 GB) + extracting (streaming)..."
  set -o pipefail
  for p in gold.partaa gold.partab gold.partac; do
    curl -fL --retry 5 --retry-delay 3 "$BASE_URL/$p" 2>>"$ERRLOG" || fail "gold: download $p failed"
  done \
    | AGE_PASS="$PASS" python3 "$AGE_RUN" -d 2>>"$ERRLOG" \
    | zstd -dc 2>>"$ERRLOG" \
    | tar -xpf - -C "$DEST"
  rc=$?
  set +o pipefail
  [ "$rc" = 0 ] || fail "gold: pipeline failed (rc=$rc), see $ERRLOG"
  touch "$DEST/.gold.done"
  log "gold: extracted OK"
fi

bundle_ready || fail "bundle extracted but incomplete - check $DEST and $ERRLOG"

# games-симлинк у движков должен указывать на shared/games (на случай reloc)
for eng in "$DEST"/bin/*/; do
  [ -e "${eng}games" ] || ln -sfn ../../shared/games "${eng}games"
done

log "install-games: DONE ($(ls "$DEST/launchers"/*.sh 2>/dev/null | wc -l) games, engines: $(ls "$DEST/bin" | tr '\n' ' '))"
