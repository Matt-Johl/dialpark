# Headless baresip phone (SPEC §7.1 audio seam, automated sibling). Audio in
# and out are WAV files via the aufile module, so a call's media can be
# asserted on by comparing recordings.
#
# Built from source: Debian 12/13 package baresip 1.0/1.1 (2020-21), whose
# aufile module cannot act as an audio source in our tests and which lacks
# the WAV-recording player. Current baresip (3.x) has both.
ARG BARESIP_VERSION=v3.15.0

FROM debian:bookworm-slim AS build
ARG BARESIP_VERSION
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates pkg-config \
      libssl-dev libopus-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# libre and baresip release in lockstep with matching version tags.
RUN git clone --depth 1 --branch "$BARESIP_VERSION" https://github.com/baresip/re.git \
 && git clone --depth 1 --branch "$BARESIP_VERSION" https://github.com/baresip/baresip.git
# The same in-place source patches the app's build applies (build context is
# the repo root for this): the receive-path packet-loss concealment is what
# the audio-quality gates measure, so the harness phone must carry it too.
COPY ios/vendor/patches/apply-baresip.sh ios/vendor/patches/apply-re.sh /src/
# Lab (lab/audio-continuity): the playout engine the patches wire in.
COPY ios/vendor/patches/playout/playout.c ios/vendor/patches/playout/playout.h /src/baresip/src/
RUN sh /src/apply-baresip.sh /src/baresip && sh /src/apply-re.sh /src/re
# The app's codec modules too: g722 built from WebRTC's public-domain G.722
# (no spandsp) and g711, both with the packet-loss concealment the
# audio-quality gates measure (ios/vendor/patches/{g711,g722,plc}).
COPY ios/vendor/patches/g711 /src/patches/g711
COPY ios/vendor/patches/g722 /src/patches/g722
COPY ios/vendor/patches/plc /src/patches/plc
RUN cp /src/patches/g722/CMakeLists.txt /src/patches/g722/g722.c /src/baresip/modules/g722/ \
 && rm -rf /src/baresip/modules/g722/webrtc && cp -R /src/patches/g722/webrtc /src/baresip/modules/g722/webrtc \
 && cp /src/patches/g711/CMakeLists.txt /src/patches/g711/g711.c /src/baresip/modules/g711/ \
 && for m in g711 g722; do mkdir -p /src/baresip/modules/$m/plc && cp /src/patches/plc/plc.c /src/patches/plc/plc.h /src/baresip/modules/$m/plc/; done
RUN cmake -S re -B re/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build re/build -j"$(nproc)" \
 && cmake --install re/build
RUN cmake -S baresip -B baresip/build -DCMAKE_BUILD_TYPE=Release \
      -DSTATIC=OFF -DMODULES="account;contact;menu;ctrl_tcp;aufile;ausine;opus;g722;g711;ice;srtp;stdio;auconv;auresamp" \
 && cmake --build baresip/build -j"$(nproc)" \
 && cmake --install baresip/build

FROM debian:bookworm-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libssl3 libopus0 zlib1g ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && ldconfig
COPY --from=build /usr/local/ /usr/local/
RUN ldconfig
COPY harness/baresip/config harness/baresip/accounts harness/baresip/entrypoint.sh /opt/baresip/
RUN chmod +x /opt/baresip/entrypoint.sh
VOLUME ["/media"]
ENTRYPOINT ["/opt/baresip/entrypoint.sh"]
