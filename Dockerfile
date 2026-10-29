# syntax=docker/dockerfile:1
# Cross build of the Kulisa FFmpeg (Windows x64) on Ubuntu 24.04 with the mingw-w64 toolchain.
# Run it through ./build.sh. Stages:
#   toolchain  apt packages and the win32 thread model of mingw-w64
#   build      download and verify sources, build the dependencies and FFmpeg
#   package    import check, BUILDINFO, licenses, zip and source archive
#   artifacts  scratch image holding only /out, for docker create and docker cp
ARG UBUNTU_IMAGE

FROM ${UBUNTU_IMAGE} AS toolchain
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg xz-utils python3 file \
      build-essential make nasm pkg-config cmake ninja-build \
      binutils-mingw-w64-x86-64 gcc-mingw-w64-x86-64-win32 g++-mingw-w64-x86-64-win32 \
      mingw-w64-x86-64-dev mingw-w64-common \
      clang llvm \
 && update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-win32 \
 && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-win32 \
 && rm -rf /var/lib/apt/lists/*

FROM toolchain AS build
WORKDIR /work
COPY versions.env components /work/
COPY scripts/fetch.sh scripts/build-deps.sh scripts/build-ffmpeg.sh scripts/toolchain-mingw.cmake /work/scripts/
RUN bash /work/scripts/fetch.sh
RUN bash /work/scripts/build-deps.sh
RUN bash /work/scripts/build-ffmpeg.sh

FROM toolchain AS package
WORKDIR /work
COPY --from=build /work/sources /work/sources
COPY --from=build /work/stage /work/stage
COPY --from=build /work/logs /work/logs
COPY . /work/repo
RUN bash /work/repo/scripts/package.sh

FROM scratch AS artifacts
COPY --from=package /out/ /
