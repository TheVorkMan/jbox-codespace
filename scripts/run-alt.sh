#!/usr/bin/env bash
# =============================================================================
# run-alt.sh — запуск альтернативных (не-Jackbox) игр.
#
#   run-alt.sh <GameId>     # по game_id из манифеста /opt/jbox-alt/manifests/*.json
#   run-alt.sh              # если манифест один — запустить его
#   run-alt.sh --list       # список alt-игр
#
# Манифест (пишется загрузчиком altgames.py или руками в репо):
#   {"game_id":"DubTogether","title":"Dub Together","kind":"wine",
#    "exe":"DubTogether.exe","dir":"DubTogether"}
#   kind: native | wine | auto (по расширению exe); exe/cmd — пути относительно dir.
#
# Состояние для UI — те же файлы, что у run-game.sh (current_game, game_status,
# game.pid): лаунчер/опции клиента работают без изменений. Audio-окружение —
# то же (pulse null-sink jbox → Selkies читает jbox.monitor).
# =============================================================================
set -uo pipefail

ALT_DIR="${JBOX_ALT_DIR:-/opt/jbox-alt}"
GAMES_DIR="$ALT_DIR/games"
MAN_DIR="$ALT_DIR/manifests"
PFX_DIR="$ALT_DIR/prefixes"
LOG=/tmp/game.log
RUNLOG=/tmp/run-alt.log
DISPLAY="${DISPLAY:-:99}"
export DISPLAY

mkdir -p "$PFX_DIR"
log() { echo "[alt] $(date +%T) $*" | tee -a "$RUNLOG" >&2; }
die() { log "ERROR: $*"; echo "run-alt: $*" >&2; exit "${2:-1}"; }

# --- state: как у run-game.sh, но переживаем read-only /opt (docker/vps) ---
STATE_DIR="${JBOX_STATE_DIR:-/opt/jbox/state}"
if ! mkdir -p "$STATE_DIR" 2>/dev/null || ! touch "$STATE_DIR/.w" 2>/dev/null; then
  STATE_DIR=/tmp/jbox-state; mkdir -p "$STATE_DIR"
fi
rm -f "$STATE_DIR/.w"
st_write() { printf '%s\n' "$1" > "$STATE_DIR/$2" 2>/dev/null || true; }

# --- аудио: то же окружение, что у Jackbox-игр (см. run-game.sh) ---
export XDG_RUNTIME_DIR=/tmp/xdg-jbox
export PULSE_SERVER=unix:$XDG_RUNTIME_DIR/pulse/native
export PULSE_SINK=jbox
export SDL_AUDIODRIVER=pulse
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
if command -v pulseaudio >/dev/null 2>&1 && ! pactl info >/dev/null 2>&1; then
  pulseaudio -k >/dev/null 2>&1 || true
  pulseaudio --daemonize=yes --exit-idle-time=-1 \
    --load="module-null-sink sink_name=jbox rate=48000 channels=2" \
    >/tmp/pulse.log 2>&1 || true
  for _ in $(seq 1 20); do pactl info >/dev/null 2>&1 && break; sleep 0.5; done
fi
pactl set-default-sink jbox >/dev/null 2>&1 || true

[ -d "$MAN_DIR" ] || die "нет каталога манифестов $MAN_DIR (ни одной alt-игры не установлено)"

# ---------- разбор манифеста в M_* переменные (json -> sh, безопасно) ----------
read_manifest() { # $1 = файл
  python3 - "$1" <<'PY'
import json, sys, shlex
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"битый манифест {sys.argv[1]}: {e}")
for k in ("game_id", "title", "dir", "exe", "cmd", "kind"):
    if m.get(k) is not None:
        print(f"M_{k}={shlex.quote(str(m[k]))}")
env = m.get("env")
if isinstance(env, dict):
    for k, v in env.items():
        print(f"M_env_{k}={shlex.quote(str(v))}")
PY
}

