#!/usr/bin/env bash
# Скачивает AppImage-и паков (с catalog.json) в /opt/games/src с кэшем.
# Кэш: /tmp/jbox-cache — формат <pack>.<size>.AppImage; если размер удалённого файла
# совпадает с закэшированным, скачивание пропускается (экономия трафика и времени).
set -euo pipefail
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
mkdir -p "$DEST" "$CACHE"

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
  # размер первого (основного) источника
  first_url="$(echo "$urls" | head -1)"
  size="$(curl -fsSLI --retry 2 "$first_url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
  cached="$CACHE/$pack.${size:-unknown}.AppImage"
  target="$DEST/$pack.AppImage"
  if [ -n "$size" ] && [ -f "$cached" ]; then
    echo "[games] cache hit for $pack ($size bytes)"
    cp -f "$cached" "$target"
    continue
  fi
  echo "[games] downloading $pack"
  if [ "$(echo "$urls" | wc -l)" -gt 1 ]; then
    # многочастный источник (part00 + part01 -> cat)
    i=0; parts=()
    while IFS= read -r u; do
      p="$CACHE/$pack.part$(printf '%02d' "$i")"
      curl -fL --retry 3 --retry-delay 3 -o "$p" "$u"
      parts+=("$p"); i=$((i+1))
    done <<< "$urls"
    cat "${parts[@]}" > "$target"
  else
    curl -fL --retry 3 --retry-delay 3 -o "$target" "$first_url"
  fi
  chmod +x "$target"
  [ -n "$size" ] && cp -f "$target" "$cached" || true
  echo "[games] $pack ready: $(du -h "$target" | cut -f1)"
done
ls -la "$DEST"
