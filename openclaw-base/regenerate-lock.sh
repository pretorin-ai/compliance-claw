#!/usr/bin/env bash
# Make the combined pnpm lock for the source-built OpenClaw base ONCE.
#
#   openclaw-base/regenerate-lock.sh OUTDIR
#
# Runs the reviewed r3 method in the pinned Node image: verify the exact
# upstream archive and files, apply workspace.diff, then
#   pnpm install --lockfile-only --ignore-scripts
# with the workspace's own strict minimumReleaseAge policy, which this script
# never changes. It refuses to start before LOCK_NOT_BEFORE (inputs.env).
#
# OUTDIR must not exist. It receives pnpm-lock.yaml, pnpm-workspace.yaml,
# lock.diff (unified, a/ b/ labels), package-changes.txt, lockfile-only.log and
# sha256.txt. Nothing here writes to the repository: a reviewer commits
# lock.diff and the two hashes in inputs.env after review (README.md).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:?usage: regenerate-lock.sh OUTDIR}"

export DRY_RUN="${REGEN_DRY_RUN:-0}"   # 1: verify inputs only, stop before pnpm; no lock is made
set -a
# shellcheck source=openclaw-base/inputs.env
. "$HERE/inputs.env"
set +a

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$DRY_RUN" != 1 ] && [[ "$now" < "$LOCK_NOT_BEFORE" ]]; then
  echo "REFUSED: $now is before $LOCK_NOT_BEFORE (joi 18.3.1 is younger than the" >&2
  echo "workspace minimumReleaseAge). The age rule is not changed; run again later." >&2
  exit 3
fi
[ ! -e "$OUT" ] || { echo "REFUSED: $OUT exists" >&2; exit 2; }
command -v docker >/dev/null || { echo "REFUSED: docker is required" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

echo "$WORKSPACE_DIFF_SHA256  $HERE/workspace.diff" | shasum -a 256 -c - >/dev/null \
  || { echo "REFUSED: workspace.diff hash" >&2; exit 4; }

docker run --rm --platform "$REGEN_PLATFORM" --network bridge \
  -e OPENCLAW_SOURCE_URL -e OPENCLAW_SOURCE_BYTES -e OPENCLAW_SOURCE_SHA256 \
  -e OPENCLAW_SOURCE_COMMIT -e UPSTREAM_DOCKERFILE_SHA256 -e UPSTREAM_WORKSPACE_SHA256 \
  -e UPSTREAM_LOCK_SHA256 -e PATCHED_WORKSPACE_SHA256 -e REGEN_NODE_IMAGE -e REGEN_PLATFORM -e DRY_RUN \
  -v "$HERE:/in:ro" -v "$REPO/scripts/openclaw-base-guard.py:/g/openclaw-base-guard.py:ro" \
  -v "$OUT:/out" "$REGEN_NODE_IMAGE" bash -euo pipefail -c '
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    curl -fsSL --retry 3 -o /tmp/src.tgz "$OPENCLAW_SOURCE_URL"
    test "$(stat -c %s /tmp/src.tgz)" = "$OPENCLAW_SOURCE_BYTES"
    echo "$OPENCLAW_SOURCE_SHA256  /tmp/src.tgz" | sha256sum -c -
    test "$(gzip -dc /tmp/src.tgz | git get-tar-commit-id)" = "$OPENCLAW_SOURCE_COMMIT"
    mkdir /work && tar -xzf /tmp/src.tgz -C /work --strip-components=1 && cd /work
    sha256sum -c - <<EOF
$UPSTREAM_DOCKERFILE_SHA256  Dockerfile
$UPSTREAM_WORKSPACE_SHA256  pnpm-workspace.yaml
$UPSTREAM_LOCK_SHA256  pnpm-lock.yaml
EOF
    cp pnpm-workspace.yaml /tmp/workspace.upstream.yaml
    cp pnpm-lock.yaml /tmp/lock.upstream.yaml
    patch pnpm-workspace.yaml < /in/workspace.diff
    echo "$PATCHED_WORKSPACE_SHA256  pnpm-workspace.yaml" | sha256sum -c -
    python3 -I /g/openclaw-base-guard.py policy --upstream /tmp/workspace.upstream.yaml --patched pnpm-workspace.yaml
    if [ "$DRY_RUN" = 1 ]; then echo "DRY RUN: inputs verified; no lock was made"; exit 0; fi

    corepack enable
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm install --lockfile-only --ignore-scripts 2>&1 | tee /out/lockfile-only.log
    grep -q "Lockfile passes supply-chain policies" /out/lockfile-only.log

    cp pnpm-lock.yaml pnpm-workspace.yaml /out/
    rc=0; diff -u --label a/pnpm-lock.yaml --label b/pnpm-lock.yaml /tmp/lock.upstream.yaml pnpm-lock.yaml > /out/lock.diff || rc=$?
    test "$rc" = 1
    python3 -I /g/openclaw-base-guard.py lock-changes --upstream /tmp/lock.upstream.yaml --patched pnpm-lock.yaml > /out/package-changes.txt
    {
      echo "started=$started finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "image=$REGEN_NODE_IMAGE platform=$REGEN_PLATFORM node=$(node --version) pnpm=$(pnpm --version) patch=$(patch --version | head -1)"
      cd /out && sha256sum pnpm-lock.yaml pnpm-workspace.yaml lock.diff package-changes.txt lockfile-only.log
    } > /out/sha256.txt
  '

[ "$DRY_RUN" != 1 ] || exit 0
cat "$OUT/package-changes.txt"
cat "$OUT/sha256.txt"
echo "Review lock.diff and package-changes.txt. Then copy lock.diff to openclaw-base/ and set"
echo "LOCK_DIFF_SHA256 and PATCHED_LOCK_SHA256 in inputs.env, in one separate commit."
