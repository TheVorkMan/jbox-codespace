#!/usr/bin/env python3
"""API + веб-клиент для Jackbox-стрима (порт 8081).

Одна страница для всех, роль определяется ключом (host/viewer).
Стрим Selkies (порт 8080) встроен через <iframe src="/stream/"> — этот сервер
проксирует его (HTTP + WebSocket), так что клиент живёт на ОДНОМ origin и
 Codespaces URL наружу не светится.

API:
  GET  /api/state?role=..&key=..        — игры, статус сессии, флаги роли
  POST /api/launch {game_id}            — запустить игру (host)
  POST /api/stop-game                   — остановить игру (host)
  POST /api/stop-session                — остановить codespace (host)
  POST /api/keepalive                   — отменить автостоп (host)
  GET  /api/verify                      — проверить целостность дерева игр (host)
"""
import asyncio
import json
import os
import re
import subprocess
import time
from pathlib import Path

from aiohttp import ClientSession, web, WSMsgType

STATE = Path("/opt/jbox/state"); STATE.mkdir(parents=True, exist_ok=True)
UNIFIED = Path(os.environ.get("JBOX_UNIFIED_DIR", "/opt/jbox-unified"))
PID = Path("/tmp/jbox-api.pid")
SELKIES = "http://127.0.0.1:8080"

# ---------- env (env.sh парсим вручную: там bash-синтаксис) ----------
def _expand_shell(v):
    def repl_default(m):
        name, _, default = m.group(1).partition(":-")
        return os.environ.get(name, default)
    v = re.sub(r"\$\{([^}]+)\}", repl_default, v)
    v = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", lambda m: os.environ.get(m.group(1), ""), v)
    return v

def _int_env(v, default):
    try: return int(str(v).strip())
    except (TypeError, ValueError): return default

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

# ---------- каталог игр: парсим лаунчеры ----------
def load_games():
    """[{id, title, pack, desc}] из launchers/*.sh + comments."""
    games = []
    ldir = UNIFIED / "launchers"
    if not ldir.is_dir():
        return games
    for f in sorted(ldir.glob("*.sh")):
        try:
            head = f.read_text(errors="replace").splitlines()[:2]
            comment = head[1][2:].strip() if len(head) > 1 and head[1].startswith("# ") else ""
            pack, _, title = comment.partition(" — ")
            body = f.read_text(errors="replace")
            m = re.search(r'launchTo (games/[^ ]+\.swf)', body)
            swf = m.group(1) if m else ""
            # игра доступна только если swf существует
            m2 = re.search(r'PACK="\$ROOT/bin/([^"]+)"', body)
            eng = m2.group(1) if m2 else ""
            ok = bool(swf) and (UNIFIED / "bin" / eng / swf).exists()
            games.append({
                "id": f.stem, "title": title or f.stem,
                "pack": pack or eng, "ok": ok,
            })
        except Exception:
            continue
    return games

GAMES_CACHE = {"ts": 0, "list": []}
def games():
    now = time.time()
    if now - GAMES_CACHE["ts"] > 5:
        GAMES_CACHE["list"] = load_games()
        GAMES_CACHE["ts"] = now
    # отдаём только реально запускаемые: у части лаунчеров игр нет в пуле
    # shared/games (бандл собран из высокорейтинговых) - они мертвы
    return [g for g in GAMES_CACHE["list"] if g["ok"]]

# ---------- session state ----------
session = {"auto_stop_at": None, "started": time.time()}

def read(path, default=None):
    try: return Path(path).read_text().strip()
    except Exception: return default

def _poll_keepalive_file():
    ld = read(STATE / "last_disconnect")
    if (STATE / "keepalive").exists():
        session["auto_stop_at"] = None
    elif ld:
        try:
            t = int(ld) + STOP_TIMEOUT
            if t > time.time() - 300:
                session["auto_stop_at"] = t
        except ValueError:
            pass

def run_bg(cmd):
    f = open("/tmp/jbox-api-bg.log", "ab")
    f.write(f"\n[{time.strftime('%m-%d %H:%M:%S')}] $ {cmd}\n".encode())
    subprocess.Popen(cmd, shell=True, stdout=f, stderr=f)

def is_codespace():
    return bool(os.environ.get("CODESPACE_NAME"))

def session_state():
    return {
        "uptime_s": int(time.time() - session["started"]),
        "game": read(STATE / "current_game", None),
        "game_status": read(STATE / "game_status", ""),
        "game_pid": int(read(STATE / "game.pid", "0") or 0),
        "auto_stop_at": session["auto_stop_at"],
        "is_codespace": is_codespace(),
    }

def role_ok(role, key):
    if role == "host": return key and key == HOST_PW
    if role == "viewer": return key and (key == VIEW_PW or key == HOST_PW)
    return False

