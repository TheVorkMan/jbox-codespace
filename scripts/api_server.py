#!/usr/bin/env python3
"""API + веб-клиент для Jackbox-стрима (порт 8081).

Одна страница (/) для всех: UI зависит от роли (host/viewer).
Стрим остаётся нативным Selkies UI (порт 8080), встроен через <iframe src="/stream/">
(прокси в этом же сервере — чтобы не зависеть от внешних путей).

API:
  GET  /api/state?role=host|viewer[&key=...]  — каталог, статус, пароли роли
  POST /api/launch                            — запустить игру {game_id}
  POST /api/stop-game                         — остановить игру
  POST /api/stop-session                      — остановить codespace (сохранить часы)
  POST /api/keepalive                         — отменить запланированный автостоп
  GET  /api/chat?since=N                      — длинный опрос чата
  POST /api/chat                              — отправить сообщение
"""
import asyncio, json, os, re, shutil, subprocess, time
from pathlib import Path
from aiohttp import web

CATALOG_PATH = Path("/opt/games/catalog.json")
CATALOG = json.load(open(CATALOG_PATH)) if CATALOG_PATH.exists() else {"packs": {}, "games": {}}
# каталог перечитываем при каждом /api/state: post-start может скопировать
# catalog.json ПОЗЖЕ старта этого сервера — иначе лаунчер навсегда пустой
def reload_catalog():
    global CATALOG
    try:
        CATALOG = json.load(open(CATALOG_PATH))
    except Exception:
        pass
STATE = Path("/opt/jbox/state"); STATE.mkdir(parents=True, exist_ok=True)
PID = Path("/tmp/jbox-api.pid")

# ---------- env ----------
# env.sh пишется для bash: значения могут содержать ${VAR:-default}.
# start-selkies.sh его source-ит (bash разворачивает сам), а этот сервер
# парсит файл вручную — поэтому разворачиваем дефолты тут.
def _expand_shell(v):
    def repl_default(m):
        name, _, default = m.group(1).partition(":-")
        return os.environ.get(name, default)
    v = re.sub(r"\$\{([^}]+)\}", repl_default, v)
    v = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", lambda m: os.environ.get(m.group(1), ""), v)
    return v

def _int_env(v, default):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default

ENV = {}
_envsh = Path("/opt/jbox/env.sh")
if _envsh.exists():
    for line in _envsh.read_text().splitlines():
        if line.startswith("export "):
            k, _, v = line[7:].partition("=")
            ENV[k] = _expand_shell(v.strip().strip('"').strip("'"))
HOST_PW = ENV.get("SELKIES_BASIC_AUTH_PASSWORD", "")
VIEW_PW = ENV.get("SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD", "")
STOP_TIMEOUT = _int_env(ENV.get("JBOX_STOP_TIMEOUT", "20"), 20)

# ---------- session state ----------
session = {
    "chat": [],            # [{id, nick, text, ts}]
    "chat_id": 0,
    "players": {},         # nick -> {ts, last_seen_poll}
    "auto_stop_at": None,  # ts запланированного автостопа (хук on-disconnect)
    "started": time.time(),
}

def _poll_keepalive_file():
    """Хук on-disconnect пишет keepalive-файл и время отсечки; следим из API."""
    global session
    ld = read(STATE / "last_disconnect")
    ka = (STATE / "keepalive").exists()
    if ka:
        session["auto_stop_at"] = None
    elif ld:
        try:
            t = int(ld) + STOP_TIMEOUT
            if t > time.time() - 300:  # свежая отметка (не старше 5 мин)
                session["auto_stop_at"] = t
        except ValueError:
            pass

def read(path, default=None):
    try: return Path(path).read_text().strip()
    except Exception: return default

