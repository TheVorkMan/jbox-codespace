# Jackbox Stream на своём VPS (задел, не тестировалось)

Идея: те же скрипты из `scripts/`, но в Docker на вашей машине — без лимитов
GitHub Codespaces, свой домен, полноценный WebRTC (UDP доступен).

## Быстрый старт

```bash
cd vps
docker compose up -d --build
# лог: docker compose logs -f jbox
# пароли: docker compose exec jbox cat /opt/jbox/env.sh
```

Открыть `http://<ip>:8081` (веб-клиент), стрим: `http://<ip>:8080`.

## Что внутри

- Тот же Selkies (AppImage) + все скрипты репозитория монтируются в /opt/jbox
- Кэш AppImage-ов — в volume `gamecache`, распакованные паки — `runtime`
- WebRTC (UDP) работает: переключите `--mode webrtc` в scripts/start-selkies.sh
- Автостоп: JBOX_STOP_TIMEOUT работает так же; вместо `gh codespace stop`
  контейнер останавливает сам docker (--stop-timeout в compose не нужен)

## Ограничения

- GPU-ускорение (VA-API/NVENC) не настроено — используется CPU-энкодер x264
- Без HTTPS: поставьте Caddy/nginx перед 8080/8081 (стрим идёт по WSS,
  браузер требует защищённый контекст для gamepad/clipboard — необязательны)
