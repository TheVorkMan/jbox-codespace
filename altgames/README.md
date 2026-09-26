# Альтернативные игры (не-Jackbox)

Система для игр вне единого Jackbox-бандла: тестовые билды, Godot/Unity-игры,
Windows-игры через Wine (например **Dub Together**).

## Из чего состоит

| Файл | Роль |
|---|---|
| `scripts/altgames.py` | движок: загрузка ZIP по прямой ссылке, распаковка, манифесты, jobs |
| `scripts/run-alt.sh` | запуск alt-игры по манифесту (native или Wine) |
| `scripts/api_server.py` | `/api/altgames/*` + слияние alt-игр в общий лаунчер |
| `web/index.html` | секция «Другие игры» в опциях хоста +alt-группа в лаунчере |
| `altgames/manifests/` | манифесты игр, объявленных в репо (кнопка «подключить» в UI) |
| `/opt/jbox-alt/` | контейнер: `games/`, `manifests/`, `jobs/`, `archives/`, `prefixes/` |

## Как это работает

1. **Загрузка**: хост в веб-клиенте открывает Опции → «Другие игры», вставляет
   **прямую ссылку на незашифрованный ZIP** и путь распаковки, например
   `dub-together`. Скачивание идёт в контейнер с прогрессом (3 повтора,
   watchdog на обрыв), распаковка — со страховкой от zip-slip.
2. **Манифест**: по окончании создаётся `_auto-<Game>.json` (exe определяется
   по подсказкам; можно задать поле `exe` сразу в форме загрузки или поправить
   потом через «Указать exe»).
3. **Запуск**: игра появляется в общем лаунчере; `/api/launch` сам вызывает
   `run-alt.sh` для alt-игр (state-файлы и аудио-окружение — те же, что у
   Jackbox-игр, так что стрим/звук работают без изменений).
4. **Wine**: bootstrap ставит `wine64`; при первом запуске игры создаётся
   префикс `/opt/jbox-alt/prefixes/<game_id>`. Для Godot-игр (Dub Together)
   нужные X-библиотеки тоже ставит bootstrap.

## API (host)

```
GET  /api/altgames/list           — alt-игры + активные загрузки + хвост лога
POST /api/altgames/add            — {url, dest, name?, title?, exe?, kind?, cmd?} → {id}
GET  /api/altgames/job?id=...     — прогресс загрузки
POST /api/altgames/cancel         — {id}
POST /api/altgames/remove         — {game_id} (только _auto-игры)
POST /api/altgames/config         — {game_id, exe?/title?/kind?/cmd?}
```

## Формат манифеста

```json
{
  "game_id": "DubTogether",
  "title": "Dub Together",
  "kind": "wine",
  "dir": "dub-together",
  "exe": "DubTogether.exe",
  "args": "",
  "env": {"GODOT_...": "..."}
}
```

- `kind`: `native` | `wine` | `auto` (по расширению exe).
- `exe`/`cmd` — путь точки запуска **относительно** `dir` (внутри
  `/opt/jbox-alt/games/`).
- `dir` — папка внутри `/opt/jbox-alt/games/` (то, что вы указали как путь
  распаковки при загрузке).
- Манифесты без `_`-префикса объявляются в репо (`altgames/manifests/`) и
  перекачиваются в контейнер post-start-скриптом; такие игры удаляются из UI
  (загрузчик управляет только `_auto-*`).
- Игра без `exe`/`cmd` не показывается в лаунчере.

## Dub Together — план

1. **Игра**: ZIP с билдом (например, из itch.io или экспорт Godot) → прямая
   ссылка → загрузка в `dub-together` → указать exe.
2. **Контент Steam Workshop**: steamcmd+anonymous качать не может — ZIP
   содержимым `steamapps/workshopcontent/<appid>/<publishedfileid>` грузится
   отдельной загрузкой в `dub-together/workshop/` (путь согласовать с тем,
   куда игра смотрит). Затем «Указать exe» не трогаем, игру перезапускаем.
3. **Микрофон**: участникам микрофон не нужен — требуют его *веб-интерфейс*
   игры (пользовать микрофон стрима будет хост). Веб-клиент уже проксирует
   клавиатуру/мышь; если игре нужен именно локальный ввод из браузера —
   отдельная задача (WebRTC-микрофон в Selkies).

## CLI (внутри codespace)

```
python3 /opt/jbox/altgames.py list
python3 /opt/jbox/altgames.py jobs
python3 /opt/jbox/altgames.py add <url> <dest> [name]
```
