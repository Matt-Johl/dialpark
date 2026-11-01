#!/bin/sh
# Cross-compiles the SIP/media stack for iOS and packages it as XCFrameworks
# (SPEC §3: baresip / libre, Opus, OpenSSL — all permissive licences).
#
#   sh ios/vendor/build-baresip.sh            # everything: fetch, all libs, both platforms, xcframeworks
#   sh ios/vendor/build-baresip.sh openssl device
#   sh ios/vendor/build-baresip.sh xcframeworks
#
# Stages: fetch | openssl | opus | re | baresip | xcframeworks | all
# Platforms: device (arm64 iphoneos) | simulator (arm64 iphonesimulator) |
#            macos (arm64, for the headless engine probe) | both | all
#
# Outputs: ios/vendor/xcframeworks/{re,baresip,opus,ssl,crypto}.xcframework
# Everything under ios/vendor/{src,build,prefix} is scratch (gitignored).
set -eu
cd "$(dirname "$0")"
ROOT="$(pwd)"

RE_VERSION="${RE_VERSION:-v3.15.0}"          # libre + baresip release in lockstep
BARESIP_VERSION="${BARESIP_VERSION:-v3.15.0}"
OPUS_VERSION="${OPUS_VERSION:-v1.5.2}"
OPENSSL_VERSION="${OPENSSL_VERSION:-openssl-3.3.2}"
IOS_MIN="${IOS_MIN:-17.0}"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"

# Modules linked statically into libbaresip. audiounit = iOS CoreAudio.
BARESIP_MODULES="${BARESIP_MODULES:-account;audiounit;aufile;opus;g722;g711;ice;srtp;auconv;auresamp}"

STAGE="${1:-all}"
PLATFORMS="${2:-both}"
[ "$PLATFORMS" = both ] && PLATFORMS="device simulator"
[ "$PLATFORMS" = all ] && PLATFORMS="device simulator macos"

SRC="$ROOT/src"; BUILD="$ROOT/build"; PREFIX="$ROOT/prefix"; OUT="$ROOT/xcframeworks"
mkdir -p "$SRC" "$BUILD" "$PREFIX" "$OUT"

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

# ---- platform facts ---------------------------------------------------------
MACOS_MIN="${MACOS_MIN:-14.0}"
sdk_for()      { case "$1" in device) echo iphoneos ;; simulator) echo iphonesimulator ;; macos) echo macosx ;; esac; }
sysroot_for()  { xcrun --sdk "$(sdk_for "$1")" --show-sdk-path; }
minflag_for()  { case "$1" in device) echo "-mios-version-min=$IOS_MIN" ;; simulator) echo "-mios-simulator-version-min=$IOS_MIN" ;; macos) echo "-mmacosx-version-min=$MACOS_MIN" ;; esac; }
prefix_for()   { echo "$PREFIX/$1"; }

cmake_ios_flags() {
  p="$1"
  if [ "$p" = macos ]; then
    sys="-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN"
  else
    sys="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN"
  fi
  echo "$sys -DCMAKE_OSX_SYSROOT=$(sdk_for "$p") -DCMAKE_OSX_ARCHITECTURES=arm64 \
       -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_INSTALL_PREFIX=$(prefix_for "$p") -DCMAKE_PREFIX_PATH=$(prefix_for "$p") \
       -DCMAKE_FIND_ROOT_PATH=$(prefix_for "$p") -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
       -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
       -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_MACOSX_BUNDLE=OFF"
}

# ---- fetch -------------------------------------------------------------------
fetch() {
  log "fetch sources (release tarballs; no .git directories needed)"
  tarball() { # name url
    [ -d "$SRC/$1" ] && return 0
    tmp="$SRC/$1.tar.gz"
    curl -sSL --fail -o "$tmp" "$2"
    mkdir -p "$SRC/$1"
    # .git* entries are excluded: not needed, and some sandboxes refuse to create them.
    tar -xzf "$tmp" -C "$SRC/$1" --strip-components=1 --exclude='.git*'
    rm -f "$tmp"
    echo "   $1 ← $2"
  }
  tarball openssl "https://github.com/openssl/openssl/releases/download/$OPENSSL_VERSION/$OPENSSL_VERSION.tar.gz"
  tarball opus    "https://github.com/xiph/opus/archive/refs/tags/$OPUS_VERSION.tar.gz"
  tarball re      "https://github.com/baresip/re/archive/refs/tags/$RE_VERSION.tar.gz"
  tarball baresip "https://github.com/baresip/baresip/archive/refs/tags/$BARESIP_VERSION.tar.gz"
  apply_patches
}

