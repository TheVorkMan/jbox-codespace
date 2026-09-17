#!/usr/bin/env bash
# Selkies v2 (single-file AppImage) -> /opt/selkies/selkies
# AppImage требует FUSE; в Codespaces/VPS-контейнерах /dev/fuse может отсутствовать,
# поэтому при неудачном прямом запуске распаковываем --appimage-extract.
set -euo pipefail

SELKIES_VERSION="${SELKIES_VERSION:-2.0.0rc0}"
DEST=/opt/selkies
APPIMG="$DEST/selkies.AppImage"
BIN="$DEST/selkies"
URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-x86_64.AppImage"

mkdir -p "$DEST"
if [ -x "$BIN" ] && "$BIN" --version >/dev/null 2>&1; then
  echo "[selkies] already installed: $("$BIN" --version 2>/dev/null | head -1)"
  exit 0
fi

echo "[selkies] downloading $URL"
curl -fL --retry 3 --retry-delay 3 -o "$APPIMG" "$URL"
chmod +x "$APPIMG"

# Пробуем запустить напрямую (нужен FUSE); иначе распаковываем.
if ! "$APPIMG" --version >/dev/null 2>&1; then
  echo "[selkies] no FUSE — extracting squashfs"
  cd "$DEST"
  rm -rf "$DEST/squashfs-root"
  "$APPIMG" --appimage-extract >/dev/null
  ln -sf "$DEST/squashfs-root/AppRun" "$BIN"
else
  ln -sf "$APPIMG" "$BIN"
fi

"$BIN" --version 2>/dev/null | head -1 || true
echo "[selkies] installed at $BIN"
