#!/usr/bin/env bash
# Host driver: builds the release assets inside Docker and copies them to ./dist.
#
# Usage:
#   ./build.sh            builds the toolchain image (apt from the pinned snapshot) and the assets;
#                         sources missing from sources/ are downloaded and verified
#   ./build.sh --offline  reuses the toolchain image and builds the assets with docker build
#                         --network none; every source must be in sources/
#   ./build.sh --dev      (git checkout only) builds HEAD without the release tag; the assets are named
#                         kulisa-ffmpeg-<tag>-dev-<commit>-*, never like a release
#
# In a git checkout the build refuses a dirty tree and, without --dev, refuses to run unless HEAD
# carries the release tag v<FFMPEG_VERSION>-<BUILD_NUMBER> from versions.env; it then uses the tagged
# commit (git archive of the tag). In an extracted source archive (no .git) it uses the files of the
# archive, the asset name in its build-tag.txt, its sources/ directory and its toolchain-dpkg-l.txt,
# which the toolchain image must match package for package.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env

OFFLINE=0
DEV=0
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
    --dev) DEV=1 ;;
    *) echo "usage: $0 [--offline] [--dev]" >&2; exit 2 ;;
  esac
done

TAG="v${FFMPEG_VERSION}-${BUILD_NUMBER}"
TOOLCHAIN_IMAGE="kulisa-ffmpeg-toolchain:noble-$APT_SNAPSHOT"
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
  if [ "$DEV" -eq 1 ]; then
    ASSET_TAG="$TAG-dev-$(git rev-parse --short=12 HEAD)"
    ref=HEAD
  else
    # A release is built only from its tagged commit, so the asset names that Kulisa pins by SHA-256
    # never carry the bytes of another commit.
    if ! git tag --points-at HEAD | grep -qxF "$TAG"; then
      echo "HEAD does not carry the release tag $TAG (versions.env); tag the commit or use --dev" >&2
      exit 1
    fi
    ASSET_TAG="$TAG"
    ref="refs/tags/$TAG^{commit}"
  fi
  echo "building $ASSET_TAG from commit $(git rev-parse "$ref")"
  git archive --format=tar "$ref" > "$ctx/repo.tar"
  : > "$ctx/tree/expected-toolchain-dpkg-l.txt"
else
  if [ "$DEV" -eq 1 ]; then
    echo "--dev needs a git checkout" >&2
    exit 2
  fi
  if [ ! -f toolchain-dpkg-l.txt ] || [ ! -f build-tag.txt ]; then
    echo "not a git checkout and no toolchain-dpkg-l.txt or build-tag.txt: run this in a checkout or a source archive" >&2
    exit 1
  fi
  ASSET_TAG="$(cat build-tag.txt)"
  case "$ASSET_TAG" in
    "$TAG"|"$TAG"-dev-*) ;;
    *) echo "build-tag.txt ($ASSET_TAG) does not match versions.env ($TAG)" >&2; exit 1 ;;
  esac
  echo "building $ASSET_TAG from the source archive in $PWD"
  tar --exclude=./sources --exclude=./dist --exclude=./toolchain-dpkg-l.txt --exclude=./build-tag.txt \
    -cf "$ctx/repo.tar" .
  cp toolchain-dpkg-l.txt "$ctx/tree/expected-toolchain-dpkg-l.txt"
fi
ARTIFACTS_IMAGE="kulisa-ffmpeg-artifacts:$ASSET_TAG"
tar -xf "$ctx/repo.tar" -C "$ctx/tree"
mv "$ctx/repo.tar" "$ctx/tree/repo.tar"
if [ -d sources ]; then
  find sources -maxdepth 1 -type f -exec cp {} "$ctx/tree/sources/" \;
fi

build_args=(--build-arg "UBUNTU_IMAGE=$UBUNTU_IMAGE" --build-arg "APT_SNAPSHOT=$APT_SNAPSHOT"
            --build-arg "ASSET_TAG=$ASSET_TAG")
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
