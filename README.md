# kulisa-ffmpeg

A minimal LGPL build of FFmpeg for Windows x64, made for the transcode stage of the Kulisa restream
feature. It is built by cross compilation in Docker (Ubuntu 24.04 with mingw-w64) and released as a
zip of shared libraries plus the matching source archive.

Source code of the build: https://github.com/PhoenixllGames/kulisa-ffmpeg

## What it does

Kulisa starts `ffmpeg.exe` as a child process. Kulisa writes FLV to its standard input and reads FLV
from its standard output; the relay in Kulisa owns the network, so FFmpeg is built without network
support and without TLS, and stream keys never appear on its command line.

Typical use:

```
ffmpeg -f flv -i pipe:0 -vf scale=-2:720,fps=30 -c:v h264_mf -rate_control cbr -b:v 3000k -maxrate 3000k -bufsize 6000k -g 60 -bf 0 -c:a copy -progress pipe:2 -f flv pipe:1
```

## License

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or later. This build uses
none of `--enable-gpl`, `--enable-nonfree` and `--enable-version3`, and the libraries are shared
(DLLs), as required by https://ffmpeg.org/legal.html. The text is in `LICENSE.txt` inside the zip.

The build scripts in this repository are under the MIT license (`LICENSE`).

Third party inputs, all MIT:

- nv-codec-headers 13.1.15.0 (headers only; the NVIDIA runtime is loaded from the driver)
- AMD AMF headers 1.5.3 (headers only; the AMF runtime is loaded from the driver)
- Intel libvpl 2.17.0 (static dispatcher linked into the FFmpeg libraries; the Intel runtime is
  loaded from the driver)

The mingw-w64 C runtime, libgcc and libstdc++ are linked statically. The license texts of the third
party inputs are in `licenses/` inside the zip.

## Versions

| Component | Version |
|---|---|
| FFmpeg | 9.0.2 (release tarball, GPG verified, SHA-256 pinned) |
| nv-codec-headers | 13.1.15.0 |
| AMF headers | 1.5.3 |
| libvpl | 2.17.0 |
| Build image | `ubuntu:24.04`, pinned by digest in `versions.env` |
| Toolchain | mingw-w64 GCC 13 (win32 thread model), binutils-mingw-w64, clang 18 (CUDA kernels), nasm, cmake |

Exact package versions are written to `BUILDINFO.txt` inside the zip.

Release tags are `v<FFmpeg version>-<build number>`. The current build is `v9.0.2-1`. A published tag
is never rebuilt; a change of any input gets the next build number.

## NVENC driver requirement

The NVENC API level of the nv-codec-headers decides the minimum NVIDIA driver. Headers 13.1.15.0
require a Windows driver 610.0 or newer; with an older driver `h264_nvenc` fails to open and reports
that the driver does not support the required nvenc API version. Older header tags accepted by this
FFmpeg version and their minimum Windows drivers: 13.0.19.1 needs 570.0, 12.2.72.0 needs 551.76,
12.1.14.1 needs 531.61. Changing `NV_CODEC_HEADERS_*` in `versions.env` and the build number is the
only change needed.

## Contents of the build

Everything else is disabled (`--disable-autodetect --disable-everything`). The allow list is the file
`components`; a later addition is a one-line change there.

- Programs: `ffmpeg` only.
- Libraries: avutil, avcodec, avformat, avfilter, swscale, swresample, avdevice (lavfi input only).
- Protocols: pipe, file. Demuxers: flv, live_flv. Muxers: flv, null. Input device: lavfi.
- Decoders: h264, aac, h264_qsv, h264_cuvid, wrapped_avframe.
- Encoders: h264_mf, h264_nvenc, h264_amf, h264_qsv, aac, wrapped_avframe.
- Hardware acceleration: Media Foundation, NVENC, NVDEC and CUVID through ffnvcodec, CUDA kernels
  compiled with clang (cuda-llvm), AMF, QSV through libvpl, D3D11VA, DXVA2.
- Hwaccels: h264_d3d11va, h264_d3d11va2, h264_dxva2, h264_nvdec.
- Parsers: h264, aac. Bitstream filters: aac_adtstoasc, h264_mp4toannexb, extract_extradata,
  dump_extradata, null.
- Filters: scale, fps, format, null, anull, aresample, aformat, setpts, asetpts, trim, atrim, copy,
  hwupload, hwdownload, hwmap, hwupload_cuda, scale_cuda, scale_qsv, vpp_qsv, vpp_amf, scale_d3d11,
  color, testsrc2, nullsrc, anullsrc, sine. FFmpeg adds the filters its own command line tool needs
  (crop, hflip, vflip, transpose, rotate).

