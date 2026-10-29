#!/usr/bin/env bash
# Configures, builds and installs FFmpeg into /work/stage (DESTDIR). The configure line is built
# from the allow list in /work/components; no GPL, nonfree or version3 option is ever passed.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$PWD"
. ./versions.env
. ./components

# ld and strip stamp the PE headers with this time (SOURCE_DATE_EPOCH) instead of the build time.
export SOURCE_DATE_EPOCH
SYSROOT=/usr/x86_64-w64-mingw32
PREFIX=/opt/kulisa-ffmpeg
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"

mkdir -p logs stage
rm -rf build/ffmpeg stage/*
mkdir -p build/ffmpeg
tar -xJf "sources/$FFMPEG_FILE" -C build/ffmpeg --strip-components=1
cd build/ffmpeg

# Components this FFmpeg version does not know are skipped and reported.
: > "$WORK/logs/skipped-components.txt"
declare -A known_cache
known() { # kind-plural name
  if [ -z "${known_cache[$1]+x}" ]; then
    known_cache[$1]="$(./configure "--list-$1" | tr -s ' \t' '\n\n')"
  fi
  # A here-string keeps grep -q from closing a pipe early under pipefail.
  grep -qx -- "$2" <<<"${known_cache[$1]}"
}
select_known() { # kind-plural names...
  local kind="$1" out=() n
  shift
  for n in "$@"; do
    if known "$kind" "$n"; then
      out+=("$n")
    else
      echo "WARNING: $kind '$n' does not exist in FFmpeg $FFMPEG_VERSION, skipped" | tee -a "$WORK/logs/skipped-components.txt" >&2
    fi
  done
  (IFS=,; echo "${out[*]}")
}

help_text="$(./configure --help)"

args=(
  "--prefix=$PREFIX"
  --arch=x86_64
  --target-os=mingw32
  --cross-prefix=x86_64-w64-mingw32-
  --pkg-config=pkg-config
  --pkg-config-flags=--static
  --x86asmexe=nasm
  --enable-shared
  --disable-static
  --disable-autodetect
  --disable-everything
  --disable-debug
  --disable-doc
  --disable-network
  --disable-programs
  --extra-ldflags=-static-libgcc
  --extra-ldflags=-static-libstdc++
  --extra-ldflags=-Wl,--no-insert-timestamp
  --extra-libs=-lstdc++
)

for p in $PROGRAMS; do args+=("--enable-$p"); done

# Libraries: keep the listed ones, disable the rest that this version has.
for lib in avutil avcodec avformat avfilter swscale swresample avdevice postproc; do
  case " $LIBRARIES " in
    *" $lib "*) ;;
    *) if grep -q -- "--disable-$lib " <<<"$help_text"; then args+=("--disable-$lib"); fi ;;
  esac
done

list="$(select_known protocols $PROTOCOLS)";  [ -n "$list" ] && args+=("--enable-protocol=$list")
list="$(select_known demuxers $DEMUXERS)";    [ -n "$list" ] && args+=("--enable-demuxer=$list")
list="$(select_known muxers $MUXERS)";        [ -n "$list" ] && args+=("--enable-muxer=$list")
list="$(select_known indevs $INDEVS)";        [ -n "$list" ] && args+=("--enable-indev=$list")
list="$(select_known decoders $DECODERS)";    [ -n "$list" ] && args+=("--enable-decoder=$list")
list="$(select_known encoders $ENCODERS)";    [ -n "$list" ] && args+=("--enable-encoder=$list")
list="$(select_known hwaccels $HWACCELS)";    [ -n "$list" ] && args+=("--enable-hwaccel=$list")
list="$(select_known parsers $PARSERS)";      [ -n "$list" ] && args+=("--enable-parser=$list")
list="$(select_known bsfs $BSFS)";            [ -n "$list" ] && args+=("--enable-bsf=$list")
list="$(select_known filters $FILTERS)";      [ -n "$list" ] && args+=("--enable-filter=$list")

for e in $EXTERNAL; do args+=("--enable-$e"); done
for d in $DISABLE; do args+=("--disable-$d"); done

# Hard stop on any licence switch that would change the LGPL status.
for a in "${args[@]}"; do
  case "$a" in
    --enable-gpl|--enable-nonfree|--enable-version3|--enable-gplv3)
      echo "forbidden licence option: $a" >&2
      exit 1
      ;;
  esac
done

echo "configure ${args[*]}" > "$WORK/logs/configure-line.txt"
./configure "${args[@]}" 2>&1 | tee "$WORK/logs/configure-summary.txt"
cp ffbuild/config.log "$WORK/logs/config.log"

make -j"$(nproc)" 2>&1 | tee "$WORK/logs/make.log" | tail -n 30
make install DESTDIR="$WORK/stage" 2>&1 | tee "$WORK/logs/make-install.log" | tail -n 10

# Notices of the non-LGPL code compiled into the binaries, generated from the objects of this build.
# Fails on license-like text that is not reviewed in scripts/notices-allow.txt and on generated
# intermediates whose inputs it cannot resolve (the release tarball tells sources from generated files).
python3 -I "$WORK/scripts/notices.py" . "$WORK/sources/$FFMPEG_FILE" "$WORK/scripts/notices-allow.txt" \
  "$WORK/stage/FFmpeg-third-party-notices.txt" "$WORK/logs/notices-sources.txt" \
  "Third party notices of the FFmpeg $FFMPEG_VERSION code in Kulisa FFmpeg ${ASSET_TAG:-v$FFMPEG_VERSION-$BUILD_NUMBER}"
cp LICENSE.md "$WORK/stage/FFmpeg-LICENSE.md"

# Text of the configure line exactly as the binary reports it, and the licence file.
sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h > "$WORK/stage/configuration.txt"
cp COPYING.LGPLv2.1 "$WORK/stage/COPYING.LGPLv2.1"
grep -n "^#define FFMPEG_LICENSE" config.h | tee "$WORK/logs/license-define.txt"

cd "$WORK"
rm -rf build/ffmpeg
echo "staged: $(find stage -type f | wc -l) files"
