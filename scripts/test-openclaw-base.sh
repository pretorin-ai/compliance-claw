#!/usr/bin/env bash
# Check a built Claw image against the committed receipt of its source-built
# OpenClaw base (openclaw-base/README.md).
#
#   scripts/test-openclaw-base.sh IMAGE [RECEIPT_DIR]
#
# IMAGE must already be in the local Docker store (build or pull it first;
# nothing is fetched here). The default receipt is
# openclaw-base/receipts/<BASE_IMAGE_TAG> from openclaw-base/inputs.env.
#
# Checks (scripts/openclaw-base-guard.py compare):
#   - /app/dist equals the receipt manifest (no stale dist or control-ui file);
#   - /app/node_modules equals the receipt, except the app npm package, which
#     the Claw npm step replaces; that package must have the versions.env
#     NPM_* versions;
#   - the pnpm store list equals the receipt; no forbidden entry is present;
#   - version surfaces equal the source version and commit;
#   - RootFS diffIDs start with the base receipt's diffIDs, and no official
#     OpenClaw layer (other than the shared Node bookworm-slim layers) is present.
#     All diffID lists are linux/amd64.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:?usage: test-openclaw-base.sh IMAGE [RECEIPT_DIR]}"
# shellcheck source=openclaw-base/inputs.env
. "$REPO/openclaw-base/inputs.env"
RECEIPT="${2:-$REPO/openclaw-base/receipts/$BASE_IMAGE_TAG}"

[ -f "$RECEIPT/facts.json" ] || {
  echo "REFUSED: no base receipt at $RECEIPT. The guard applies only after the" >&2
  echo "FROM lines use a reviewed base digest (README.md, promotion step 4)." >&2
  exit 2
}
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "REFUSED: $IMAGE is not in the local Docker store; build or pull it first" >&2
  exit 2
}
platform="$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$IMAGE")"
[ "$platform" = "$BUILD_PLATFORM" ] || {
  echo "REFUSED: $IMAGE is $platform; the receipt is for $BUILD_PLATFORM" >&2
  exit 2
}

OUT="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-base-check.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
chmod 0777 "$OUT"

docker run --rm --platform "$BUILD_PLATFORM" --network none --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
  -v "$REPO/scripts/openclaw-base-guard.py:/guard/openclaw-base-guard.py:ro" \
  -v "$OUT:/out" --entrypoint python3 "$IMAGE" \
  -I /guard/openclaw-base-guard.py collect --root / --out /out
docker image inspect -f '{{range .RootFS.Layers}}{{println .}}{{end}}' "$IMAGE" > "$OUT/diffids.txt"

python3 -I "$REPO/scripts/openclaw-base-guard.py" compare \
  --receipt "$RECEIPT" --observed "$OUT" \
  --forbidden "$REPO/openclaw-base/forbidden-store-entries.txt" \
  --diffids "$OUT/diffids.txt" --versions-env "$REPO/versions.env" \
  --expect-version "$OPENCLAW_VERSION" --expect-commit "$OPENCLAW_SOURCE_COMMIT"
