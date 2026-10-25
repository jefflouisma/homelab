FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="Cove media player for Fenrir and Moonlight"
ARG COVE_VERSION=1.6.0
ARG COVE_SHA256=9e8946e880ffb699a638f8aebd070c4b34ad3fc30305c8d4cb642e9a558f04e1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 pulseaudio-utils dbus-x11 \
      xwayland openbox x11-utils x11-xserver-utils xdotool \
      libmpv2 libgtk-3-0t64 libasound2t64 libatomic1 \
      libgl1 libegl1 libgbm1 libgl1-mesa-dri \
      libxrender1 libxtst6 libxi6 libxrandr2 libxfixes3 libxinerama1 libxcursor1 \
      fonts-dejavu-core fonts-noto-color-emoji fontconfig \
    && curl -fL "https://github.com/coveninja/cove/releases/download/v${COVE_VERSION}/cove-linux-amd64.tar.gz" -o /tmp/cove.tar.gz \
    && echo "${COVE_SHA256}  /tmp/cove.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/cove.tar.gz -C /usr \
    && ln -s /usr/lib/x86_64-linux-gnu/libmpv.so.2 /usr/local/lib/libmpv.so \
    && ldconfig \
    && rm /tmp/cove.tar.gz && rm -rf /var/lib/apt/lists/* \
    && userdel ubuntu && groupadd -g 1000 retro && useradd -u 1000 -g 1000 -m -s /bin/bash retro \
    && install -d -o 1000 -g 1000 /Volumes/4TB_Drive/tmp/cove
COPY start-cove.sh /usr/local/bin/start-cove
COPY install-torrentio.py /usr/local/lib/fenrir/install-torrentio.py
COPY openbox.xml /etc/fenrir/openbox.xml
RUN chmod 755 /usr/local/bin/start-cove \
    && ldd /usr/lib/cove/Cove/lib/runtime/lib/libawt_xawt.so > /tmp/cove-ldd \
    && ! grep -q 'not found' /tmp/cove-ldd && rm /tmp/cove-ldd
ENV HOME=/home/retro COVE_DATA_DIR=/home/retro/.config/cove
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/start-cove"]