case "${1:-}" in
  --list)
    for f in "$MAN_DIR"/*.json; do
      [ -f "$f" ] || continue
      OUT="$(read_manifest "$f")" || { echo "БИТЫЙ: $f"; continue; }
      eval "$OUT"
      printf '%-28s %-26s alt · %s\n' "${M_game_id:-?}" "${M_title:-?}" "${M_kind:-auto}"
      unset M_game_id M_title M_kind
    done
    exit 0
    ;;
esac

GID="${1:-}"
if [ -z "$GID" ]; then
  N="$(find "$MAN_DIR" -maxdepth 1 -name '*.json' | wc -l)"
  [ "$N" = 1 ] || die "укажите game_id (см. run-alt.sh --list)"
  MF="$(find "$MAN_DIR" -maxdepth 1 -name '*.json' | head -1)"
else
  MF=""
  for f in "$MAN_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -q "\"game_id\"[[:space:]]*:[[:space:]]*\"$GID\"" "$f" && { MF="$f"; break; }
  done
fi
[ -n "$MF" ] || die "нет манифеста для '$GID' (см. run-alt.sh --list)"

M_game_id="" M_dir="" M_exe="" M_cmd="" M_kind=""
eval "$(read_manifest "$MF")" || die "не удалось прочитать манифест $MF"
GID="${M_game_id:-$GID}"
log "launching $GID ($(M_title:+${M_title}))"

GAMEDIR="$GAMES_DIR/${M_dir:-}"
ENTRY="${M_exe:-${M_cmd:-}}"
[ -n "$GAMEDIR" ] && [ -d "$GAMEDIR" ] || die "каталог игры $GAMEDIR отсутствует (файлы не загружены?)"
[ -n "$ENTRY" ] || die "в манифесте нет exe/cmd — укажите точку запуска (POST /api/altgames/config или руками в манифесте)"

EXE_PATH="$GAMEDIR/$ENTRY"
KIND="${M_kind:-auto}"
if [ "$KIND" = "auto" ]; then
  case "${ENTRY,,}" in
    *.exe|*.bat|*.msi) KIND="wine" ;;
    *)                 KIND="native" ;;
  esac
fi

# --- одна игра за раз: гасим предыдущую (та же state-логика, что в run-game.sh) ---
if [ -f "$STATE_DIR/game.pid" ]; then
  OLD="$(cat "$STATE_DIR/game.pid")"
  if kill -0 "$OLD" 2>/dev/null; then
    log "stopping previous game (pid $OLD)"
    kill -- -"$OLD" 2>/dev/null || kill "$OLD" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$STATE_DIR/game.pid"
fi

st_write "$GID" current_game
st_write "starting" game_status
rm -f "$STATE_DIR/keepalive"

# --- подготовка запуска ---
ARGS=()
[ -n "${M_args:-}" ] && read -r -a ARGS <<< "$M_args"
for k in "${!M_env_@}"; do
  export "${k#M_env_}=${!k}"
done
cd "$GAMEDIR" || die "нет доступа к $GAMEDIR"

if [ "$KIND" = "wine" ]; then
  [ -f "$EXE_PATH" ] || die "exe не найден: $ENTRY (проверьте exe в манифесте)"
  WINEBIN="$(command -v wine64 || command -v wine || true)"
  [ -n "$WINEBIN" ] || die "wine не найден — bootstrap должен установить wine64"
  export WINEPREFIX="$PFX_DIR/$GID"
  export WINEDLLOVERRIDES="mscoree,mshtml="   # без диалогов установки mono/gecko
  export WINEDEBUG=-all
  mkdir -p "$WINEPREFIX"
  if [ ! -f "$WINEPREFIX/system.reg" ]; then
    log "инициализация wineprefix (первый запуск — занимает до минуты)"
    "$WINEBIN" wineboot --init >/dev/null 2>&1 || true
  fi
  CMD=("$WINEBIN" "$EXE_PATH")
else
  if [ ! -x "$EXE_PATH" ] && [[ "$ENTRY" == *.sh ]]; then
    CMD=(bash "$EXE_PATH")
  else
    [ -e "$EXE_PATH" ] || die "точка запуска не найдена: $ENTRY (проверьте exe/cmd в манифесте)"
    chmod +x "$EXE_PATH" 2>/dev/null || true
    CMD=("$EXE_PATH")
  fi
fi

setsid nohup "${CMD[@]}" "${ARGS[@]}" >"$LOG" 2>&1 &
PID=$!
echo "$PID" > "$STATE_DIR/game.pid"

# --- проверка живости: 8 сек (wine-игры стартуют заметно дольше, но процесс
#     жив уже через секунду; умирает сразу только при битом exe/prefix) ---
DEAD=0
for _ in $(seq 1 8); do
  sleep 1
  kill -0 "$PID" 2>/dev/null || { DEAD=1; break; }
done
if [ "$DEAD" = 1 ] || ! kill -0 "$PID" 2>/dev/null; then
  st_write "failed" game_status
  log "game $GID died immediately — tail of $LOG:"
  tail -15 "$LOG" >&2 || true
  exit 4
fi

st_write "running" game_status
log "started $GID (pid $PID, kind $KIND, log $LOG)"
exit 0
