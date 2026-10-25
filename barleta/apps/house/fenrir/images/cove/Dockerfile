FROM ubuntu:24.04 AS cove-release
ARG COVE_VERSION=1.6.0
ARG COVE_SHA256=9e8946e880ffb699a638f8aebd070c4b34ad3fc30305c8d4cb642e9a558f04e1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && mkdir -p /release /Volumes/4TB_Drive/tmp/cove-release \
    && curl -fL "https://github.com/coveninja/cove/releases/download/v${COVE_VERSION}/cove-linux-amd64.tar.gz" \
       -o /Volumes/4TB_Drive/tmp/cove-release/archive.tar.gz \
    && echo "${COVE_SHA256}  /Volumes/4TB_Drive/tmp/cove-release/archive.tar.gz" | sha256sum -c - \
    && tar -xzf /Volumes/4TB_Drive/tmp/cove-release/archive.tar.gz -C /release

FROM ubuntu:24.04 AS remote-build
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk-headless python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY remote /Volumes/4TB_Drive/tmp/cove-remote-build/src
COPY --from=cove-release /release/lib/cove/Cove/lib/app /Volumes/4TB_Drive/tmp/cove-remote-build/app
RUN bash /Volumes/4TB_Drive/tmp/cove-remote-build/src/build.sh /Volumes/4TB_Drive/tmp/cove-remote-build/out \
    /Volumes/4TB_Drive/tmp/cove-remote-build/app \
    && python3 /Volumes/4TB_Drive/tmp/cove-remote-build/src/build-tv-back.py \
       /Volumes/4TB_Drive/tmp/cove-remote-build/app /Volumes/4TB_Drive/tmp/cove-remote-build/out

FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/jefflouisma/homelab"
LABEL org.opencontainers.image.description="Cove media player for Fenrir and Moonlight"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 pulseaudio-utils dbus-x11 \
      xwayland openbox x11-utils x11-xserver-utils xdotool \
      libmpv2 libgtk-3-0t64 libasound2t64 libatomic1 \
      libgl1 libegl1 libgbm1 libgl1-mesa-dri \
      libxrender1 libxtst6 libxi6 libxrandr2 libxfixes3 libxinerama1 libxcursor1 \
      fonts-dejavu-core fonts-noto-color-emoji fontconfig \
    && ln -s /usr/lib/x86_64-linux-gnu/libmpv.so.2 /usr/local/lib/libmpv.so \
    && ldconfig \
    && rm -rf /var/lib/apt/lists/* \
    && userdel ubuntu && groupadd -g 1000 retro && useradd -u 1000 -g 1000 -m -s /bin/bash retro \
    && install -d -o 1000 -g 1000 /Volumes/4TB_Drive/tmp/cove
COPY --from=cove-release /release/ /usr/
COPY start-cove.sh /usr/local/bin/start-cove
COPY install-torrentio.py /usr/local/lib/fenrir/install-torrentio.py
COPY init-remote-pointer.py /usr/local/lib/fenrir/init-remote-pointer.py
COPY openbox.xml /etc/fenrir/openbox.xml
COPY patch-video-alpha.py /usr/local/lib/fenrir/patch-video-alpha.py
COPY video-alpha.patch /usr/share/doc/cove/video-alpha.patch
COPY --from=remote-build /Volumes/4TB_Drive/tmp/cove-remote-build/out/cove-remote.jar /usr/local/lib/fenrir/cove-remote.jar
COPY --from=remote-build /Volumes/4TB_Drive/tmp/cove-remote-build/out/back/com/coveninja/cove/ui/platform/PlaybackBackHandler_desktopKt.class /usr/local/lib/fenrir/cove-back.class
COPY --from=remote-build /Volumes/4TB_Drive/tmp/cove-remote-build/out/tv/ /usr/local/lib/fenrir/cove-tv/
COPY desktop-back.patch /usr/share/doc/cove/desktop-back.patch
COPY remote /usr/share/doc/cove/remote
COPY --from=remote-build /Volumes/4TB_Drive/tmp/cove-remote-build/out/CoveTvApp.kt /usr/share/doc/cove/remote/CoveTvApp.kt
COPY --from=remote-build /Volumes/4TB_Drive/tmp/cove-remote-build/out/TvTextField.kt /usr/share/doc/cove/remote/TvTextField.kt
COPY patch-remote-launcher.py /usr/local/lib/fenrir/patch-remote-launcher.py
RUN python3 /usr/local/lib/fenrir/patch-video-alpha.py /usr/lib/cove/Cove \
    && python3 /usr/local/lib/fenrir/patch-remote-launcher.py /usr/lib/cove/Cove \
    && chmod 755 /usr/local/bin/start-cove \
    && LD_LIBRARY_PATH=/usr/lib/cove/Cove/lib/runtime/lib:/usr/lib/cove/Cove/lib/runtime/lib/server \
       ldd /usr/lib/cove/Cove/lib/runtime/lib/libawt_xawt.so > /tmp/cove-ldd \
    && ! grep -q 'not found' /tmp/cove-ldd && rm /tmp/cove-ldd
ENV HOME=/home/retro COVE_DATA_DIR=/home/retro/.config/cove
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/start-cove"]
