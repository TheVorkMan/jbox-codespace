#!/usr/bin/env bash
# Скачивает AppImage-и паков (с catalog.json) в /opt/games/src с кэшем.
#
# Кэш: /tmp/jbox-cache/<pack>.<size>.AppImage. Размер определяем безопасно:
#   HEAD может быть запрещён (403/405) или отдать 0 — тогда GET с Range 0-0
#   и разбор Content-Range; если и это не дало размер — кэш по месяцу.
# Никаких вечных зависаний: --max-time/--connect-timeout на каждом запросе.
# Прогресс: строки "[games] ..." в stdout + полоса curl (-#) в stderr —
# оба потока попадают в /tmp/run-game-<pack>.log (см. run-game.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="${CATALOG:-}"
if [ -z "$CATALOG" ]; then
  for c in "$HERE/../catalog.json" /opt/games/catalog.json; do
    [ -f "$c" ] && CATALOG="$c" && break
  done
fi
[ -z "$CATALOG" ] && { echo "[games] catalog.json not found"; exit 1; }
DEST=/opt/games/src
CACHE=/tmp/jbox-cache
if ! mkdir -p "$DEST" "$CACHE" 2>/dev/null; then
  sudo mkdir -p "$DEST" "$CACHE"
  sudo chown -R "$(id -u):$(id -g)" /opt/games
fi

# --speed-limit/--speed-time: обрыв, если скорость < 1 КБ/с в течение 60 с
CURL=(curl -fL -# --retry 3 --retry-delay 3 --connect-timeout 30 --speed-time 60 --speed-limit 1024)

# размер источника, не скачивая файл целиком.
# Важно: сначала проверяем HTTP-код — заголовки 403/405 тоже содержат
# content-length (размер страницы ошибки), без проверки кода получим мусор.
probe_size() {
  local u="$1" hdr sz code
  code="$(curl -sIL -o /dev/null -w '%{http_code}' --retry 1 --max-time 20 "$u" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    hdr="$(curl -sIL --retry 1 --max-time 20 "$u" 2>/dev/null || true)"
    sz="$(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
  fi
  if [ -z "$sz" ] || [ "$sz" = "0" ]; then
    code="$(curl -sL -o /dev/null -w '%{http_code}' --retry 1 --max-time 20 -r 0-0 "$u" 2>/dev/null || echo 000)"
    if [ "$code" = "206" ] || [ "$code" = "200" ]; then
      hdr="$(curl -sL -D - -o /dev/null --max-time 20 -r 0-0 "$u" 2>/dev/null || true)"
      sz="$(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="content-range:"{split($2,a,"/"); print a[2]}' | tail -1)"
      [ -z "$sz" ] && sz="$(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
    fi
  fi
  echo "${sz:-0}"
}

packs="${1:-}"
if [ -z "$packs" ]; then
  packs="$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["packs"]))' "$CATALOG")"
fi

for pack in $packs; do
  urls="$(python3 - "$CATALOG" "$pack" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); p=sys.argv[2]
print("\n".join(c["sources"].get(p,[])))
PY
)"
  if [ -z "$urls" ]; then
    echo "[games] no sources for $pack — skip"; continue
  fi
  first_url="$(echo "$urls" | head -1)"
  echo "[games] == $pack =="

  expected=0
  while IFS= read -r u; do
    sz="$(probe_size "$u")"
    echo "[games] $pack: $(basename "$u") size=${sz:-unknown}"
    expected=$(( expected + ${sz:-0} ))
  done <<< "$urls"

  if [ "$expected" -gt 0 ]; then
    cached="$CACHE/$pack.$expected.AppImage"
  else
    # размер узнать не удалось (403 и т.п.) — кэш на календарный месяц
    cached="$CACHE/$pack.unknown.$(date +%Y%m).AppImage"
  fi
  target="$DEST/$pack.AppImage"

  if [ -f "$cached" ]; then
    echo "[games] cache hit for $pack ($(du -h "$cached" | cut -f1))"
    cp -f "$cached" "$target"; chmod +x "$target"
    continue
  fi

  if [ "$(echo "$urls" | wc -l)" -gt 1 ]; then
    echo "[games] $pack: скачивание частей (прогресс ниже):"
    i=0; parts=()
    while IFS= read -r u; do
      p="$CACHE/$pack.part$(printf '%02d' "$i")"
      echo "[games] $pack: часть $((i+1))..."
      "${CURL[@]}" -o "$p" "$u" || { echo "[games] download failed (часть $((i+1))): $u"; exit 3; }
      parts+=("$p"); i=$((i+1))
    done <<< "$urls"
    cat "${parts[@]}" > "$target" || { echo "[games] assemble failed"; exit 3; }
    rm -f "${parts[@]}"
  else
    echo "[games] $pack: скачивание (прогресс ниже):"
    "${CURL[@]}" -o "$target" "$first_url" || { echo "[games] download failed: $first_url"; exit 3; }
  fi
  chmod +x "$target"

  actual="$(stat -c%s "$target" 2>/dev/null || echo 0)"
  if [ "$expected" -gt 0 ] && [ "$actual" -ne "$expected" ]; then
    echo "[games] WARNING: $pack: размер скачанного ($actual) != ожидаемому ($expected)"
  fi
  cp -f "$target" "$cached" 2>/dev/null || true
  echo "[games] $pack ready: $(du -h "$target" | cut -f1) -> $target"
done
echo "[games] done:"
ls -lh "$DEST"
