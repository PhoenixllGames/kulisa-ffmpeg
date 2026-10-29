#!/usr/bin/env bash
# Host driver: builds the release assets inside Docker and copies them to ./dist.
#
# Usage:
#   ./build.sh            builds the toolchain image (apt from the pinned snapshot) and the assets;
#                         sources missing from sources/ are downloaded and verified
#   ./build.sh --offline  reuses the toolchain image and builds the assets with docker build
#                         --network none; every source must be in sources/
#
# In a git checkout the build uses the committed tree (git archive HEAD) and refuses a dirty tree. In
# an extracted source archive (no .git) it uses the files of the archive, its sources/ directory and
# its toolchain-dpkg-l.txt, which the toolchain image must match package for package.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env

OFFLINE=0
case "${1:-}" in
  "") ;;
  --offline) OFFLINE=1 ;;
  *) echo "usage: $0 [--offline]" >&2; exit 2 ;;
esac

TAG="v${FFMPEG_VERSION}-${BUILD_NUMBER}"
TOOLCHAIN_IMAGE="kulisa-ffmpeg-toolchain:noble-$APT_SNAPSHOT"
ARTIFACTS_IMAGE="kulisa-ffmpeg-artifacts:$TAG"
DIST="${DIST:-$PWD/dist}"

ctx="$(mktemp -d)"
cid=""
cleanup() {
  if [ -n "$cid" ]; then docker rm -f "$cid" >/dev/null; fi
  rm -rf "$ctx"
}
trap cleanup EXIT

# Build context: the repository files only, plus repo.tar (the same files, for the source archive),
# the pre-seeded sources and the expected toolchain package list.
mkdir -p "$ctx/tree/sources"
if [ -e .git ]; then
  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "the working tree is not clean; commit or remove the changes first" >&2
    git status --short >&2
    exit 1
  fi
  echo "building from commit $(git rev-parse HEAD)"
  git archive --format=tar HEAD > "$ctx/repo.tar"
  : > "$ctx/tree/expected-toolchain-dpkg-l.txt"
else
  if [ ! -f toolchain-dpkg-l.txt ]; then
    echo "not a git checkout and no toolchain-dpkg-l.txt: run this in a checkout or a source archive" >&2
    exit 1
  fi
  echo "building from the source archive in $PWD"
  tar --exclude=./sources --exclude=./dist --exclude=./toolchain-dpkg-l.txt -cf "$ctx/repo.tar" .
  cp toolchain-dpkg-l.txt "$ctx/tree/expected-toolchain-dpkg-l.txt"
fi
tar -xf "$ctx/repo.tar" -C "$ctx/tree"
mv "$ctx/repo.tar" "$ctx/tree/repo.tar"
if [ -d sources ]; then
  find sources -maxdepth 1 -type f -exec cp {} "$ctx/tree/sources/" \;
fi

build_args=(--build-arg "UBUNTU_IMAGE=$UBUNTU_IMAGE" --build-arg "APT_SNAPSHOT=$APT_SNAPSHOT")
if [ "$OFFLINE" -eq 1 ]; then
  if ! docker image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
    echo "offline build needs the toolchain image $TOOLCHAIN_IMAGE" >&2
    exit 1
  fi
  network=(--network none)
else
  docker build "${build_args[@]}" --target toolchain -t "$TOOLCHAIN_IMAGE" "$ctx/tree"
  network=()
fi
# --no-cache: the assets are always built from scratch on top of the toolchain image.
docker build "${build_args[@]}" --build-arg "TOOLCHAIN_IMAGE=$TOOLCHAIN_IMAGE" "${network[@]}" \
  --no-cache --target artifacts -t "$ARTIFACTS_IMAGE" "$ctx/tree"

# docker cp creates the files with the uid of the calling user.
cid="$(docker create "$ARTIFACTS_IMAGE" /nonexistent)"
rm -rf "$DIST"
mkdir -p "$DIST"
docker cp "$cid:/out/." "$DIST/"
docker rm -f "$cid" >/dev/null
cid=""
docker image rm "$ARTIFACTS_IMAGE" >/dev/null

(cd "$DIST" && sha256sum -c SHA256SUMS)
echo "assets in $DIST"