BG_LOG = "/tmp/jbox-api-bg.log"
def run_bg(cmd):
    # stdout/stderr фоновых задач — в лог, а не в /dev/null (иначе диагностике конец)
    try:
        f = open(BG_LOG, "ab")
        f.write(f"\n[{time.strftime('%m-%d %H:%M:%S')}] $ {cmd}\n".encode())
        subprocess.Popen(cmd, shell=True, stdout=f, stderr=f)
    except Exception:
        subprocess.Popen(cmd, shell=True)

def is_codespace():
    return bool(os.environ.get("CODESPACE_NAME"))

# ---------- helpers ----------
def role_ok(role, key):
    if role == "host":  return key and key == HOST_PW
    if role == "viewer": return key and (key == VIEW_PW or key == HOST_PW)
    return False

def pack_states():
    """Состояние каждого пака: ready (распакован) / cached (AppImage скачан) /
    absent + хвост лога установки — для индикации в лаунчере."""
    out = {}
    for pid, p in (CATALOG.get("packs") or {}).items():
        bin_path = Path("/opt/games/runtime") / pid / p.get("bin", "x")
        src = Path("/opt/games/src") / f"{pid}.AppImage"
        state = "absent"
        if bin_path.exists(): state = "ready"
        elif src.exists(): state = "cached"
        log = Path(f"/tmp/run-game-{pid}.log")
        tail = []
        if log.exists():
            tail = [l for l in log.read_text(errors="replace").strip().splitlines()[-4:]]
        out[pid] = {"state": state, "log": tail}
    return out

def session_state():
    return {
        "uptime_s": int(time.time() - session["started"]),
        "game": read(STATE / "current_game", None),
        "game_status": read(STATE / "game_status", ""),
        "game_pid": int(read(STATE / "game.pid", "0") or 0),
        "auto_stop_at": session["auto_stop_at"],
        "is_codespace": is_codespace(),
        "players": {n: int(time.time() - p["ts"]) for n, p in session["players"].items()},
        "packs": pack_states(),
    }

def stream_url(request):
    """Прямой URL Selkies-стрима (8080). В Codespaces порт публикуется публично."""
    cs = os.environ.get("CODESPACE_NAME")
    if cs:
        return f"https://{cs}-8080.app.github.dev"
    env = os.environ.get("JBOX_STREAM_URL")
    if env:
        return env.rstrip("/")
    host = request.host.split(":")[0]
    scheme = request.headers.get("X-Forwarded-Proto", "http")
    return f"{scheme}://{host}:8080"

def touch_player(nick):
    nick = nick.strip()[:24]
    if nick: session["players"][nick] = {"ts": time.time()}
    # живые игроки = те, кто за последние 30 сек опрашивал
    session["players"] = {n: p for n, p in session["players"].items() if time.time() - p["ts"] < 30}

# ---------- routes ----------
async def index(_):
    return web.FileResponse("/opt/jbox/index.html")

async def api_state(request):
    reload_catalog()
    role = request.query.get("role", "viewer")
    key = request.query.get("key", "")
    if not role_ok(role, key):
        return web.json_response({"error": "bad role/key"}, status=403)
    touch_player(request.query.get("nick", ""))
    return web.json_response({
        "ok": True, "role": role,
        "catalog": CATALOG,
        "session": session_state(),
        "stream_url": stream_url(request),
        "stop_timeout": STOP_TIMEOUT,
        "selkies_up": shutil.which("ss") and "LISTEN" in subprocess.run(
            ["ss", "-tln"], capture_output=True, text=True).stdout or False,
    })

async def api_launch(request):
    body = await request.json()
    key, game_id = body.get("key"), body.get("game_id", "")
    if not role_ok("host", key):
        return web.json_response({"error": "host key required"}, status=403)
    pack = game_id.split(".")[0]
    if pack not in CATALOG.get("packs", {}):
        return web.json_response({"error": "unknown pack"}, status=400)
    run_bg(f"DISPLAY=:99 /opt/jbox/run-game.sh {game_id!r} >> /tmp/run-game.log 2>&1")
    return web.json_response({"ok": True, "game_id": game_id})

