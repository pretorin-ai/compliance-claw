#!/usr/bin/env bash
# Point a GHCR tag at a verified digest by re-PUTting THE SAME MANIFEST BYTES.
#
#   scripts/release-tag.sh IMAGE_REPO DIGEST TAG [--allow-move]
#
# CI ONLY (.github/workflows/release.yml). Needs GH_TOKEN (the automatic
# GITHUB_TOKEN with packages:write), GITHUB_ACTOR, curl, python3 and docker.
#
# A digest IS the hash of the manifest bytes, so re-PUTting those bytes under a
# tag preserves it by construction -- there is no operation to get wrong.
#
# `docker buildx imagetools create --tag X repo@digest` is NOT that operation and
# must not be used here. It does not move a tag; it BUILDS A NEW MANIFEST LIST
# wrapping the source, which by definition hashes differently. v0.2.0's first
# release attempt proved it: the step published `sha256:351ecb37...` (a
# manifest.list) for a verified `sha256:34619259...` (a manifest.v2), and the
# gate below correctly refused to let a tag point at bytes nothing had verified.
#
# `docker tag` + `docker push` would probably preserve the digest for a single
# manifest, but only as a side effect of the client regenerating an identical
# manifest. "Probably" is not a supply-chain control.
#
# A TAG THAT ALREADY EXISTS is left alone when it already names DIGEST (a retry),
# and refused when it names other bytes -- unless --allow-move is given. Only the
# candidate tag may move; a version tag never does, so a retry cannot replace a
# completed version with different bytes.
set -euo pipefail

die() { echo "::error::release-tag: $*" >&2; exit 1; }

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || die "usage: release-tag.sh IMAGE_REPO DIGEST TAG [--allow-move]"
IMAGE_REPO="$1" DIGEST="$2" TAG="$3" MOVE="${4:-}"
[ -z "$MOVE" ] || [ "$MOVE" = --allow-move ] || die "unknown option ${MOVE}"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest '${DIGEST}' is not sha256:<64 hex>"
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "tag '${TAG}' is not a valid tag"
case "$IMAGE_REPO" in ghcr.io/*/*) ;; *) die "'${IMAGE_REPO}' is not a ghcr.io repository" ;; esac
: "${GH_TOKEN:?GH_TOKEN is required}" "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"

REPO_PATH="${IMAGE_REPO#ghcr.io/}"
ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A registry bearer token for this repository only, exchanged from the automatic
# GITHUB_TOKEN. Same credential `docker login` already used.
TOKEN="$(curl -fsSL -u "${GITHUB_ACTOR}:${GH_TOKEN}" \
  "https://ghcr.io/token?service=ghcr.io&scope=repository:${REPO_PATH}:pull,push" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
[ -n "$TOKEN" ] || die "could not obtain a ghcr.io token"

# Gate 0: what the tag names now, if it exists.
CODE="$(curl -sSL -I -o "$WORK/head" -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${ACCEPT}" \
  "https://ghcr.io/v2/${REPO_PATH}/manifests/${TAG}")"
case "$CODE" in
  200)
    CURRENT="$(awk -F': *' 'tolower($1)=="docker-content-digest"{gsub("\r","",$2); print $2}' "$WORK/head")"
    if [ "$CURRENT" = "$DIGEST" ]; then
      echo "tag ${IMAGE_REPO}:${TAG} already names ${DIGEST}; nothing to do"
      exit 0
    fi
    [ "$MOVE" = --allow-move ] \
      || die "tag ${IMAGE_REPO}:${TAG} already names ${CURRENT:-other bytes}, not ${DIGEST}. A version tag never moves."
    echo "moving ${IMAGE_REPO}:${TAG} from ${CURRENT} to ${DIGEST}" ;;
  404) ;;
  *) die "could not read the current tag ${TAG} (HTTP ${CODE})" ;;
esac

# Content-Type must be echoed back exactly: it is part of what the digest
# covers, so guessing it would change the bytes and hence the digest.
CT="$(curl -fsSL -o "$WORK/manifest.json" -w '%{content_type}' \
  -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${ACCEPT}" \
  "https://ghcr.io/v2/${REPO_PATH}/manifests/${DIGEST}")"

# Gate 1: the bytes we are about to re-PUT really are the verified image.
LOCAL="sha256:$(sha256sum "$WORK/manifest.json" | cut -d' ' -f1)"
[ "$LOCAL" = "$DIGEST" ] || die "fetched manifest hashes to ${LOCAL}, expected ${DIGEST}"

# Gate 2: the registry's own accounting of what it just stored.
STORED="$(curl -fsSL -X PUT -o /dev/null -w '%header{docker-content-digest}' \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: ${CT}" \
  --data-binary @"$WORK/manifest.json" \
  "https://ghcr.io/v2/${REPO_PATH}/manifests/${TAG}")"
[ "$STORED" = "$DIGEST" ] || die "registry stored the tag as ${STORED}, expected ${DIGEST}"

# Gate 3: resolve the tag through the docker client, so the check does not
# depend on the same API call that wrote it.
RESOLVED="$(docker buildx imagetools inspect "${IMAGE_REPO}:${TAG}" --format '{{json .Manifest.Digest}}' | tr -d '"')"
[ "$RESOLVED" = "$DIGEST" ] || die "tag ${IMAGE_REPO}:${TAG} resolves to ${RESOLVED}, expected ${DIGEST}"
echo "tag ${IMAGE_REPO}:${TAG} -> ${DIGEST}"
