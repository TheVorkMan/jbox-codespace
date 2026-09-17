# jbox-codespace — Jackbox Party Pack в браузере (GitHub Codespaces + Selkies)

**Серверная часть** проекта JBox (пара: [jbox-hub](../jbox-hub) — сайт-панель
для GitHub Pages). Форкни это репо, создай codespace — получишь стрим Jackbox
из браузера: лаунчер игр, чат, зрители по QR, автостоп для экономии часов.

Стек: **Selkies v2** (WebSocket-стрим, single-binary AppImage), Xvfb+openbox,
PulseAudio null-sink, API на aiohttp (8081), веб-клиент.

## Архитектура

```
Браузер хоста ──► 8081 (веб-клиент: лаунчер, чат, QR, автостоп)
Браузер хоста ──► 8080 (Selkies: видео+аудио+ввод, basic-auth host)
Телефон игрока ─► 8081 (клиент: просмотр, чат, jackbox.fun)
Телефон игрока ─► jackbox.tv (комнату игры — напрямую, не через нас)
```

## Быстрый старт

1. **Форк** этого репо себе.
2. (Опционально, рекомендую) Settings → Secrets and variables → Codespaces →
   New repository secret:
   - `JBOX_HOST_PW` — пароль хоста
   - `JBOX_VIEW_PW` — пароль зрителя
   - `JBOX_PRELOAD` = `1` — качать все паки при провижининге (медленный старт,
     но потом мгновенный запуск игр)
   Без секретов пароли сгенерируются сами (лог: `tail /tmp/bootstrap.log | grep passwords`).
3. Code → **Create codespace on main** (2-core по умолчанию) — или через
   [jbox-hub](../jbox-hub) сайт-панель.
4. Открой порт **8081** → введи host-пароль → лаунчер игр.
5. Зрители: QR/ссылка из клиента, viewer-пароль → просмотр + чат.

## Лимиты: как влезть в бесплатный Codespaces

Codespaces Free = **120 core-часов/мес**, реальное время умножается на ядра.
`hostRequirements.cpus: 2` → **60 часов** реального стрима в месяц.

Встроенная экономия:
- Последний зритель отключился → через `JBOX_STOP_TIMEOUT` (20 c по умолчанию)
  codespace глушится (`gh codespace stop`). Запуск — обратно из хаба или
  вкладки Codespaces на GitHub.
- Кнопка «Стоп-сессия» в веб-клиенте.
- `touch /opt/jbox/state/keepalive` — отменить запланированный автостоп.

Хватать должно: 60 ч × ~10 вечеров по 2 ч. Если нет — VPS-вариант ниже.

## Паки

Три уровня:
1. **Лениво** (по умолчанию): AppImage докачивается при первом запуске игры
   (30–60 c), кэш `/tmp/jbox-cache` переживает rebuild контейнера.
2. **Прелоад**: секрет `JBOX_PRELOAD=1` — все паки при провижининге.
3. **Готовый образ**: workflow `build-base.yaml` собирает GHCR-образ со всеми
   распакованными паками (когда доработаете подключение образа в devcontainer).

Источники AppImage-ов — в `catalog.json` (правится под свои паки).

## Безопасность

- Пароли: host (полный доступ) / viewer (только просмотр) — basic-auth Selkies.
- В Codespaces порты public — без GitHub-авторизации, но Selkies требует пароль.
- GitHub-токен (для хаба) — только на твоём браузере, в codespace не попадает.

## Структура

```
catalog.json            — паки (AppImage) + игры (окна, лимиты игроков)
.devcontainer/          — devcontainer.json, bootstrap, install-*, post-start
scripts/                — start-selkies, run-game, stop-game, on-connect/disconnect, api_server.py
web/index.html          — веб-клиент (host/viewer)
.github/workflows/      — build-base.yaml (GHCR-образ со всеми паками)
vps/                    — Docker-вариант для своего VPS (без лимитов, WebRTC)
```

## VPS-вариант

Свой сервер = нет лимитов, свой домен, можно включить WebRTC (`--mode webrtc`).
Инструкция — [vps/README.md](vps/README.md). Хаб умеет открывать URL VPS в
том же интерфейсе.

## Идеи на будущее

- [ ] Интеграция Jackbox Utility (окна 7+ паков)
- [ ] Коллекции паков: 2–3 GHCR-образа вместо одного большого
- [ ] Автостарт комнаты через Ephemeral API (+QR с room code)
- [ ] Голосовой чат зрителей (WebRTC)
- [ ] Cloudflare Access перед Codespaces URL (нормальная auth поверх basic-auth)
