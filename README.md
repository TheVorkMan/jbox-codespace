# jbox-codespace — Jackbox в GitHub Codespaces (единый бандл)

Сессия Jackbox в браузере: стрим (Selkies), лаунчер и jackbox.fun в одном
веб-клиенте на порту 8081; стрим проксируется тем же сервером (`/stream/`),
так что клиент живёт на одном origin и URL codespace наружу не светится.

## Архитектура

```
браузер ── порт 8081 (этот репозиторий)
           ├── /            веб-клиент (Material, стрим на всю вкладку)
           ├── /api/*       лаунчер / опции / автостоп
           └── /stream/*    прокси в Selkies (HTTP + WebSocket), порт 8080
```

- **Игры** — единое дерево `/opt/jbox-unified` (copper+gold с
  github.com/tryanddmca/images): `bin/jpp7|jpp11` — движки двух эпох,
  `launchers/*.sh` — по одному лаунчеру на игру, `shared/games` — пул игр.
  Лаунчер сам знает свой движок и swf; `api_server.py` парсит лаунчеры и
  отдаёт в UI только игры, чьи файлы реально есть в пуле.
- **Установка бандла** — `.devcontainer/install-games.sh` качает copper
  (55 МБ) и gold (3 части, 4.1 ГБ) и распаковывает **стримингом**
  (`age -d | zstd -d | tar -x`), без промежуточных файлов на диске.
  Пассфраза: `JBOX_AGE_PASS` (Codespaces Secret), дефолт — `lickmaballs`.
- **Хуки Selkies** (`on-connect/on-disconnect`) ведут автостоп: последний
  зритель отключился → через `JBOX_STOP_TIMEOUT` (по умолчанию 20 c) хаб/API
  останавливает codespace. `touch /opt/jbox/state/keepalive` отменяет.

## Быстрый старт (свой форк)

1. Форкните репозиторий, в Settings → Secrets → Codespaces добавьте
   `JBOX_HOST_PW`, `JBOX_VIEW_PW` (и опционально `JBOX_AGE_PASS`).
2. Code → Create codespace (2-core — 120 core-часов/мес на бесплатном плане).
3. Дождитесь `BOOTSTRAP-DONE` в `/tmp/bootstrap.log`; бандл игр ставится там же.
4. Откройте порт 8081 → ключ `host` из `/opt/jbox/env.sh`.
5. Игрокам — viewer-ключ и ссылку из хаба (`jbox-hub`, режим «Подключение»).

## Отладка

| Симптом | Где смотреть |
|---|---|
| не стартует codespace / bootstrap | `/tmp/bootstrap.log` |
| бандл не установился | `/tmp/install-games.err`, `bash .devcontainer/install-games.sh` |
| игра не запустилась | `/tmp/run-game.log`, `/tmp/game.log` |
| стрим не поднимается | `/tmp/selkies.log`, `bash .devcontainer/doctor.sh` |
| API не отвечает | `/tmp/api.log`, `/tmp/jbox-api-bg.log` |

## Лимиты и часы

- 2-core codespace = 120 core-часов/мес бесплатно; автостоп экономит часы.
- Бандл ~4.6 ГБ на диске (storage-лимит 15 ГБ core-плана — ок).
- CI-образ с предустановленным бандлом — будущий шаг (`.github/workflows/`).

## VPS

`vps/` — тот же стек в Docker без лимитов: `docker compose up` в `vps/`.
