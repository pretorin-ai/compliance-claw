#!/usr/bin/env bash
#
# bootstrap.sh — host-side setup. Everything a fresh clone needs before
# `docker compose up`, and nothing that talks to the Pretorin platform (that is
# scripts/onboard-targets.sh, which needs a key).
#
#   1. check Docker, compose v2, and linux/amd64 emulation
#   2. clone or update every target from targets.yaml into workspace/targets/
#   3. write .env with a generated gateway token, ONLY if absent
#   4. docker compose build, then confirm the image really runs as x86_64
#
# Idempotent: a second run fetches instead of cloning, leaves .env untouched, and
# hits the build cache. Nothing here ever deletes or overwrites an existing clone
# or an existing .env — when reality disagrees with targets.yaml it reports and
# exits non-zero rather than resolving it for you.
#
# Written for macOS (the POC's operator platform) but plain POSIX-ish bash, so it
# also runs on the Linux CI runner. Dependencies are git, python3, openssl and
# docker; on macOS the first three come with the Command Line Tools, which git
# already requires.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGETS_FILE="${TARGETS_FILE:-targets.yaml}"
TARGETS_DIR="workspace/targets"
PARSE="scripts/parse-targets.py"

log()  { printf 'bootstrap: %s\n' "$*"; }
warn() { printf 'bootstrap: WARNING — %s\n' "$*" >&2; }
die()  { printf 'bootstrap: ERROR — %s\n' "$*" >&2; exit 1; }

# --- 1. host preflight -----------------------------------------------------

command -v git >/dev/null 2>&1 || die "git not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found (macOS: xcode-select --install)."
command -v openssl >/dev/null 2>&1 || die "openssl not found."
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Desktop and start it."
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable. Start Docker Desktop and retry."
docker compose version >/dev/null 2>&1 \
  || die "'docker compose' (v2) not available. This project does not use docker-compose v1."
log "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), $(docker compose version --short 2>/dev/null || echo '?')"

# Upstream publishes no linux/arm64 Pretorin binary, so the image is amd64 even
# on Apple Silicon. Emulation is therefore a hard requirement, and finding out
# during a long build — as an 'exec format error' — is a bad way to learn it.
# The probe reuses the digest already pinned on the Dockerfile's first FROM line,
# so this check introduces no second place to bump a pin, and the image it pulls
# is one the build needs anyway.
HOST_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || uname -m)"
case "$HOST_ARCH" in
  x86_64 | amd64)
    log "host is amd64, no emulation needed"
    ;;
  *)
    PROBE_IMAGE="$(awk '/^FROM debian:/ {print $2; exit}' Dockerfile)"
    [ -n "$PROBE_IMAGE" ] || die "could not read the pinned debian image from Dockerfile."
    log "host is ${HOST_ARCH}; probing linux/amd64 emulation with ${PROBE_IMAGE%%@*}"
    docker run --rm --platform linux/amd64 "$PROBE_IMAGE" /bin/true >/dev/null 2>&1 \
      || die "cannot run linux/amd64 images on this host.
  Docker Desktop: Settings -> General -> 'Use Rosetta for x86_64/amd64 emulation',
  or Settings -> Features in development. Colima/other: enable qemu binfmt.
  Upstream ships no linux/arm64 Pretorin binary, so amd64 is required."
    log "linux/amd64 emulation works"
    ;;
esac

[ -f "$TARGETS_FILE" ] || die "${TARGETS_FILE} not found."
python3 "$PARSE" scope "$TARGETS_FILE" >/dev/null   # fail fast on a bad file
IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID < <(python3 "$PARSE" scope "$TARGETS_FILE")
log "scope: system=${SYSTEM_ID} framework=${FRAMEWORK_ID}"

# --- 2. targets ------------------------------------------------------------

mkdir -p "$TARGETS_DIR"
TARGET_COUNT=0

# Never prompt for credentials. A private or moved remote must fail immediately
# with a clear error instead of blocking on a password prompt — and because the
# loop below reads its target list from stdin, a prompt would also swallow the
# rest of that list.
export GIT_TERMINAL_PROMPT=0

