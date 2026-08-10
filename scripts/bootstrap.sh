#!/usr/bin/env bash
#
# bootstrap.sh — host-side setup. Everything a fresh clone needs before
# `docker compose up`, and nothing that talks to the Pretorin platform (that is
# scripts/onboard-targets.sh, which needs a key).
#
#   1. check Docker, compose v2, and linux/amd64 emulation
#   2. write .env with a generated gateway token, ONLY if absent
#   3. clone or update every target from targets.yaml into workspace/targets/,
#      minting a short-lived read-only GitHub App token if any target is private
#   4. pull the published image (or build it with --build), then confirm the
#      image really runs as x86_64
#
#   scripts/bootstrap.sh            # pull the released image (the normal path)
#   scripts/bootstrap.sh --build    # build locally instead (development)
#
# Idempotent: a second run fetches instead of cloning, leaves .env untouched, and
# hits the image cache. Nothing here ever deletes or overwrites an existing clone
# or an existing .env — when reality disagrees with targets.yaml it reports and
# exits non-zero rather than resolving it for you.
#
# GIT CREDENTIALS NEVER LEAVE THIS HOST. A private target is cloned with a
# GitHub App installation token that lives in a 0600 temp file for the duration
# of this script, is passed to git through a credential helper rather than in the
# URL or in argv, and is never written into the clone's .git/config. The container
# receives the resulting working tree over a read-only bind mount and nothing else.
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

DO_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --build) DO_BUILD=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'bootstrap: ERROR — unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log()  { printf 'bootstrap: %s\n' "$*"; }
warn() { printf 'bootstrap: WARNING — %s\n' "$*" >&2; }
die()  { printf 'bootstrap: ERROR — %s\n' "$*" >&2; exit 1; }

# The installation token, when private targets exist. Removed on every exit path,
# including failures and interrupts.
GH_TOKEN_FILE=""
# `return 0` is load-bearing, not tidiness. An EXIT trap's exit status becomes the
# SCRIPT's exit status, so a bare `[ -n "$GH_TOKEN_FILE" ] && rm -f ...` makes
# every run with no private targets exit 1 — a successful bootstrap reported as a
# failure. Found by the smoke test, which is the only reason it is not shipping.
cleanup() {
  [ -n "$GH_TOKEN_FILE" ] && rm -f "$GH_TOKEN_FILE"
  return 0
}
trap cleanup EXIT INT TERM

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

# --- 2. .env ---------------------------------------------------------------
# Before targets, not after: a private target's GitHub App configuration is read
# from this file, so it has to exist first. On a genuinely fresh clone the
# generated .env has an empty GITHUB_APP_ID, and a private target then fails with
# a message naming exactly what to fill in — which is the correct outcome, not a
# bug.

if [ -e .env ]; then
  # Never overwritten: it holds the operator's Pretorin key and the token every
  # existing session authenticated with. Rotating either is a deliberate act.
  log ".env exists, keeping it (contents not modified)"
  # GNU first, BSD second, and the order is not cosmetic: on GNU coreutils
  # `stat -f` means "filesystem status" and SUCCEEDS, so a BSD-first chain never
  # reaches its fallback and hands back a filesystem dump instead of a mode.
  MODE="$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null || echo '?')"
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

# --- 3. targets ------------------------------------------------------------

mkdir -p "$TARGETS_DIR"
TARGET_COUNT=0

# Never prompt for credentials. A private or moved remote must fail immediately
# with a clear error instead of blocking on a password prompt — and because the
# loop below reads its target list from stdin, a prompt would also swallow the
# rest of that list.
export GIT_TERMINAL_PROMPT=0

# Private targets need one installation token covering all of them, minted once
# before the loop. Collected in a first pass so a missing GitHub App is reported
# before anything is cloned rather than halfway through.
#
# Field order is name/url/private/ref, and reading it in that order matters: tab
# is IFS whitespace, so consecutive tabs collapse. With ref third, a target that
# omits ref would put "true" into the ref variable and leave private empty — a
# private repository silently cloned anonymously. parse-targets.py documents the
# contract and its self-test drives this exact shape through bash.
PRIVATE_SLUGS=()
while IFS=$'\t' read -r NAME URL PRIVATE _REF; do
  [ -n "$NAME" ] || continue
  [ "$PRIVATE" = "true" ] || continue
  # https://github.com/owner/repo.git -> owner/repo. The parser has already
  # guaranteed the host, so this is pure string work.
  SLUG="${URL#https://github.com/}"
  SLUG="${SLUG%.git}"
  PRIVATE_SLUGS+=("$SLUG")
done < <(python3 "$PARSE" list "$TARGETS_FILE")

if [ "${#PRIVATE_SLUGS[@]}" -gt 0 ]; then
  log "${#PRIVATE_SLUGS[@]} private target(s): ${PRIVATE_SLUGS[*]}"
  GH_TOKEN_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-gh-token.XXXXXX")"
  chmod 600 "$GH_TOKEN_FILE"
  # Fails closed with its own diagnostics: missing App id, unreadable key,
  # repository not in the installation, permission never granted.
  bash scripts/github-app-token.sh "$GH_TOKEN_FILE" "${PRIVATE_SLUGS[@]}" \
    || die "could not mint a GitHub App token for the private target(s).
  Nothing was cloned. See the messages above, or README.md ('Private repositories').
  A fine-grained PAT is a development-only fallback; the App is the supported path."
fi

