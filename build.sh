#!/usr/bin/env bash
# Host driver: builds the release assets inside Docker and copies them to ./dist.
# Needs Docker and network access (the sources are downloaded and verified inside the build).
# Usage: ./build.sh            (the tag comes from versions.env)
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env

TAG="v${FFMPEG_VERSION}-${BUILD_NUMBER}"
DIST="${DIST:-$PWD/dist}"

docker build --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --target toolchain \
  -t "kulisa-ffmpeg-toolchain:ubuntu24.04" .
docker build --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --target artifacts \
  -t "kulisa-ffmpeg-artifacts:$TAG" .

# docker cp creates the files with the uid of the calling user.
cid="$(docker create "kulisa-ffmpeg-artifacts:$TAG" /nonexistent)"
trap 'docker rm -f "$cid" >/dev/null' EXIT
rm -rf "$DIST"
mkdir -p "$DIST"
docker cp "$cid:/out/." "$DIST/"

(cd "$DIST" && sha256sum -c SHA256SUMS)
echo "assets in $DIST"
