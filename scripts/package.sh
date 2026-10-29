#!/usr/bin/env bash
# Checks the built binaries and writes the release assets to /out:
#   kulisa-ffmpeg-<tag>-win64.zip, kulisa-ffmpeg-<tag>-src.tar.xz, SHA256SUMS, logs/
set -euo pipefail
WORK=/work
cd "$WORK"
REPO="$WORK/repo"
. "$REPO/versions.env"
. "$REPO/components"

TAG="v${FFMPEG_VERSION}-${BUILD_NUMBER}"
BINDIR="stage/opt/kulisa-ffmpeg/bin"
OBJDUMP=x86_64-w64-mingw32-objdump
OUT=/out
mkdir -p "$OUT/logs"

# ---------------------------------------------------------------------------------------------
# 1. Imports: every binary may import only Windows system DLLs and the bundled DLLs.
# ---------------------------------------------------------------------------------------------
system_dlls=" kernel32.dll user32.dll gdi32.dll advapi32.dll shell32.dll ole32.dll oleaut32.dll
  msvcrt.dll bcrypt.dll mfplat.dll mf.dll mfreadwrite.dll d3d11.dll dxgi.dll d3d9.dll dxva2.dll
  cfgmgr32.dll shlwapi.dll ntdll.dll setupapi.dll winmm.dll "
bundled=" $(cd "$BINDIR" && ls *.dll | tr 'A-Z' 'a-z' | tr '\n' ' ') "
: > "$OUT/logs/imports.txt"
bad=0
for f in "$BINDIR"/*.exe "$BINDIR"/*.dll; do
  name="$(basename "$f")"
  imports="$($OBJDUMP -p "$f" | sed -n 's/^\s*DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)"
  {
    echo "== $name"
    echo "$imports" | sed 's/^/   /'
  } >> "$OUT/logs/imports.txt"
  for d in $imports; do
    case "$system_dlls$bundled" in
      *" $d "*) ;;
      *) echo "NOT ALLOWED import in $name: $d" | tee -a "$OUT/logs/imports.txt"; bad=1 ;;
    esac
  done
done
$OBJDUMP -p "$BINDIR/ffmpeg.exe" | grep -E "DllCharacteristics|Subsystem|MajorOSystemVersion" >> "$OUT/logs/imports.txt" || true
cat "$OUT/logs/imports.txt"
if [ "$bad" -ne 0 ]; then
  echo "import check failed" >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# 2. Package tree.
# ---------------------------------------------------------------------------------------------
PKG="$WORK/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/bin" "$PKG/licenses"
cp "$BINDIR"/*.exe "$BINDIR"/*.dll "$PKG/bin/"
cp stage/COPYING.LGPLv2.1 "$PKG/LICENSE.txt"

# FFmpeg's own LICENSE.md and the notices of the non-LGPL code compiled into the binaries, generated
# from the build tree by scripts/notices.py (see build-ffmpeg.sh).
cp stage/FFmpeg-LICENSE.md "$PKG/licenses/FFmpeg-LICENSE.md"
cp stage/FFmpeg-third-party-notices.txt "$PKG/licenses/FFmpeg-third-party-notices.txt"

# The mingw-w64 runtime (CRT startup code and libmingwex, including gdtoa and mingw_pformat) is linked
# statically into every binary. Its notices are the copyright file of the toolchain package.
MINGW_COPYRIGHT=/usr/share/doc/mingw-w64-x86-64-dev/copyright
{
  echo "mingw-w64 runtime, $(dpkg-query -W -f='${Package} ${Version}' mingw-w64-x86-64-dev), https://www.mingw-w64.org/"
  echo "Linked statically into ffmpeg.exe and the FFmpeg DLLs (CRT startup code and libmingwex,"
  echo "including gdtoa and mingw_pformat). The text below is $MINGW_COPYRIGHT"
  echo "of the Ubuntu toolchain package, unmodified."
  echo
  cat "$MINGW_COPYRIGHT"
} > "$PKG/licenses/mingw-w64-runtime.txt"

# Licence texts of the third party inputs, taken from the unmodified sources.
mkdir -p src-tmp
tar -xzf "sources/$NV_CODEC_HEADERS_FILE" -C src-tmp
tar -xzf "sources/$AMF_FILE" -C src-tmp
tar -xzf "sources/$LIBVPL_FILE" -C src-tmp --wildcards "*/LICENSE"