async def api_stop_game(request):
    body = await request.json()
    if not role_ok("host", body.get("key")):
        return web.json_response({"error": "host key required"}, status=403)
    run_bg("/opt/jbox/stop-game.sh")
    return web.json_response({"ok": True})

async def api_keepalive(request):
    body = await request.json()
    if not (role_ok("host", body.get("key")) or role_ok("viewer", body.get("key"))):
        return web.json_response({"error": "bad key"}, status=403)
    session["auto_stop_at"] = None
    run_bg("touch /opt/jbox/state/keepalive")
    return web.json_response({"ok": True})

async def api_stop_session(request):
    body = await request.json()
    if not role_ok("host", body.get("key")):
        return web.json_response({"error": "host key required"}, status=403)
    # сохранить изменения (если git) и заглушить машину
    run_bg("cd /workspaces 2>/dev/null && cd */ && git add -A >/dev/null 2>&1; true")
    cs = os.environ.get("CODESPACE_NAME", "")
    if cs:
        run_bg(f"gh codespace stop {cs!r}")
    return web.json_response({"ok": True, "stopped": bool(cs)})

async def api_chat_post(request):
    body = await request.json()
    key, nick, text = body.get("key"), body.get("nick", ""), body.get("text", "").strip()[:300]
    if not role_ok(body.get("role", "viewer"), key):
        return web.json_response({"error": "bad key"}, status=403)
    if not text:
        return web.json_response({"error": "empty"}, status=400)
    session["chat_id"] += 1
    session["chat"].append({"id": session["chat_id"], "nick": nick[:24] or "anon", "text": text, "ts": int(time.time())})
    session["chat"] = session["chat"][-200:]
    touch_player(nick)
    return web.json_response({"ok": True})

async def api_chat_get(request):
    since = int(request.query.get("since", "0"))
    touch_player(request.query.get("nick", ""))
    msgs = [m for m in session["chat"] if m["id"] > since]
    # long poll: ждём до 25 сек, если пусто
    if not msgs:
        try:
            async def _wait():
                for _ in range(50):
                    if any(m["id"] > since for m in session["chat"]): return
                    await asyncio.sleep(0.5)
            await _wait()
        except asyncio.CancelledError:
            pass
        msgs = [m for m in session["chat"] if m["id"] > since]
    return web.json_response({"msgs": msgs, "session": session_state()})

# ---------- CORS (чтобы хаб-сайт мог запрашивать статус) ----------
@web.middleware
async def cors_mw(request, handler):
    if request.method == "OPTIONS":
        r = web.Response(status=204)
    else:
        r = await handler(request)
    r.headers["Access-Control-Allow-Origin"] = "*"
    r.headers["Access-Control-Allow-Headers"] = "Content-Type"
    r.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
    return r

# ---------- app ----------
async def on_startup(app):
    asyncio.create_task(_keepalive_poller())

async def _keepalive_poller():
    while True:
        _poll_keepalive_file()
        # чистка игроков, ушедших > 60 c
        now = time.time()
        session["players"] = {n: p for n, p in session["players"].items() if now - p["ts"] < 60}
        await asyncio.sleep(5)

app = web.Application(client_max_size=1024**2, middlewares=[cors_mw])
app.on_startup.append(on_startup)
app.router.add_get("/", index)
app.router.add_get("/api/state", api_state)
app.router.add_post("/api/launch", api_launch)
app.router.add_post("/api/stop-game", api_stop_game)
app.router.add_post("/api/stop-session", api_stop_session)
app.router.add_post("/api/keepalive", api_keepalive)
app.router.add_get("/api/chat", api_chat_get)
app.router.add_post("/api/chat", api_chat_post)

if __name__ == "__main__":
    PID.write_text(str(os.getpid()))
    web.run_app(app, host="0.0.0.0", port=8081, print=None)
