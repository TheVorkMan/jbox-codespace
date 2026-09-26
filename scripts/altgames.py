#!/usr/bin/env python3
"""altgames.py — движок «альтернативных игр» (не-Jackbox).

Что умеет:
  * скачать ZIP по прямой http(s)-ссылке (стримингово, с ретраями и прогрессом);
  * распаковать в указанный каталог внутри games/ (с защитой от zip-slip);
  * записать манифест игры — по нему UI-лаунчер и run-alt.sh запускают игру
    нативно или через Wine.

Каталоги (корень — JBOX_ALT_DIR, по умолчанию /opt/jbox-alt):
  games/      распакованные игры (каждая в своей папке)
  archives/   временные файлы загрузок (в конце удаляются в любом случае)
  manifests/  *.json-манифесты (файлы с префиксом «_», кроме _auto-*, игнорируются)
  jobs/       файлы прогресса загрузок (<jobid>.json)

Манифест игры:
  {"game_id": "DubTogether", "title": "Dub Together", "kind": "wine",
   "exe": "DubTogether.exe", "dir": "DubTogether"}
  kind: native | wine | auto (по расширению exe); exe/cmd — пути относительно dir.

CLI для отладки:
  python3 altgames.py list
  python3 altgames.py jobs
  python3 altgames.py add <url> <dest> [name]
"""
import json
import os
import re
import shutil
import time
import traceback
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlparse

ALT_LOG = os.environ.get("JBOX_ALT_LOG", "/tmp/jbox-alt.log")
MAX_ARCHIVE = 8 * 1024 ** 3   # 8 ГБ — страховка от «бесконечных» ссылок
STALL_S = 90                  # столько секунд без байт считаем обрывом соединения


class Cancelled(Exception):
    """Загрузка отменена через /api/altgames/cancel."""


# ---------- каталоги ----------
def _dirs():
    root = Path(os.environ.get("JBOX_ALT_DIR", "/opt/jbox-alt"))
    games = root / "games"
    archives = root / "archives"
    manifests = root / "manifests"
    jobs = root / "jobs"
    for d in (games, archives, manifests, jobs):
        d.mkdir(parents=True, exist_ok=True)
    return root, games, archives, manifests, jobs