The binaries import only Windows system DLLs and each other (no libwinpthread, libgcc or libstdc++
DLLs). The check runs at the end of every build and fails the build otherwise.

## Configure line

This is the line `ffmpeg -buildconf` reports (the build number does not change it):

```
./configure \
  --prefix=/opt/kulisa-ffmpeg --arch=x86_64 --target-os=mingw32 --cross-prefix=x86_64-w64-mingw32- \
  --pkg-config=pkg-config --pkg-config-flags=--static --x86asmexe=nasm \
  --enable-shared --disable-static --disable-autodetect --disable-everything \
  --disable-debug --disable-doc --disable-network --disable-programs \
  --extra-ldflags=-static-libgcc --extra-ldflags=-static-libstdc++ \
  --extra-ldflags='-Wl,--no-insert-timestamp' --extra-libs=-lstdc++ \
  --enable-ffmpeg \
  --enable-protocol='pipe,file' --enable-demuxer='flv,live_flv' --enable-muxer='flv,null' \
  --enable-indev=lavfi \
  --enable-decoder='h264,aac,h264_qsv,h264_cuvid,wrapped_avframe' \
  --enable-encoder='h264_mf,h264_nvenc,h264_amf,h264_qsv,aac,wrapped_avframe' \
  --enable-hwaccel='h264_d3d11va,h264_d3d11va2,h264_dxva2,h264_nvdec' \
  --enable-parser='h264,aac' \
  --enable-bsf='aac_adtstoasc,h264_mp4toannexb,extract_extradata,dump_extradata,null' \
  --enable-filter='scale,fps,format,null,anull,aresample,aformat,setpts,asetpts,trim,atrim,copy,hwupload,hwdownload,hwmap,hwupload_cuda,scale_cuda,scale_qsv,vpp_qsv,vpp_amf,scale_d3d11,color,testsrc2,nullsrc,anullsrc,sine' \
  --enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuvid --enable-cuda-llvm \
  --enable-amf --enable-libvpl --enable-mediafoundation --enable-d3d11va --enable-dxva2 \
  --enable-w32threads
```

The line is assembled by `scripts/build-ffmpeg.sh` from `components`.

## Release assets

| Asset | Content |
|---|---|
| `kulisa-ffmpeg-<tag>-win64.zip` | `bin/ffmpeg.exe` and the FFmpeg DLLs, `LICENSE.txt` (FFmpeg COPYING.LGPLv2.1), `BUILDINFO.txt`, `licenses/` |
| `kulisa-ffmpeg-<tag>-src.tar.xz` | the scripts of this repository plus every source tarball the build used, unmodified (FFmpeg and its signature, nv-codec-headers, AMF headers, libvpl) |
| `SHA256SUMS` | SHA-256 of the two files above |

Both archives are deterministic: sorted entries and the fixed timestamp `SOURCE_DATE_EPOCH` from
`versions.env`.

## Rebuild

Needs Docker and network access. The sources are downloaded inside the build and verified against
the SHA-256 values in `versions.env`; the FFmpeg tarball is also verified against its GPG signature
and the pinned release key fingerprint.

```
./build.sh
```

The assets are written to `dist/`. Files are copied out of the container with `docker create` and
`docker cp`, so they are owned by the calling user.

| File | Role |
|---|---|
| `versions.env` | pinned versions, URLs, SHA-256 values, base image digest, `BUILD_NUMBER` |
| `components` | the allow list of FFmpeg components and external libraries |
| `Dockerfile` | toolchain, build and package stages |
| `scripts/fetch.sh` | download and verification of the sources |
| `scripts/build-deps.sh` | nv-codec-headers, AMF headers and static libvpl |
| `scripts/build-ffmpeg.sh` | configure, make, install |
| `scripts/package.sh` | import check, `BUILDINFO.txt`, licenses, zip and source archive |
| `verify.ps1` | checks of a built zip on Windows |

## Verify a build on Windows

`verify.ps1` extracts the zip into an empty directory and checks the license text, the configure line
(no gpl, nonfree or version3, and `BUILDINFO.txt` equal to `-buildconf`), the encoders, hwaccels and
filters, an FLV transcode through standard input and output with `h264_mf`, and a one-frame probe of
each GPU encoder. A separate ffmpeg and ffprobe, used only to create the test input and inspect the
output, is passed with `-GplBin`; it is not part of this build.

```
pwsh ./verify.ps1 -Zip dist/kulisa-ffmpeg-v9.0.2-1-win64.zip -Dest D:\tools\kulisa-ffmpeg-v9.0.2-1 -GplBin <dir with ffmpeg.exe and ffprobe.exe>
```
