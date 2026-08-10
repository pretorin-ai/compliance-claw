#!/usr/bin/env bash
#
# verify-pretorin.sh — verify staged Pretorin release assets, then install the
# verified binary. Fully offline: needs no network, only the staged bytes and the
# committed trust anchor (vendor/cosign.pub, see vendor/README.md).
#
# The gates run in this order, and the order is the security property:
#
#   1. cosign verify-blob over SHA256SUMS, keyed by vendor/cosign.pub.
#      Until this passes, NO line in SHA256SUMS is trustworthy — so an attacker
#      who rewrites the manifest to match a corrupted binary still fails here.
#   2. Hash the exact file that is about to be installed.
#   3. That digest must equal the PRETORIN_SHA256 pin, which fails closed even if
#      the signing key itself were compromised.
#   4. That digest must also be what the signed manifest records for this exact
#      filename, tying the trusted manifest to the bytes on disk.
#   5. install.
#
# Gates 2-4 hash ${DIR}/${BINARY} directly instead of delegating to
# `sha256sum -c SHA256SUMS`. That matters: a checksum line names the file it
# describes, and sha256sum filenames may contain spaces, so a signed line like
# "<pinned-digest>  decoy  <binary>" makes `-c` verify a decoy file while a
# different file gets installed — every gate reporting OK. Always hash the bytes
# you are actually going to use.
#
# The cosign invocation mirrors pretorin-cli tools/verify-release.sh, which is
# authoritative: signing runs with the transparency log disabled, so verification
# must pass --insecure-ignore-tlog=true (it warns; that is expected).
#
# Usage: verify-pretorin.sh [dir]     # dir defaults to <repo>/dist
#        INSTALL_DIR=... verify-pretorin.sh [dir]   # defaults to /usr/local/bin
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/versions.env"

DIR="${1:-${ROOT}/dist}"
ANCHOR="${ROOT}/vendor/cosign.pub"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BINARY="pretorin-${PRETORIN_VERSION}-${PRETORIN_TARGET}"

command -v cosign >/dev/null 2>&1 || {
  echo "verify-pretorin: cosign not found on PATH" >&2; exit 1; }

# coreutils on Linux, shasum on stock macOS (which ships no sha256sum).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# -s rather than -f throughout: curl truncates its output file before transfer and
# does not remove it on failure, so a half-finished fetch leaves a 0-byte file. An
# empty signature would otherwise surface as a cosign error that reads like tamper.
[ -s "$ANCHOR" ] || { echo "verify-pretorin: missing or empty trust anchor ${ANCHOR}" >&2; exit 1; }
for f in "$BINARY" SHA256SUMS SHA256SUMS.sig; do
  [ -s "${DIR}/${f}" ] || { echo "verify-pretorin: missing or empty ${f} in ${DIR}" >&2; exit 1; }
done

echo "==> cosign verify-blob (offline, no tlog) over SHA256SUMS"
cosign verify-blob \
  --key "$ANCHOR" \
  --signature "${DIR}/SHA256SUMS.sig" \
  --insecure-ignore-tlog=true \
  "${DIR}/SHA256SUMS"

echo "==> hashing ${BINARY}"
actual="$(sha256_of "${DIR}/${BINARY}")"

# Defence in depth against signing-key compromise: the signed manifest is only as
# trustworthy as the key that signed it, so cross-check against our own pin.
if [ "$actual" != "$PRETORIN_SHA256" ]; then
  echo "verify-pretorin: ${BINARY} does not match the pin in versions.env" >&2
  echo "  pinned: ${PRETORIN_SHA256}" >&2
  echo "  actual: ${actual}" >&2
  exit 1
fi
echo "    matches versions.env pin"

# Exact match on the filename field, not a regex: the version number's dots would
# be wildcards, and "<binary>" is a prefix of "<binary>.spdx.json". NF==2 rejects
# any line whose filename field contains whitespace.
signed="$(awk -v b="$BINARY" 'NF==2 && $2==b {print $1}' "${DIR}/SHA256SUMS")"
if [ -z "$signed" ]; then
  echo "verify-pretorin: signed SHA256SUMS contains no entry for ${BINARY}" >&2
  echo "  a substituted or rolled-back release looks exactly like this" >&2
  exit 1
fi
if [ "$signed" != "$actual" ]; then
  echo "verify-pretorin: ${BINARY} does not match its signed SHA256SUMS entry" >&2
  echo "  signed: ${signed}" >&2
  echo "  actual: ${actual}" >&2
  exit 1
fi
echo "    matches signed SHA256SUMS entry"

echo "==> installing verified binary to ${INSTALL_DIR}/pretorin"
install -d "$INSTALL_DIR"
install -m 0755 "${DIR}/${BINARY}" "${INSTALL_DIR}/pretorin"

echo "==> PRETORIN VERIFIED: ${PRETORIN_VERSION}"