def _elog(msg):
    try:
        with open(ALT_LOG, "a") as f:
            f.write(f"[{time.strftime('%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def log_tail(n=40):
    try:
        return "\n".join(Path(ALT_LOG).read_text(errors="replace").splitlines()[-n:])
    except Exception:
        return ""


# ---------- jobs (прогресс загрузок) ----------
def _job_path(job_id):
    _, _, _, _, jobs = _dirs()
    safe = re.sub(r"[^A-Za-z0-9._-]+", "", job_id or "")
    return jobs / f"{safe}.json"


def write_job(job_id, data):
    p = _job_path(job_id)
    data = dict(data)
    data["id"] = job_id
    data["updated"] = time.time()
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    os.replace(tmp, p)


def read_job(job_id):
    try:
        return json.loads(_job_path(job_id).read_text())
    except Exception:
        return None


def list_jobs():
    _, _, _, _, jobs = _dirs()
    out = []
    for f in sorted(jobs.glob("*.json")):
        try:
            out.append(json.loads(f.read_text()))
        except Exception:
            pass
    return out


def _upd(job_id, **kw):
    j = read_job(job_id) or {}
    j.update(kw)
    write_job(job_id, j)
    return j


def _cancel_marker(job_id):
    _, _, _, _, jobs = _dirs()
    return jobs / f"{_job_path(job_id).stem}.cancel"

def request_cancel(job_id):
    """Атомичная отмена: маркер-файл вместо правки job.json (нет гонок с _upd)."""
    _cancel_marker(job_id).touch()

def _check_cancel(job_id):
    if _cancel_marker(job_id).exists():
        raise Cancelled()


# ---------- манифесты ----------
def _manifest_files():
    """Манифест-файлы: репо-манифесты первыми, авто (_auto-*) последними."""
    _, _, _, mdir, _ = _dirs()
    files = [p for p in mdir.glob("*.json")
             if not p.name.startswith("_") or p.name.startswith("_auto-")]
    files.sort(key=lambda p: p.name.startswith("_auto-"))
    return files


def list_manifests():
    out = []
    for f in _manifest_files():
        try:
            m = json.loads(f.read_text())
            m["_file"] = f.name
            out.append(m)
        except Exception:
            continue
    return out


def _find_manifest_file(game_id):
    for f in _manifest_files():
        try:
            m = json.loads(f.read_text())
        except Exception:
            continue
        if m.get("game_id") == game_id:
            return f, m
    return None, None


def write_manifest(m, auto=False):
    _, _, _, mdir, _ = _dirs()
    gid = m.get("game_id") or ""
    if not gid:
        raise ValueError("manifest without game_id")
    fname = f"_auto-{gid}.json" if auto else f"{gid}.json"
    p = mdir / fname
    p.write_text(json.dumps(m, ensure_ascii=False, indent=1))
    return p


def alt_game_entries():
    """Записи для UI-лаунчера: [{id, title, pack, ok, is_alt, kind}]."""
    seen = set()
    out = []
    for m in list_manifests():
        gid = m.get("game_id")
        if not gid or gid in seen:
            continue
        seen.add(gid)
        exe = str(m.get("exe") or "")
        kind = m.get("kind") or ("wine" if exe.lower().endswith(".exe") else "native")
        out.append({
            "id": gid,
            "title": m.get("title") or gid,
            "pack": f"alt · {kind}",
            "ok": bool(m.get("exe") or m.get("cmd")),   # без exe/cmd запуск невозможен
            "is_alt": True,
            "kind": kind,
        })
    return out


def update_config(game_id, exe=None, title=None, kind=None, cmd=None):
    """Правка манифеста без перекачки (например, указать exe после загрузки)."""
    f, m = _find_manifest_file(game_id)
    if not f:
        raise ValueError("манифест не найден")
    for k, v in (("exe", exe), ("title", title), ("kind", kind), ("cmd", cmd)):
        if v:
            m[k] = str(v).strip()
    f.write_text(json.dumps(m, ensure_ascii=False, indent=1))
    return m


def remove_game(game_id):
    """Удалить alt-игру (только установленную через загрузчик, _auto-*)."""
    _, games_dir, _, _, _ = _dirs()
    f, m = _find_manifest_file(game_id)
    if not f:
        raise ValueError("манифест не найден")
    if not f.name.startswith("_auto-"):
        raise ValueError("эта игра объявлена манифестом в репозитории — она не управляется загрузчиком")
    d = m.get("dir") or ""
    if d:
        target = games_dir / d
        try:
            inside = str(target.resolve()).startswith(str(games_dir.resolve()) + os.sep)
        except Exception:
            inside = False
        if inside and target.is_dir():
            shutil.rmtree(target, ignore_errors=True)
    f.unlink(missing_ok=True)
    return True


# ---------- утилиты безопасности/имён ----------
def safe_dest(dest):
    """Относительный путь распаковки: без .., абсолюта и backslash; части санитизируем."""
    d = (dest or "").strip().replace("\\", "/")
    if not d or d.startswith("/"):
        return None
    parts = [p for p in d.split("/") if p != ""]
    if not parts:
        return None
    out = []
    for p in parts:
        if p in (".", ".."):
            return None
        p = re.sub(r"[^A-Za-z0-9._ ()-]+", "_", p).strip("_")
        if not p:
            return None
        out.append(p)
    return "/".join(out)


def _safe_component(s):
    s = (s or "").strip().strip("/")
    s = re.sub(r"[^A-Za-z0-9._ ()-]+", "_", s).strip()
    return s or None


def _game_id_from(name):
    gid = re.sub(r"[^A-Za-z0-9._-]+", "_", (name or "").strip()).strip("_")
    return gid or None


def _archive_name(url):
    n = os.path.basename(unquote(urlparse(url).path)) or "archive.zip"
    return re.sub(r"[^A-Za-z0-9._-]+", "_", n) or "archive.zip"


def _check_member(name, base):
    """zip-slip: абсолютные пути, backslash и выход за base запрещены."""
    if name.startswith("/") or "\\" in name or ".." in Path(name).parts:
        raise ValueError(f"опасный путь в архиве: {name!r}")
    rp = (base / name).resolve()
    if not str(rp).startswith(str(base.resolve()) + os.sep):
        raise ValueError(f"опасный путь в архиве: {name!r}")


def _find_exes(root):
    """Кандидаты на точку запуска — подсказка в job.exe_hints."""
    out = []
    for p in root.rglob("*"):
        if p.is_file() and p.suffix.lower() in (".exe", ".sh", ".bat", ".x86_64", ".appimage"):
            out.append(p.relative_to(root).as_posix())
    out.sort(key=lambda s: (len(s.split("/")), s))
    out.sort(key=lambda s: any(k in s.lower() for k in
                               ("uninstall", "setup", "redist", "crash", "unity", "mono", "vc_redist")))
    return out


# ---------- загрузка ----------
def fetch_size(url):
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "jbox-altgames/1.0"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return int(r.headers.get("Content-Length") or 0)
    except Exception:
        return 0


def _download(url, dest_file, job_id):
    """Стриминговое скачивание с прогрессом в job и watchdog-ом на обрыв."""
    req = urllib.request.Request(url, headers={"User-Agent": "jbox-altgames/1.0"})
    done = 0
    total = 0
    last_ui = 0.0
    stall_ts = time.time()
    stall_bytes = 0
    with urllib.request.urlopen(req, timeout=60) as r:
        try:
            total = int(r.headers.get("Content-Length") or 0)
        except ValueError:
            total = 0
        if total > MAX_ARCHIVE:
            raise ValueError(f"архив больше {MAX_ARCHIVE // (1024 ** 3)} ГБ")
        _upd(job_id, total=total)
        with open(dest_file, "wb") as f:
            while True:
                chunk = r.read(512 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if done == stall_bytes:
                    if time.time() - stall_ts > STALL_S:
                        raise IOError(f"загрузка не двигается {STALL_S} c — обрыв соединения")
                else:
                    stall_ts = time.time()
                    stall_bytes = done
                now = time.time()
                if now - last_ui >= 1.0:
                    last_ui = now
                    _check_cancel(job_id)
                    _upd(job_id, done=done, total=total,
                         pct=round(done * 100 / total, 1) if total else 0.0)
    return done, total


def download_and_install(job_id, url, dest, name=None, title=None, exe=None, kind=None, cmd=None):
    """Вся работа по одной загрузке. Запускается в отдельном потоке из api_server.

    Фазы: queued → downloading → extracting → finalizing → done | error | cancelled.
    Прогресс пишется в jobs/<id>.json, UI читает его через /api/altgames/job.
    """
    _, games_dir, archives_dir, _, _ = _dirs()
    staging = None
    arch = None
    _elog(f"[{job_id}] start: url={url} dest={dest} name={name} exe={exe} kind={kind}")
    try:
        dest = safe_dest(dest)
        if not dest:
            raise ValueError("некорректный путь распаковки")
        name = _safe_component(name)
        _upd(job_id, phase="downloading", url=url, dest=dest, done=0, total=0, pct=0.0, error=None)

        # --- 1. скачивание (до 3 попыток) ---
        arch = archives_dir / f"{job_id}_{_archive_name(url)}"
        total = fetch_size(url)
        if total:
            _upd(job_id, total=total)
        for attempt in range(1, 4):
            try:
                done, total = _download(url, arch, job_id)
                break
            except Cancelled:
                raise
            except Exception as e:
                if attempt == 3:
                    raise
                _elog(f"[{job_id}] attempt {attempt}/3 failed: {e!r}")
                _upd(job_id, log=f"повтор {attempt + 1}/3 после ошибки: {e}")
                time.sleep(2 * attempt)
        _upd(job_id, done=done, total=total,
             pct=round(done * 100 / total, 1) if total else 0.0, log="скачано")

        # --- 2. распаковка в staging ---
        _check_cancel(job_id)
        _upd(job_id, phase="extracting", done=0, total=0, pct=0.0, log="распаковка")
        staging = games_dir / f".staging-{job_id}"
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(parents=True)
        with zipfile.ZipFile(arch) as z:
            names = z.namelist()
            for n in names:
                _check_member(n, staging)
            total_n = len(names)
            for i, n in enumerate(names):
                _check_cancel(job_id)   # каждый вход — дёшево против гонки с отменой
                if i % 25 == 0:
                    _upd(job_id, done=i, total=total_n,
                         pct=round(i * 100 / total_n, 1) if total_n else 0.0)
                z.extract(n, staging)

        exes = _find_exes(staging)
        hint = ""
        top = [p.name for p in staging.iterdir()]
        if len(top) == 1 and (staging / top[0]).is_dir():
            hint = f"в корне архива одна папка «{top[0]}» — возможно, dest должен был включать её"

        # --- 3. размещение + манифест ---
        _check_cancel(job_id)
        if not staging.is_dir():
            raise IOError("staging-каталог исчез — внутренняя ошибка")
        _upd(job_id, phase="finalizing", log="размещение файлов")
        if name:
            target = games_dir / name
            if target.exists():
                shutil.rmtree(target)   # повторная загрузка заменяет игру
            shutil.move(str(staging), str(target))
            staging = None
            dest_actual = name
        else:
            final_dir = games_dir / dest
            final_dir.mkdir(parents=True, exist_ok=True)
            for p in staging.iterdir():
                t = final_dir / p.name
                if t.is_dir() and p.is_dir():
                    shutil.rmtree(t)
                os.replace(p, t)
            staging.rmdir()
            staging = None
            dest_actual = dest

        arch.unlink(missing_ok=True)
        gid = _game_id_from(name) or _game_id_from(Path(_archive_name(url)).stem) \
            or f"game-{job_id[-6:]}"
        exe = (exe or "").strip()
        kind = kind or ("wine" if exe.lower().endswith(".exe") else "native")
        m = {
            "game_id": gid,
            "title": (title or name or Path(_archive_name(url)).stem).strip() or gid,
            "kind": kind,
            "dir": dest_actual,
            "installed_at": int(time.time()),
        }
        if exe:
            m["exe"] = exe
        if cmd:
            m["cmd"] = cmd
        write_manifest(m, auto=True)
        _elog(f"[{job_id}] done: game_id={gid} dir={dest_actual} exe_hints={exes[:5]}")
        _upd(job_id, phase="done", done=1, total=1, pct=100.0, game_id=gid,
             dir=dest_actual, exe=exe, exe_hints=exes[:10], log=hint)
    except Cancelled:
        if arch:
            arch.unlink(missing_ok=True)
        if staging:
            shutil.rmtree(staging, ignore_errors=True)
        _cancel_marker(job_id).unlink(missing_ok=True)
        _elog(f"[{job_id}] cancelled")
        _upd(job_id, phase="cancelled", log="загрузка отменена")
    except Exception as e:
        if arch:
            arch.unlink(missing_ok=True)
        if staging:
            shutil.rmtree(staging, ignore_errors=True)
        _cancel_marker(job_id).unlink(missing_ok=True)
        _elog(f"[{job_id}] ERROR: {traceback.format_exc()}")
        _upd(job_id, phase="error", error=str(e)[:500])


def startup_sweep():
    """После рестарта API: подвисшие jobs (поток умер вместе с сервером) — в error."""
    _, _, archives_dir, _, _ = _dirs()
    for j in list_jobs():
        if j.get("phase") in ("queued", "downloading", "extracting", "finalizing") \
                and time.time() - j.get("updated", 0) > 120:
            j["phase"] = "error"
            j["error"] = "прервано рестартом сервера"
            write_job(j.get("id"), j)
            for a in archives_dir.glob(f"{j.get('id')}_*"):
                a.unlink(missing_ok=True)


# ---------- CLI ----------
if __name__ == "__main__":
    import sys

    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "list":
        for e in alt_game_entries():
            print(f"{e['id']:<28} {e['title']:<26} {e['pack']}{'' if e['ok'] else '   (нет exe/cmd!)'}")
    elif cmd == "jobs":
        for j in list_jobs():
            print(json.dumps(j, ensure_ascii=False))
    elif cmd == "add" and len(sys.argv) >= 4:
        jid = f"cli-{int(time.time())}"
        write_job(jid, {"id": jid, "phase": "queued"})
        download_and_install(jid, sys.argv[2], sys.argv[3],
                             name=sys.argv[4] if len(sys.argv) > 4 else None)
        print(json.dumps(read_job(jid), ensure_ascii=False, indent=1))
    else:
        print(__doc__)
