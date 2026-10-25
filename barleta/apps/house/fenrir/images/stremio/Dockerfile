# The official Stremio binary links libcrypto.so.1.1 but omits it from Depends.
# Resolve the compatibility package through Ubuntu's signed Focal apt metadata.
FROM ubuntu:20.04 AS openssl-compat
WORKDIR /compat
RUN apt-get update && apt-get download libssl1.1

FROM ubuntu:22.04
LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="Stremio desktop for Fenrir/Moonlight"
ARG STREMIO_VERSION=4.4.168
ARG STREMIO_SHA256=1028f1a38a70fc66bfcda1c8a9e1674231e17ac81774fc48859ed8f53c7a6039
ENV DEBIAN_FRONTEND=noninteractive
COPY --from=openssl-compat /compat/libssl1.1_*.deb /tmp/libssl1.1.deb
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl pulseaudio-utils qtwayland5 \
      fonts-dejavu-core fonts-noto-color-emoji dbus-x11 xdg-utils hicolor-icon-theme \
      python3 python3-websocket ffmpeg /tmp/libssl1.1.deb \
    && curl -fL "https://dl.strem.io/shell-linux/v${STREMIO_VERSION}/stremio_${STREMIO_VERSION}-1_amd64.deb" -o /tmp/stremio.deb \
    && echo "${STREMIO_SHA256}  /tmp/stremio.deb" | sha256sum -c - \
    && mkdir -p /usr/share/desktop-directories \
    && apt-get install -y --no-install-recommends /tmp/stremio.deb \
    && rm -f /tmp/stremio.deb /tmp/libssl1.1.deb && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 retro && useradd -u 1000 -g 1000 -m -s /bin/bash retro
COPY start-stremio.sh /usr/local/bin/start-stremio
COPY install-torrentio.py /usr/local/lib/fenrir/install-torrentio.py
RUN chmod 755 /usr/local/bin/start-stremio \
    && ldd /opt/stremio/stremio > /tmp/stremio-ldd \
    && ! grep -q 'not found' /tmp/stremio-ldd \
    && rm /tmp/stremio-ldd
ENV HOME=/home/retro QT_QPA_PLATFORM=wayland QTWEBENGINE_DISABLE_SANDBOX=1
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/start-stremio"]
