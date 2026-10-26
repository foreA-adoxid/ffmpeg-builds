#!/usr/bin/env bash
set -euo pipefail

: "${FFMPEG_VERSION:?Set FFMPEG_VERSION to a stable source release}"
: "${BUILD_TARGET:?Set BUILD_TARGET to windows, macos or linux}"
: "${BUILD_ARCH:?Set BUILD_ARCH to x86_64 or arm64}"
[[ "$FFMPEG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'Expected a stable release version such as 9.0.2' >&2
  exit 1
}
case "$BUILD_TARGET/$BUILD_ARCH/$(uname -s)/$(uname -m)" in
  linux/x86_64/Linux/x86_64|macos/x86_64/Darwin/x86_64|macos/arm64/Darwin/arm64|windows/x86_64/MINGW64_NT-*/x86_64|windows/x86_64/UCRT64_NT-*/x86_64) ;;
  *) echo 'Unsupported target or runner architecture' >&2; exit 1 ;;
esac

ROOT="$(pwd)"
BUILD="$ROOT/.build/$BUILD_TARGET-$BUILD_ARCH-$FFMPEG_VERSION"
PREFIX="$BUILD/prefix"
DOWNLOAD_CACHE="$ROOT/.build/downloads"
JOBS="${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
LAME_VERSION=3.100
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
FFMPEG_SIGNER=FCF986EA15E6E293A5644F10B4322F04D67658D8
mkdir -p "$BUILD/downloads" "$DOWNLOAD_CACHE" "$PREFIX" "$ROOT/dist/bin" "$ROOT/out"
if [[ "$BUILD_TARGET" == macos ]]; then
  export MACOSX_DEPLOYMENT_TARGET=10.15
  [[ "$BUILD_ARCH" != arm64 ]] || export MACOSX_DEPLOYMENT_TARGET=11.0
fi

# ccache hashes the real compiler and headers, even after a runner toolchain update.
export CCACHE_DIR="$ROOT/.build/ccache"
export CCACHE_BASEDIR="$ROOT"
export CCACHE_COMPILERCHECK=content
export CCACHE_NAMESPACE="$BUILD_TARGET-$BUILD_ARCH-${MSYSTEM:-native}"
export CCACHE_MAXSIZE=1G
export CCACHE_UMASK=0022
export CC="ccache ${CC:-cc}"
ccache --zero-stats
trap 'ccache --show-stats || true' EXIT

download() {
  local cache_name="${3:-}"
  if [[ -n "$cache_name" && -s "$DOWNLOAD_CACHE/$cache_name" ]]; then
    echo "Using cached source: $cache_name"
    cp "$DOWNLOAD_CACHE/$cache_name" "$BUILD/downloads/$2"
    return
  fi
  curl --fail --location --retry 5 --retry-delay 2 --connect-timeout 30 \
    --output "$BUILD/downloads/$2" "$1"
  if [[ -n "$cache_name" ]]; then
    cp "$BUILD/downloads/$2" "$DOWNLOAD_CACHE/$cache_name"
  fi
}
hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
verify_hash() {
  [[ "$(hash "$BUILD/downloads/$1")" == "$2" ]] || {
    echo "Source checksum mismatch: $1" >&2; exit 1
  }
}

download "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" ffmpeg.tar.xz "ffmpeg-$FFMPEG_VERSION.tar.xz"
download "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz.asc" ffmpeg.tar.xz.asc "ffmpeg-$FFMPEG_VERSION.tar.xz.asc"
download https://ffmpeg.org/ffmpeg-devel.asc ffmpeg-devel.asc
mkdir -p "$BUILD/gnupg"
chmod 700 "$BUILD/gnupg"
gpg --batch --homedir "$BUILD/gnupg" --import "$BUILD/downloads/ffmpeg-devel.asc"
gpg --batch --homedir "$BUILD/gnupg" --status-fd 1 \
  --verify "$BUILD/downloads/ffmpeg.tar.xz.asc" "$BUILD/downloads/ffmpeg.tar.xz" \
  > "$BUILD/signature.status"
awk -v signer="$FFMPEG_SIGNER" \
  '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == signer || $NF == signer) { valid=1 } END { exit !valid }' \
  "$BUILD/signature.status"

download "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" lame.tar.gz "lame-$LAME_VERSION.tar.gz"
verify_hash lame.tar.gz "$LAME_SHA256"
mkdir -p "$BUILD/lame" "$BUILD/ffmpeg"
tar -xf "$BUILD/downloads/lame.tar.gz" -C "$BUILD/lame" --strip-components=1
tar -xf "$BUILD/downloads/ffmpeg.tar.xz" -C "$BUILD/ffmpeg" --strip-components=1
# LAME's original 2017 platform detection predates Apple Silicon.
cp "$(automake --print-libdir)/config.guess" "$BUILD/lame/config.guess"
cp "$(automake --print-libdir)/config.sub" "$BUILD/lame/config.sub"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
cd "$BUILD/lame"
./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend --disable-decoder
make -j "$JOBS"
make install

