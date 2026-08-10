#!/usr/bin/env bash
#
# fetch-pretorin.sh — stage the pinned Pretorin release assets into a directory.
#
# The source is the PUBLIC pretorin-ai/homebrew-tap, so this is anonymous: no
# token, no `gh`, no credentials of any kind. Nothing here is trusted — this
# script only moves bytes onto disk. All trust decisions live in
# verify-pretorin.sh, which runs against whatever this staged.
#
# Usage: fetch-pretorin.sh [dir]      # dir defaults to <repo>/dist
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/versions.env"

DIR="${1:-${ROOT}/dist}"
BASE="https://github.com/${PRETORIN_REPO}/releases/download/v${PRETORIN_VERSION}"
BINARY="pretorin-${PRETORIN_VERSION}-${PRETORIN_TARGET}"

mkdir -p "$DIR"

# cosign.pub is deliberately NOT fetched: the trust anchor is vendor/cosign.pub,
# committed and reviewable. See vendor/README.md.
#
# -f turns an HTTP error into a non-zero exit rather than a file full of HTML.
# --retry keeps a transient network blip from surfacing later as a much scarier
# looking checksum or signature failure. --remove-on-error deletes the partial
# file: curl truncates before transferring, so without it a failed fetch leaves a
# 0-byte asset behind that a later verify would report as a signature error.
for f in "$BINARY" SHA256SUMS SHA256SUMS.sig; do
  echo "==> fetching ${f}"
  curl -fsSL --retry 3 --retry-all-errors --remove-on-error -o "${DIR}/${f}" "${BASE}/${f}"
done

echo "==> staged ${BINARY}, SHA256SUMS, SHA256SUMS.sig in ${DIR}"
