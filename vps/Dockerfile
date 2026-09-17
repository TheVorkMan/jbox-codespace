FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y -qq \
    python3 python3-pip curl ca-certificates fuse3 libfuse2t64 \
    xvfb openbox xdotool x11-utils x11-xserver-utils xserver-xorg-core \
    libgl1 libegl1 libgbm1 libxkbcommon0 \
    libasound2t64 libpulse0 pulseaudio pulseaudio-utils \
    fonts-dejavu-core gh \
 && pip3 install --break-system-packages --quiet aiohttp \
 && rm -rf /var/lib/apt/lists/*

# Скрипты из репо
COPY scripts/ /opt/jbox/
COPY .devcontainer/install-selkies.sh /opt/jbox/install-selkies.sh
COPY .devcontainer/install-games.sh /opt/jbox/install-games.sh
COPY web/index.html /opt/jbox/index.html
COPY catalog.json /opt/games/catalog.json
RUN chmod +x /opt/jbox/*.sh

# Selkies
RUN bash /opt/jbox/install-selkies.sh

# Паки: при первом старте качаются в volume
VOLUME ["/opt/games/src", "/opt/games/runtime", "/opt/jbox/state"]

EXPOSE 8080 8081
CMD ["/bin/bash", "-c", "/opt/jbox/start-selkies.sh & python3 /opt/jbox/api_server.py"]