TLS_FLAGS=()
LINK_FLAGS=()
case "$BUILD_TARGET" in
  linux)
    download "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" openssl.tar.gz "openssl-$OPENSSL_VERSION.tar.gz"
    verify_hash openssl.tar.gz "$OPENSSL_SHA256"
    mkdir -p "$BUILD/openssl"
    tar -xf "$BUILD/downloads/openssl.tar.gz" -C "$BUILD/openssl" --strip-components=1
    cd "$BUILD/openssl"
    ./Configure linux-x86_64 no-shared no-tests no-module --prefix="$PREFIX" --libdir=lib
    make -j "$JOBS"
    make install_sw
    TLS_FLAGS=(--enable-openssl)
    LINK_FLAGS=(--extra-ldflags=-static --extra-ldexeflags=-static)
    ;;
  windows)
    TLS_FLAGS=(--enable-schannel)
    LINK_FLAGS=(--extra-ldflags='-static -static-libgcc')
    ;;
  macos)
    TLS_FLAGS=(--enable-securetransport)
    LINK_FLAGS=(--extra-ldflags=-Wl,-search_paths_first)
    ;;
esac

cd "$BUILD/ffmpeg"
./configure --cc="$CC" --prefix="$ROOT/dist" --disable-autodetect --disable-shared --enable-static \
  --disable-debug --disable-doc --disable-ffplay --disable-ffprobe \
  --enable-gpl --enable-version3 --enable-libmp3lame --enable-zlib \
  --pkg-config-flags=--static --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib" "${TLS_FLAGS[@]}" "${LINK_FLAGS[@]}"
make -j "$JOBS"
make install

BIN=ffmpeg
[[ "$BUILD_TARGET" != windows ]] || BIN=ffmpeg.exe
EXECUTABLE="$ROOT/dist/bin/$BIN"
"$EXECUTABLE" -version > "$BUILD/version.txt"
head -n 1 "$BUILD/version.txt"
[[ "$(awk 'NR == 1 {print $3}' "$BUILD/version.txt")" == "$FFMPEG_VERSION" ]]
# Fail before packaging if a required PulseSync capability was disabled.
"$EXECUTABLE" -hide_banner -filters > "$BUILD/filters.txt"
for filter in ebur128 loudnorm aresample; do
  grep -Eq "[[:space:]]$filter[[:space:]]" "$BUILD/filters.txt"
done
"$EXECUTABLE" -hide_banner -encoders > "$BUILD/encoders.txt"
for encoder in libmp3lame aac alac flac; do
  grep -Eq "[[:space:]]$encoder[[:space:]]" "$BUILD/encoders.txt"
done
"$EXECUTABLE" -hide_banner -decoders > "$BUILD/decoders.txt"
for decoder in aac alac flac mp3 opus vorbis png mjpeg; do
  grep -Eq "[[:space:]]$decoder[[:space:]]" "$BUILD/decoders.txt"
done
"$EXECUTABLE" -hide_banner -protocols > "$BUILD/protocols.txt"
grep -Eq '^[[:space:]]+https$' "$BUILD/protocols.txt"
if [[ "$BUILD_TARGET" == macos ]]; then
  otool -L "$EXECUTABLE" > "$BUILD/libraries.txt"
  awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad=1 } END { exit bad }' "$BUILD/libraries.txt"
elif [[ "$BUILD_TARGET" == linux ]]; then
  readelf -l "$EXECUTABLE" > "$BUILD/program-headers.txt"
  readelf -d "$EXECUTABLE" > "$BUILD/dynamic-section.txt"
  if grep -q INTERP "$BUILD/program-headers.txt" || grep -q NEEDED "$BUILD/dynamic-section.txt"; then
    echo 'Linux binary unexpectedly depends on shared libraries' >&2
    exit 1
  fi
fi

cd "$ROOT"
ARTIFACT="ffmpeg-$BUILD_TARGET-$BUILD_ARCH"
# Updater contract: executable at the archive root, hash of the executable.
hash "$EXECUTABLE" > "out/$ARTIFACT.sha256"
tar -C dist/bin -czf "out/$ARTIFACT.tar.gz" "$BIN"
[[ "$(tar -tzf "out/$ARTIFACT.tar.gz")" == "$BIN" ]]

# Retain the exact corresponding sources and configure arguments with each build.
mkdir -p "$BUILD/provenance"
cp "$BUILD/version.txt" "$BUILD/provenance/"
cp "$BUILD/ffmpeg/ffbuild/config.log" "$BUILD/provenance/ffmpeg-config.log"
cp "$BUILD/lame/config.log" "$BUILD/provenance/lame-config.log"
cp "$BUILD/ffmpeg/COPYING.GPLv3" "$BUILD/provenance/"
cp "$BUILD/lame/COPYING" "$BUILD/provenance/LAME-COPYING"
cp "$ROOT/.github/scripts/build-ffmpeg.sh" "$ROOT/.github/workflows/ffmpeg.yml" "$BUILD/provenance/"
cp "$BUILD/lame/config.guess" "$BUILD/lame/config.sub" "$BUILD/provenance/"
for source in ffmpeg.tar.xz lame.tar.gz openssl.tar.gz; do
  if [[ -f "$BUILD/downloads/$source" ]]; then
    printf '%s  %s\n' "$(hash "$BUILD/downloads/$source")" "$source"
  fi
done > "$BUILD/provenance/SHA256SUMS"
tar -czf "out/$ARTIFACT-sources.tar.gz" -C "$BUILD" downloads provenance
echo "Created out/$ARTIFACT.tar.gz and executable SHA-256"