# Runs git with the installation token supplied by a credential helper.
#
# Three properties this shape has and the obvious alternatives do not:
#   - The token is NOT in the URL, so it is never written into .git/config by
#     `git clone` and never ends up in `git remote -v` output.
#   - The token is NOT in argv, so it does not appear in `ps` for other users on
#     this host. The helper reads it from a 0600 file at the moment git asks.
#   - `git -c` sits BEFORE the subcommand, which makes it a one-shot override.
#     `git clone -c` would persist the setting into the new repository's config.
git_auth() {
  git -c credential.helper= \
      -c credential.helper='!f() { test "$1" = get && { echo username=x-access-token; echo "password=$(cat "'"$GH_TOKEN_FILE"'")"; }; }; f' \
      "$@"
}

# Every private clone is checked for a persisted credential. This is an assertion
# about the property above, not a hope: a git version that changed the rules
# should fail the run loudly, not leak a token into a file on disk.
assert_no_credential() {
  local dir="$1" name="$2"
  if grep -qE 'x-access-token|ghs_|github_pat_' "${dir}/.git/config" 2>/dev/null; then
    die "a git credential was persisted into ${dir}/.git/config for '${name}'.
  This must never happen. Remove the clone and report it:  rm -rf ${dir}"
  fi
}

while IFS=$'\t' read -r NAME URL PRIVATE REF; do
  [ -n "$NAME" ] || continue
  TARGET_COUNT=$((TARGET_COUNT + 1))
  DEST="${TARGETS_DIR}/${NAME}"
  if [ "$PRIVATE" = "true" ]; then GIT=git_auth; else GIT=git; fi

  if [ ! -e "$DEST" ]; then
    log "cloning ${NAME} from ${URL}${PRIVATE:+ (private: $PRIVATE)}"
    "$GIT" clone --quiet "$URL" "$DEST"
    [ "$PRIVATE" = "true" ] && assert_no_credential "$DEST" "$NAME"
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
    "$GIT" -C "$DEST" fetch --quiet --prune origin
    [ "$PRIVATE" = "true" ] && assert_no_credential "$DEST" "$NAME"

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

# --- 4. image --------------------------------------------------------------
# Pull is the default. compose.yaml names the published GHCR image and carries no
# `build:` section at all, so `docker compose up` can never silently build a local
# image that differs from the released one.
#
# --build selects compose.build.yaml, which adds the build section back. It is set
# through COMPOSE_FILE, docker compose's own native mechanism, so every other
# script in this repo picks it up with no changes: onboard-targets.sh and smoke.sh
# just call `docker compose` and inherit it.

# An operator already in the dev flow has COMPOSE_FILE exported, and pulling
# `compliance-claw:local` from a registry can only fail. Treat an inherited build
# overlay as --build rather than making them remember the flag every time.
case "${COMPOSE_FILE:-}" in
  *compose.build.yaml*)
    if [ "$DO_BUILD" = 0 ]; then
      log "COMPOSE_FILE already selects the build overlay; building instead of pulling"
      DO_BUILD=1
    fi
    ;;
esac

if [ "$DO_BUILD" = 1 ]; then
  export COMPOSE_FILE="compose.yaml:compose.build.yaml"
  log "--build: building locally (amd64; slow under emulation on first run)"
  log "  COMPOSE_FILE=${COMPOSE_FILE}"
  docker compose build
  log "for later commands in this shell:  export COMPOSE_FILE=${COMPOSE_FILE}"
else
  # Read from the one place versions are declared, so the message cannot claim a
  # version the deployment does not use.
  IMAGE_REF="$(awk -F= '/^IMAGE_REPO=/{r=$2} /^IMAGE_VERSION=/{v=$2} END{print r":"v}' versions.env)"
  log "pulling ${IMAGE_REF}"
  if ! docker compose pull --quiet 2>/dev/null; then
    docker compose pull || die "could not pull ${IMAGE_REF}.
  The package is not public, so an anonymous pull is refused. Log in first:
    echo \$GITHUB_TOKEN | docker login ghcr.io -u <your-github-username> --password-stdin
  A classic token needs the read:packages scope.
  To build locally instead of pulling:  scripts/bootstrap.sh --build"
  fi
fi

# The image is what actually has to be amd64, so confirm it on the real image
# rather than trusting the earlier host probe. Runs through the entrypoint, which
# is fine: the token check is scoped to gateway invocations.
IMAGE_ARCH="$(docker compose run --rm -T cli uname -m | tr -d '\r\n')"
[ "$IMAGE_ARCH" = "x86_64" ] \
  || die "image reports arch '${IMAGE_ARCH}', expected x86_64."
log "image runs as ${IMAGE_ARCH}"

cat <<EOF

bootstrap: done.
  targets:   ${TARGET_COUNT} under ${TARGETS_DIR} (bind-mounted read-only at /workspace/targets)$([ "${#PRIVATE_SLUGS[@]}" -gt 0 ] && printf '\n             %s private, cloned with a read-only GitHub App token that\n             stayed on this host and has been deleted' "${#PRIVATE_SLUGS[@]}")
  scope:     ${SYSTEM_ID} / ${FRAMEWORK_ID}
  image:     $([ "$DO_BUILD" = 1 ] && echo 'built locally (compose.build.yaml)' || echo "pulled ${IMAGE_REF:-}")

Next:
  1. put a read-only PRETORIN_API_KEY in .env   (see .env.example)
  2. scripts/onboard-targets.sh                 # register targets with Pretorin
  3. docker compose up -d                       # gateway on http://127.0.0.1:18789

Slack is optional. To have the agent answer in a Slack channel, import
slack/app-manifest.json at api.slack.com/apps/new, then put SLACK_APP_TOKEN,
SLACK_BOT_TOKEN and SLACK_CHANNEL_ID in .env BEFORE the first \`up\` — the config
is seeded once and never overwritten. See README.md ('Slack').
EOF