c_comment() { # leading /* ... */ block of a header, comment markers removed
  awk 'NR==1 && $0 !~ /^\/\*/ {exit} {print} /\*\// {exit}' "$1" \
    | sed -e '/^ *\*\/$/d' -e 's#^/\*\**##' -e 's#^ \* \{0,1\}##' -e 's#^ \*$##' -e 's# *\*/$##'
}
slash_comment() { # leading // block of a header, comment markers removed
  awk '/^\/\// {print; next} {exit}' "$1" | sed -e 's#^// \{0,1\}##' -e 's#^//$##'
}
{
  echo "nv-codec-headers $NV_CODEC_HEADERS_VERSION, https://github.com/FFmpeg/nv-codec-headers"
  echo "MIT licence. Headers only; the NVIDIA runtime libraries are loaded from the GPU driver."
  echo
  echo "Notice of include/ffnvcodec/nvEncodeAPI.h:"
  c_comment "src-tmp/nv-codec-headers-$NV_CODEC_HEADERS_VERSION/include/ffnvcodec/nvEncodeAPI.h"
  echo
  echo "Notice of include/ffnvcodec/dynlink_loader.h:"
  c_comment "src-tmp/nv-codec-headers-$NV_CODEC_HEADERS_VERSION/include/ffnvcodec/dynlink_loader.h"
} > "$PKG/licenses/nv-codec-headers-LICENSE.txt"
{
  echo "AMD Advanced Media Framework (AMF) headers $AMF_VERSION, https://github.com/GPUOpen-LibrariesAndSDKs/AMF"
  echo "MIT licence. Headers only; the AMF runtime is loaded from the GPU driver."
  echo
  echo "Notice of AMF/core/Version.h:"
  slash_comment "src-tmp/amf-headers-v$AMF_VERSION/AMF/core/Version.h"
} > "$PKG/licenses/AMF-LICENSE.txt"
{
  echo "Intel Video Processing Library (libvpl) $LIBVPL_VERSION, https://github.com/intel/libvpl"
  echo "Linked statically into the FFmpeg libraries (dispatcher only)."
  echo
  cat "src-tmp/libvpl-$LIBVPL_VERSION/LICENSE"
} > "$PKG/licenses/libvpl-LICENSE.txt"
rm -rf src-tmp