# ---- patches -----------------------------------------------------------------
# ios/vendor/patches/<module>/* are full-file replacements laid over the
# extracted sources (see patches/README.md). Idempotent.
apply_patches() {
  [ -d "$ROOT/patches/audiounit" ] || return 0
  log "patches: audiounit (manual audio for CallKit), g722 (no spandsp), g711+g722 PLC, aureceiver PLC"
  cp "$ROOT/patches/audiounit/"*.c "$ROOT/patches/audiounit/"*.h "$SRC/baresip/modules/audiounit/"
  # g722: upstream's module needs spandsp (LGPL) and is silently skipped
  # without it; ours compiles WebRTC's public-domain G.722 into the module.
  cp "$ROOT/patches/g722/CMakeLists.txt" "$ROOT/patches/g722/g722.c" "$SRC/baresip/modules/g722/"
  rm -rf "$SRC/baresip/modules/g722/webrtc"
  cp -R "$ROOT/patches/g722/webrtc" "$SRC/baresip/modules/g722/webrtc"
  # g711: upstream's module plus packet-loss concealment; plc/ is the
  # concealment unit both sample-domain codecs compile in.
  cp "$ROOT/patches/g711/CMakeLists.txt" "$ROOT/patches/g711/g711.c" "$SRC/baresip/modules/g711/"
  for m in g711 g722; do
    rm -rf "$SRC/baresip/modules/$m/plc"
    mkdir -p "$SRC/baresip/modules/$m/plc"
    cp "$ROOT/patches/plc/plc.c" "$ROOT/patches/plc/plc.h" "$SRC/baresip/modules/$m/plc/"
  done
  # Lab: the playout engine (ios/vendor/patches/playout) joins baresip's sources
  cp "$ROOT/patches/playout/playout.c" "$ROOT/patches/playout/playout.h" "$SRC/baresip/src/"
  sh "$ROOT/patches/apply-baresip.sh" "$SRC/baresip"
  sh "$ROOT/patches/apply-re.sh" "$SRC/re"
}

# ---- openssl -----------------------------------------------------------------
build_openssl() {
  p="$1"; log "openssl ($p)"
  b="$BUILD/openssl-$p"; rm -rf "$b"; mkdir -p "$b"
  case "$p" in
    device)    tgt=ios64-xcrun ;;
    simulator) tgt=iossimulator-arm64-xcrun ;;
    macos)     tgt=darwin64-arm64-cc ;;
  esac
  ( cd "$b" && "$SRC/openssl/Configure" "$tgt" no-shared no-tests no-dso no-engine no-legacy no-apps \
        --prefix="$(prefix_for "$p")" --libdir=lib "$(minflag_for "$p")" >/dev/null \
    && make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null )
  ls "$(prefix_for "$p")/lib/libssl.a" "$(prefix_for "$p")/lib/libcrypto.a" >/dev/null
}

# ---- opus --------------------------------------------------------------------
build_opus() {
  p="$1"; log "opus ($p)"
  b="$BUILD/opus-$p"; rm -rf "$b"
  # shellcheck disable=SC2046
  cmake -S "$SRC/opus" -B "$b" $(cmake_ios_flags "$p") -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=ON >/dev/null
  cmake --build "$b" -j"$JOBS" >/dev/null && cmake --install "$b" >/dev/null
  ls "$(prefix_for "$p")/lib/libopus.a" >/dev/null
}

# ---- libre -------------------------------------------------------------------
build_re() {
  p="$1"; log "libre ($p)"
  b="$BUILD/re-$p"; rm -rf "$b"
  # shellcheck disable=SC2046
  cmake -S "$SRC/re" -B "$b" $(cmake_ios_flags "$p") -DOPENSSL_ROOT_DIR="$(prefix_for "$p")" \
        -DUSE_OPENSSL=ON -DLIBRE_BUILD_SHARED=OFF -DLIBRE_BUILD_STATIC=ON >/dev/null
  cmake --build "$b" -j"$JOBS" >/dev/null && cmake --install "$b" >/dev/null
  ls "$(prefix_for "$p")/lib/libre.a" >/dev/null
}

