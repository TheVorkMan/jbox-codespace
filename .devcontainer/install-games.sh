#!/usr/bin/env bash
# =============================================================================
# install-games.sh - установка единого бандла игр в /opt/jbox-unified.
#
# Источник: github.com/tryanddmca/images (release v1):
#   copper                     - движки (bin/), лаунчеры, индекс
#   gold.partaa|ab|ac          - игры (tar.zst; кладёт игры в КОРЕНЬ дерева
#                                + вложенный tjppgoldcollection.tar.zst)
# Все части зашифрованы age и сжаты zstd.
#
# Распаковка СТРИМИНГОМ (decrypt | zstd | tar) - промежуточных файлов нет.
# Нормализация layout'а выполняется ПЕРВОЙ и идемпотентно: если предыдущий
# прогон оставил игры в корне и вложенный архив - они разбираются и удаляются
# БЕЗ повторной докачки (критерий докачки - фактическое наличие игр).
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

games_count() { ls "$DEST/shared/games" 2>/dev/null | wc -l; }

# Готовность бандла: лаунчеры + оба движка + игры.
bundle_ready() {
  local n
  n=$(ls "$DEST/launchers"/*.sh 2>/dev/null | wc -l)
  [ "$n" -ge 20 ] \
    && [ -f "$DEST/bin/jpp7/TJPP7_OpenGL" ] \
    && [ -f "$DEST/bin/jpp11/TJPP11_OpenGL" ] \
    && [ "$(games_count)" -ge 5 ]
}

# --- нормализация layout'а (идемпотентна, безопасна для повторных прогонов) ---
# 1) игровые папки, оставленные gold в КОРНЕ дерева -> shared/games
# 2) вложенные *.tar.zst (например tjppgoldcollection.tar.zst) -> распаковать
#    в shared/games и УДАЛИТЬ архив
normalize_layout() {
  local moved=0
  mkdir -p "$DEST/shared/games"
  for d in "$DEST"/*/; do
    local n="${d%/}"; n="$(basename "$n")"
    case "$n" in bin|shared|launchers|.*|.inner_tmp) continue ;; esac
    # игровая папка: gameManifest.json или swf на верхнем уровне
    if [ -f "${d}gameManifest.json" ] || ls "${d}"*.swf >/dev/null 2>&1; then
      if [ -e "$DEST/shared/games/$n" ]; then
        rm -rf "$d"                       # дубль (вложенный архив/повтор)
      else
        mv "$d" "$DEST/shared/games/$n"
      fi
      moved=$((moved+1))
    fi
  done
  for z in "$DEST"/*.tar.zst; do
    [ -f "$z" ] || continue
    log "normalize: extracting inner $(basename "$z")"
    local TMP="$DEST/.inner_tmp"
    rm -rf "$TMP"; mkdir -p "$TMP"
    if zstd -dc "$z" 2>>"$ERRLOG" | tar -xpf - -C "$TMP"; then
      find "$TMP" -mindepth 1 -maxdepth 1 -type d | while read -r c; do
        local n; n="$(basename "$c")"
        if [ -e "$DEST/shared/games/$n" ]; then rm -rf "$c"; else mv "$c" "$DEST/shared/games/$n"; fi
      done
    else
      log "WARN: inner archive $(basename "$z") failed to extract - removing anyway (see $ERRLOG)"
    fi
    rm -rf "$TMP" "$z"
    moved=$((moved+1))
  done
  # мусор от прошлых прогонов: частичные архивы/загрузки
  rm -f "$DEST"/*.tar.zst.tmp "$DEST"/.gold.parts.* 2>/dev/null || true
  [ "$moved" -gt 0 ] && log "normalize: $moved item(s) relocated/cleaned"
  return 0
}

normalize_layout

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

# --- 2. gold: игры (критерий - фактическое наличие игр, не маркер) -----------
if [ "$(games_count)" -ge 5 ]; then
  log "gold: games already present ($(games_count) dirs) - skip download"
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

normalize_layout

bundle_ready || fail "bundle extracted but incomplete - check $DEST and $ERRLOG"

# games-симлинк у движков должен указывать на shared/games (copper может
# привезти битый/абсолютный симлинк)
for eng in "$DEST"/bin/*/; do
  [ -e "${eng}games" ] || ln -sfn ../../shared/games "${eng}games"
done

log "install-games: DONE ($(ls "$DEST/launchers"/*.sh 2>/dev/null | wc -l) launchers, $(games_count) games, engines: $(ls "$DEST/bin" | tr '\n' ' '))"