while IFS=$'\t' read -r NAME URL REF; do
  [ -n "$NAME" ] || continue
  TARGET_COUNT=$((TARGET_COUNT + 1))
  DEST="${TARGETS_DIR}/${NAME}"

  if [ ! -e "$DEST" ]; then
    log "cloning ${NAME} from ${URL}"
    git clone --quiet "$URL" "$DEST"
    if [ -n "$REF" ]; then
      git -C "$DEST" checkout --quiet "$REF" \
        || die "cloned ${NAME} but ref '${REF}' does not exist in ${URL}."
    fi
  elif [ ! -d "$DEST" ]; then
    die "${DEST} exists but is not a directory. Move it aside and retry."
  elif [ "$(git -C "$DEST" rev-parse --show-toplevel 2>/dev/null || true)" != "$(cd "$DEST" && pwd -P)" ]; then
    # An interrupted clone leaves a directory that is neither absent nor a
    # usable repository. Reporting beats guessing, and beats deleting: this
    # script never removes anything under workspace/targets.
    #
    # The test compares --show-toplevel against this directory rather than just
    # asking `rev-parse --git-dir`: git searches PARENT directories, so an empty
    # workspace/targets/<name> inside this repository answers with
    # compliance-claw's own .git and looks like a valid clone that merely has the
    # wrong remote. --show-toplevel is documented as the top-level directory of
    # the working tree, so requiring it to be this path is the real question.
    die "${DEST} exists but is not the root of a git repository (an interrupted clone?).
  Inspect it, then remove it yourself and re-run:  rm -rf ${DEST}"
  else
    ACTUAL_URL="$(git -C "$DEST" remote get-url origin 2>/dev/null || echo '')"
    if [ "$ACTUAL_URL" != "$URL" ]; then
      die "${DEST} tracks a different remote.
  targets.yaml: ${URL}
  on disk:      ${ACTUAL_URL:-<no origin>}
  Refusing to touch it. Fix targets.yaml, or move the directory aside."
    fi
    log "updating ${NAME} (fetch)"
    git -C "$DEST" fetch --quiet --prune origin

    if [ -n "$REF" ]; then
      if [ -n "$(git -C "$DEST" status --porcelain)" ]; then
        warn "${NAME} has local changes; fetched but not moved to '${REF}'."
      else
        git -C "$DEST" checkout --quiet "$REF" \
          || die "ref '${REF}' does not exist in ${NAME}."
        # --ff-only: never create a merge commit in a review target. An upstream
        # force-push shows up here as a clear failure instead of a silent merge.
        if git -C "$DEST" rev-parse --quiet --verify "origin/${REF}" >/dev/null; then
          git -C "$DEST" merge --quiet --ff-only "origin/${REF}" \
            || warn "${NAME} cannot fast-forward to origin/${REF} (diverged?); left as-is."
        fi
      fi
    fi
  fi

  log "  ${NAME}: $(git -C "$DEST" rev-parse --short HEAD) on $(git -C "$DEST" rev-parse --abbrev-ref HEAD)"
done < <(python3 "$PARSE" list "$TARGETS_FILE")

[ "$TARGET_COUNT" -gt 0 ] || die "no targets parsed from ${TARGETS_FILE}."
log "${TARGET_COUNT} target(s) present under ${TARGETS_DIR}"

# --- 3. .env ---------------------------------------------------------------

if [ -e .env ]; then
  # Never overwritten: it holds the operator's Pretorin key and the token every
  # existing session authenticated with. Rotating either is a deliberate act.
  log ".env exists, keeping it (contents not modified)"
  MODE="$(stat -f '%Lp' .env 2>/dev/null || stat -c '%a' .env 2>/dev/null || echo '?')"
  if [ "$MODE" != "600" ]; then
    # Tightening the mode is not the same as overwriting the file, and this one
    # holds an API key: leaving it group/world-readable is the leak the 600 was
    # for. The contents are still never touched.
    log "  .env mode was ${MODE}; tightening to 600 (contents untouched)"
    chmod 600 .env
  fi
  grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env \
    || warn ".env has no OPENCLAW_GATEWAY_TOKEN value; the gateway will exit 1."
else
  log "writing .env (mode 600) with a generated gateway token"
  # Generated from .env.example so the documentation lives in exactly one file.
  # umask first: the file must never exist, even briefly, as world-readable.
  ( umask 077 && sed 's|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN='"$(openssl rand -hex 32)"'|' \
      .env.example > .env )
  chmod 600 .env
  # The sed above is only correct while .env.example still carries that exact
  # key. Assert rather than trust: a silently token-less .env fails much later,
  # as an exit 1 from a container.
  grep -qE '^OPENCLAW_GATEWAY_TOKEN=[0-9a-f]{64}$' .env \
    || die "generated .env has no valid OPENCLAW_GATEWAY_TOKEN — did .env.example change?"
  log "  PRETORIN_API_KEY is empty. Add a read-only key to .env before onboarding."
fi

# --- 4. build --------------------------------------------------------------

log "docker compose build (amd64; slow under emulation on first run)"
docker compose build

# The image is what actually has to be amd64, so confirm it on the built image
# rather than trusting the earlier probe. Runs through the entrypoint, which is
# fine: the token check is scoped to gateway invocations.
IMAGE_ARCH="$(docker compose run --rm -T cli uname -m | tr -d '\r\n')"
[ "$IMAGE_ARCH" = "x86_64" ] \
  || die "built image reports arch '${IMAGE_ARCH}', expected x86_64."
log "image runs as ${IMAGE_ARCH}"

cat <<EOF

bootstrap: done.
  targets:   ${TARGET_COUNT} under ${TARGETS_DIR} (bind-mounted read-only at /workspace/targets)
  scope:     ${SYSTEM_ID} / ${FRAMEWORK_ID}

Next:
  1. put a read-only PRETORIN_API_KEY in .env   (see .env.example)
  2. scripts/onboard-targets.sh                 # register targets with Pretorin
  3. docker compose up -d                       # gateway on http://127.0.0.1:18789
EOF