# ---- baresip -----------------------------------------------------------------
build_baresip() {
  p="$1"; log "baresip ($p) modules=$BARESIP_MODULES"
  apply_patches
  b="$BUILD/baresip-$p"; rm -rf "$b"
  # shellcheck disable=SC2046
  cmake -S "$SRC/baresip" -B "$b" $(cmake_ios_flags "$p") -DSTATIC=ON -DMODULES="$BARESIP_MODULES" \
        -DOPENSSL_ROOT_DIR="$(prefix_for "$p")" -Dre_DIR="$(prefix_for "$p")/lib/cmake/re" >/dev/null
  cmake --build "$b" -j"$JOBS" --target baresip >/dev/null 2>&1 || cmake --build "$b" -j"$JOBS" >/dev/null
  cmake --install "$b" >/dev/null 2>&1 || true
  # Some versions install only the binary; copy the static lib + headers ourselves.
  mkdir -p "$(prefix_for "$p")/include/baresip"
  cp "$SRC/baresip/include/baresip.h" "$(prefix_for "$p")/include/baresip/"
  lib="$(find "$b" -name 'libbaresip.a' | head -n1)"
  [ -n "$lib" ] || { echo "libbaresip.a not produced"; exit 1; }
  cp "$lib" "$(prefix_for "$p")/lib/libbaresip.a"
}

# ---- xcframeworks ------------------------------------------------------------
# No Clang module maps in the XCFrameworks: Xcode copies every binary
# target's headers into one shared products/include directory, so two
# module.modulemap files would collide ("Multiple commands produce"), and
# baresip.h is not self-contained anyway (it needs re.h first). Only the
# CBaresip C shim consumes these headers, textually, in the right order.
modulemap() { # dir module header
  rm -f "$1/module.modulemap"
}

xcframeworks() {
  log "xcframeworks"
  rm -rf "$OUT"; mkdir -p "$OUT"
  mk() { # name libfile headers-subdir umbrella [dest-subdir]   ("-" headers-subdir = no headers)
    name="$1"; libf="$2"; hdr="$3"; umb="$4"; sub="${5:-}"
    args=""
    slices="device simulator"
    [ -f "$(prefix_for macos)/lib/$libf" ] && slices="$slices macos"
    for p in $slices; do
      if [ "$hdr" = "-" ]; then
        args="$args -library $(prefix_for "$p")/lib/$libf"
        continue
      fi
      hd="$BUILD/headers-$name-$p"; rm -rf "$hd"; mkdir -p "$hd/$sub"
      cp -R "$(prefix_for "$p")/include/$hdr/." "$hd/$sub/"
      modulemap "$hd" "$name" "$umb"
      args="$args -library $(prefix_for "$p")/lib/$libf -headers $hd"
    done
    # shellcheck disable=SC2086
    xcodebuild -create-xcframework $args -output "$OUT/$name.xcframework" >/dev/null
    echo "   $OUT/$name.xcframework"
  }
  mk re      libre.a      re       re.h
  mk baresip libbaresip.a baresip  baresip.h
  mk opus    libopus.a    opus     opus.h
  mk ssl     libssl.a     openssl  ssl.h    openssl   # headers as <openssl/*.h>, no Clang module
  # Xcode copies every binary target's headers into one shared products
  # directory; a second copy of the OpenSSL headers here would collide
  # ("Multiple commands produce include/x509.h"). libcrypto ships bare.
  mk crypto  libcrypto.a  -        -
}

# ---- dispatch ----------------------------------------------------------------
case "$STAGE" in
  fetch)        fetch ;;
  openssl)      fetch; for p in $PLATFORMS; do build_openssl "$p"; done ;;
  opus)         fetch; for p in $PLATFORMS; do build_opus "$p"; done ;;
  re)           fetch; for p in $PLATFORMS; do build_re "$p"; done ;;
  baresip)      fetch; for p in $PLATFORMS; do build_baresip "$p"; done ;;
  xcframeworks) xcframeworks ;;
  all)
    fetch
    for p in $PLATFORMS; do build_openssl "$p"; build_opus "$p"; build_re "$p"; build_baresip "$p"; done
    xcframeworks ;;
  *) echo "unknown stage $STAGE"; exit 2 ;;
esac
log "done: $STAGE ($PLATFORMS)"