# ---------- Selkies proxy (HTTP + WebSocket) ----------
async def proxy_handler(request):
    """Проксирует /stream/* в Selkies на 8080 (WebSocket — прозрачно)."""
    target = SELKIES + request.rel_url.path_qs
    is_ws = request.headers.get("Upgrade", "").lower() == "websocket"
    if is_ws:
        ws_server = web.WebSocketResponse()
        await ws_server.prepare(request)
        async with ClientSession(cookies=request.cookies) as cs:
            try:
                async with cs.ws_connect(target, headers=_auth_headers(request)) as ws_client:
                    async def pump(c, s):
                        async for msg in c:
                            if msg.type == WSMsgType.TEXT:
                                await s.send_str(msg.data)
                            elif msg.type == WSMsgType.BINARY:
                                await s.send_bytes(msg.data)
                            elif msg.type == WSMsgType.ERROR:
                                break
                    t1 = asyncio.create_task(pump(ws_client, ws_server))
                    t2 = asyncio.create_task(pump(ws_server, ws_client))
                    await asyncio.gather(t1, t2, return_exceptions=True)
            except Exception:
                pass
        return ws_server
    # обычный HTTP
    body = await request.read()
    try:
        async with ClientSession() as cs:
            async with cs.request(request.method, target, data=body,
                                  headers=_auth_headers(request),
                                  allow_redirects=False) as resp:
                headers = {k: v for k, v in resp.headers.items()
                           if k.lower() not in ("content-encoding", "content-length", "transfer-encoding", "connection")}
                data = await resp.read()
                return web.Response(status=resp.status, headers=headers, body=data)
    except Exception as e:
        return web.json_response({"error": f"stream unavailable: {e}"}, status=502)

def _auth_headers(request):
    h = {k: v for k, v in request.headers.items()
         if k.lower() in ("authorization", "content-type", "user-agent", "accept", "origin")}
    return h

# ---------- routes ----------
async def index(_):
    return web.FileResponse("/opt/jbox/index.html")

async def api_state(request):
    role = request.query.get("role", "viewer")
    key = request.query.get("key", "")
    if not role_ok(role, key):
        return web.json_response({"error": "bad role/key"}, status=403)
    selkies_up = "LISTEN" in subprocess.run(["ss", "-tln"], capture_output=True, text=True).stdout
    return web.json_response({
        "ok": True, "role": role,
        "games": games(),
        "session": session_state(),
        "stop_timeout": STOP_TIMEOUT,
        "is_codespace": is_codespace(),
        "selkies_up": selkies_up,
    })

async def api_launch(request):
    body = await request.json()
    if not role_ok("host", body.get("key")):
        return web.json_response({"error": "host key required"}, status=403)
    gid = (body.get("game_id") or "").strip()
    if not gid or "/" in gid or not any(g["id"] == gid for g in games()):
        return web.json_response({"error": "unknown game"}, status=400)
    run_bg(f"DISPLAY=:99 /opt/jbox/run-game.sh {gid!r} >> /tmp/run-game.log 2>&1")
    return web.json_response({"ok": True, "game_id": gid})

async def api_stop_game(request):
    body = await request.json()
    if not role_ok("host", body.get("key")):
        return web.json_response({"error": "host key required"}, status=403)
    run_bg("/opt/jbox/stop-game.sh")
    return web.json_response({"ok": True})

async def api_verify(request):
    body = await request.json()
    if not role_ok("host", body.get("key")):
        return web.json_response({"error": "host key required"}, status=403)
    r = subprocess.run(["bash", "/opt/jbox/run-game.sh", "--verify"], capture_output=True, text=True)
    return web.json_response({"ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-2000:]})

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
    cs = os.environ.get("CODESPACE_NAME", "")
    if cs:
        run_bg(f"gh codespace stop {cs!r}")
    return web.json_response({"ok": True, "stopped": bool(cs)})

# ---------- CORS ----------
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
        await asyncio.sleep(5)

app = web.Application(client_max_size=1024**2, middlewares=[cors_mw])
app.on_startup.append(on_startup)
app.router.add_get("/", index)
app.router.add_get("/api/state", api_state)
app.router.add_post("/api/launch", api_launch)
app.router.add_post("/api/stop-game", api_stop_game)
app.router.add_post("/api/verify", api_verify)
app.router.add_post("/api/stop-session", api_stop_session)
app.router.add_post("/api/keepalive", api_keepalive)
# proxy всего остального (не /api, не статика) -> Selkies
app.router.add_route("*", "/stream/{tail:.*}", proxy_handler)
app.router.add_get("/stream", proxy_handler)

if __name__ == "__main__":
    PID.write_text(str(os.getpid()))
    web.run_app(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8081")))
