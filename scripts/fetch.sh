#!/usr/bin/env bash
# Downloads every source into /work/sources and verifies it. Any mismatch stops the build.
#   - SHA-256 of every file against versions.env
#   - GPG signature of the FFmpeg tarball against the pinned release key fingerprint
set -euo pipefail
cd "$(dirname "$0")/.."
. ./versions.env

mkdir -p sources
cd sources

fetch() { # file url sha256
  curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$1" "$2"
  echo "$3  $1" | sha256sum -c -
}

fetch "$FFMPEG_FILE" "$FFMPEG_URL" "$FFMPEG_SHA256"
fetch "$FFMPEG_SIG_FILE" "$FFMPEG_SIG_URL" "$FFMPEG_SIG_SHA256"
fetch "$FFMPEG_KEY_FILE" "$FFMPEG_KEY_URL" "$FFMPEG_KEY_SHA256"
fetch "$NV_CODEC_HEADERS_FILE" "$NV_CODEC_HEADERS_URL" "$NV_CODEC_HEADERS_SHA256"
fetch "$AMF_FILE" "$AMF_URL" "$AMF_SHA256"
fetch "$LIBVPL_FILE" "$LIBVPL_URL" "$LIBVPL_SHA256"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$FFMPEG_KEY_FILE"
imported="$(gpg --batch --with-colons --fingerprint | awk -F: '$1=="fpr"{print $10; exit}')"
if [ "$imported" != "$FFMPEG_KEY_FPR" ]; then
  echo "FFmpeg release key fingerprint mismatch: $imported" >&2
  exit 1
fi
status="$(gpg --batch --status-fd 1 --verify "$FFMPEG_SIG_FILE" "$FFMPEG_FILE" 2>/dev/null)"
if ! grep -q "^\[GNUPG:\] VALIDSIG $FFMPEG_KEY_FPR " <<<"$status"; then
  echo "FFmpeg tarball signature is not valid for key $FFMPEG_KEY_FPR" >&2
  exit 1
fi
rm -rf "$GNUPGHOME"
echo "sources verified: SHA-256 for all files, GPG for $FFMPEG_FILE (key $FFMPEG_KEY_FPR)"
