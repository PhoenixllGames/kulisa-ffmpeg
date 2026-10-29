# Cross build of the Kulisa FFmpeg (Windows x64) on Ubuntu 24.04 with the mingw-w64 toolchain.
# Run it through ./build.sh, which builds the context from the committed tree (or from an extracted
# source archive) and passes repo.tar, sources/ and expected-toolchain-dpkg-l.txt. Stages:
#   toolchain  apt packages from a pinned snapshot and the win32 thread model of mingw-w64
#   build      verify (or download) the sources, build the dependencies and FFmpeg
#   package    import check, BUILDINFO, licenses, zip and source archive
#   artifacts  scratch image holding only /out, for docker create and docker cp
# build and package start from TOOLCHAIN_IMAGE, the image that build.sh tagged from the toolchain
# stage, so an offline rebuild (docker build --network none) needs no apt access.
ARG UBUNTU_IMAGE
ARG TOOLCHAIN_IMAGE=toolchain

FROM ${UBUNTU_IMAGE} AS toolchain
ARG APT_SNAPSHOT
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC
# apt reads every index and package from the snapshot.ubuntu.com snapshot APT_SNAPSHOT. The base image
# has no CA certificates, so ca-certificates is installed first without TLS peer verification; apt
# still checks the signed InRelease files against the Ubuntu archive key of the pinned base image and
# every package against its hash. Everything else is installed with TLS verification on.
RUN test -n "$APT_SNAPSHOT" \
 && echo "APT::Snapshot \"$APT_SNAPSHOT\";" > /etc/apt/apt.conf.d/50kulisa-snapshot \
 && apt-get -o Acquire::https::Verify-Peer=false update \
 && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends ca-certificates \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      curl gnupg xz-utils python3 file \
      build-essential make nasm pkg-config cmake ninja-build \
      binutils-mingw-w64-x86-64 gcc-mingw-w64-x86-64-win32 g++-mingw-w64-x86-64-win32 \
      mingw-w64-x86-64-dev mingw-w64-common \
      clang llvm \
 && update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-win32 \
 && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-win32 \
 && rm -rf /var/lib/apt/lists/*

FROM ${TOOLCHAIN_IMAGE} AS build
# Asset name: the release tag, or <tag>-dev-<commit> for build.sh --dev.
ARG ASSET_TAG
WORKDIR /work
COPY versions.env components /work/
COPY scripts/ /work/scripts/
COPY sources/ /work/sources/
RUN bash /work/scripts/fetch.sh
RUN bash /work/scripts/build-deps.sh
RUN bash /work/scripts/build-ffmpeg.sh

FROM ${TOOLCHAIN_IMAGE} AS package
ARG ASSET_TAG
WORKDIR /work
COPY --from=build /work/sources /work/sources
COPY --from=build /work/stage /work/stage
COPY --from=build /work/logs /work/logs
COPY repo.tar expected-toolchain-dpkg-l.txt /work/
RUN mkdir /work/repo \
 && tar -xf /work/repo.tar -C /work/repo \
 && bash /work/repo/scripts/package.sh

FROM scratch AS artifacts
COPY --from=package /out/ /out/
