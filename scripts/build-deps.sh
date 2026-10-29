#!/usr/bin/env bash
# Installs the third party build inputs into the mingw-w64 sysroot, so the FFmpeg configure line
# needs no extra include or library paths:
#   nv-codec-headers  headers and ffnvcodec.pc (MIT)
#   AMF               headers only (MIT)
#   libvpl            static Intel dispatcher (MIT)
# The libvpl source tree and the list of files its objects read are kept for scripts/notices.py.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$PWD"
. ./versions.env
SYSROOT=/usr/x86_64-w64-mingw32

mkdir -p build logs
rm -rf build/deps
mkdir -p build/deps
cd build/deps

# nv-codec-headers
tar -xzf "$WORK/sources/$NV_CODEC_HEADERS_FILE"
make -C "nv-codec-headers-$NV_CODEC_HEADERS_VERSION" PREFIX="$SYSROOT" install

# AMF headers
tar -xzf "$WORK/sources/$AMF_FILE"
mkdir -p "$SYSROOT/include"
rm -rf "$SYSROOT/include/AMF"
cp -r "amf-headers-v$AMF_VERSION/AMF" "$SYSROOT/include/AMF"

# libvpl, static
tar -xzf "$WORK/sources/$LIBVPL_FILE"
cmake -S "libvpl-$LIBVPL_VERSION" -B libvpl-build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$WORK/scripts/toolchain-mingw.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$SYSROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_EXPERIMENTAL=OFF \
  -DINSTALL_EXAMPLES=OFF \
  -DINSTALL_DEV=ON \
  -DINSTALL_LIB=ON 2>&1 | tee "$WORK/logs/libvpl-cmake.log"
cmake --build libvpl-build 2>&1 | tee "$WORK/logs/libvpl-build.log"
cmake --install libvpl-build 2>&1 | tee "$WORK/logs/libvpl-install.log"

# Every file the compiler read for the libvpl objects (sources, libvpl headers, libstdc++, GCC and
# mingw-w64 headers). scripts/notices.py classifies them in the FFmpeg step; the libvpl source tree
# stays in build/deps until then (build-ffmpeg.sh removes it).
ninja -C libvpl-build -t deps > "$WORK/logs/libvpl-deps.txt"
test -s "$WORK/logs/libvpl-deps.txt"
rm -rf libvpl-build "nv-codec-headers-$NV_CODEC_HEADERS_VERSION" "amf-headers-v$AMF_VERSION"

cd "$WORK"
echo "--- pkg-config view of the dependencies"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
pkg-config --modversion ffnvcodec vpl
pkg-config --static --libs vpl