# ---------------------------------------------------------------------------------------------
# 3. BUILDINFO.txt
# ---------------------------------------------------------------------------------------------
pkgver() { dpkg-query -W -f='${Package} ${Version}\n' "$1" 2>/dev/null || echo "$1 (not installed)"; }
conf="$(cat stage/configuration.txt)"
{
  echo "Kulisa FFmpeg $TAG (Windows x64)"
  echo
  echo "FFmpeg version: $FFMPEG_VERSION"
  echo "FFmpeg source:  $FFMPEG_FILE, SHA-256 $FFMPEG_SHA256 (GPG verified, key $FFMPEG_KEY_FPR)"
  echo "License:        GNU LGPL version 2.1 or later. Built without --enable-gpl, --enable-nonfree"
  echo "                and --enable-version3. Shared libraries (DLLs), see LICENSE.txt."
  echo "Source code:    https://github.com/PhoenixllGames/kulisa-ffmpeg (the release asset"
  echo "                kulisa-ffmpeg-$TAG-src.tar.xz holds the build scripts and every source tarball"
  echo "                used, unmodified)."
  echo
  # Same splitting as print_buildconf() in fftools/opt_common.c, so this block is what
  # "ffmpeg -buildconf" prints (INDENT: title at 2 spaces, options at 4).
  echo "  configuration:"
  printf '%s' "$conf" | sed -e 's/ --/~--/g' -e 's/pkg-config~/pkg-config /g' | tr '~' '\n' | sed -e 's/^/    /'
  echo
  echo
  echo "Third party inputs:"
  echo "  nv-codec-headers $NV_CODEC_HEADERS_VERSION (MIT, headers only), SHA-256 $NV_CODEC_HEADERS_SHA256"
  echo "  AMF headers $AMF_VERSION (MIT, headers only), SHA-256 $AMF_SHA256"
  echo "  libvpl $LIBVPL_VERSION (MIT, static dispatcher), SHA-256 $LIBVPL_SHA256"
  echo "  CUDA, AMF and VPL runtimes are loaded from the GPU driver at run time."
  echo
  echo "Notices in licenses/:"
  echo "  FFmpeg-LICENSE.md                 FFmpeg LICENSE.md"
  echo "  FFmpeg-third-party-notices.txt    non-LGPL code compiled into the binaries: $(sed -n 's/^Licenses: //p' "$PKG/licenses/FFmpeg-third-party-notices.txt")"
  echo "  mingw-w64-runtime.txt             statically linked mingw-w64 runtime (ZPL-2.1, Lucent gdtoa and others)"
  echo "  nv-codec-headers-LICENSE.txt      nv-codec-headers (MIT)"
  echo "  AMF-LICENSE.txt                   AMF headers (MIT)"
  echo "  libvpl-LICENSE.txt                libvpl (MIT)"
  echo
  echo "Toolchain (Docker image $UBUNTU_IMAGE):"
  echo "  $(x86_64-w64-mingw32-gcc --version | head -n 1)"
  echo "  $(x86_64-w64-mingw32-g++ --version | head -n 1)"
  echo "  $(x86_64-w64-mingw32-ld --version | head -n 1)"
  echo "  $(clang --version | head -n 1) (CUDA kernels for scale_cuda, NVPTX target)"
  echo "  $(nasm --version)"
  echo "  $(cmake --version | head -n 1)"
  echo "  pkg-config $(pkg-config --version)"
  for p in gcc-mingw-w64-x86-64-win32 g++-mingw-w64-x86-64-win32 binutils-mingw-w64-x86-64 \
           mingw-w64-x86-64-dev clang-18 nasm cmake ninja-build; do
    echo "  deb: $(pkgver "$p")"
  done
  echo "  The mingw-w64 C runtime, libgcc and libstdc++ are linked statically (GCC Runtime Library"
  echo "  Exception applies to libgcc and libstdc++)."
  echo
  if [ -s logs/skipped-components.txt ]; then
    echo "Components requested but unknown to this FFmpeg version:"
    sed 's/^/  /' logs/skipped-components.txt
  else
    echo "Every component of the allow list exists in this FFmpeg version."
  fi
  echo
  echo "Build timestamp for the archives: SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
} > "$PKG/BUILDINFO.txt"

# ---------------------------------------------------------------------------------------------
# 4. Assets
# ---------------------------------------------------------------------------------------------
ZIP="kulisa-ffmpeg-$TAG-win64.zip"
SRC="kulisa-ffmpeg-$TAG-src.tar.xz"
python3 -I "$REPO/scripts/make-zip.py" "$OUT/$ZIP" "$PKG" "$SOURCE_DATE_EPOCH"

SRCDIR="$WORK/srcpkg/kulisa-ffmpeg-$TAG-src"
rm -rf "$WORK/srcpkg"
mkdir -p "$SRCDIR"
cp -a "$REPO/." "$SRCDIR/"
rm -rf "$SRCDIR/.git" "$SRCDIR/dist"
mkdir -p "$SRCDIR/sources"
cp "sources/$FFMPEG_FILE" "sources/$FFMPEG_SIG_FILE" "sources/$FFMPEG_KEY_FILE" \
   "sources/$NV_CODEC_HEADERS_FILE" "sources/$AMF_FILE" "sources/$LIBVPL_FILE" "$SRCDIR/sources/"
tar -C "$WORK/srcpkg" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
    --mode='u=rwX,go=rX' -cf - "kulisa-ffmpeg-$TAG-src" | xz -9e -T1 > "$OUT/$SRC"

(cd "$OUT" && sha256sum "$ZIP" "$SRC" > SHA256SUMS && cat SHA256SUMS)

# ---------------------------------------------------------------------------------------------
# 5. Logs next to the assets (not release assets).
# ---------------------------------------------------------------------------------------------
cp logs/configure-summary.txt logs/configure-line.txt logs/skipped-components.txt logs/license-define.txt \
   logs/config.log logs/notices-sources.txt "$OUT/logs/"
cp stage/configuration.txt "$OUT/logs/configuration.txt"
cp "$PKG/BUILDINFO.txt" "$OUT/logs/BUILDINFO.txt"
(cd "$PKG" && find . -type f | sort | xargs ls -l) > "$OUT/logs/package-files.txt"
echo "package done: $TAG"
