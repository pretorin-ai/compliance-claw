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
#      (the clone/update logic itself lives in scripts/sync-targets.sh, which is
#      the same implementation the Slack /target-sync route runs)
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
# GIT CREDENTIALS ON THIS PATH NEVER LEAVE THIS HOST, AND THAT SENTENCE IS NOW
# NARROWER THAN IT USED TO BE. Read it carefully before relying on it.
#
# What still holds, unchanged: the GitHub App private key is host-only, the
# installation token it mints lives in a 0600 temp file for the duration of this
# script, both are passed to git through a credential helper rather than in the
# URL or in argv, neither is ever written into a clone's .git/config, and neither
# is ever mounted into a container.
#
# What has been DELIBERATELY RELAXED for the internal pilot: private targets can
# now also be synchronized from Slack, inside the container, which means that
# path needs a credential of its own. That credential is a fine-grained,
# read-only, selected-repositories PAT delivered as a mounted file
# (secrets/runtime/github-readonly-pat). It is a git credential that DOES live
# inside the container. It is never exported into the environment and never
# reaches the model's prompt, but tool execution in that container is
# unsandboxed, so a prompt-injected agent can read the file. That is an accepted
# internal-pilot limitation, not a boundary — SECURITY.md says so plainly, and
# the GitHub App remains the recommended mechanism for anything beyond the pilot.
#
# THIS SCRIPT still prefers the App and will not silently fall back to the PAT:
# if an App is configured and minting fails, it stops.
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
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
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

# --- 2. credentials --------------------------------------------------------
# TWO PATHS, AND THIS SCRIPT MUST NOT MIX THEM.
#
#   RECOMMENDED  file-backed secrets. Values live in secrets/runtime/*, mounted
#                read-only, and .env holds NON-SECRETS ONLY. Selected by putting
#                compose.secrets.yaml in COMPOSE_FILE — the same way the build
#                overlay is selected further down, so there is one mechanism to
#                learn rather than a bespoke flag.
#
#   LEGACY       secret values in .env. Still supported; still what an existing
#                deployment uses. compose's env_file hands every value here to
#                the container AND to `docker inspect`.
#
# Putting a gateway token in .env on the FILE-SECRET path is not a harmless
# belt-and-braces: the entrypoint refuses when a secret is supplied twice
# ("... and ..._FILE are both set") and the gateway exits before serving. So on
# that path this script deliberately generates nothing secret into .env.
FILE_SECRETS=0
case "${COMPOSE_FILE:-}" in
  *compose.secrets.yaml*) FILE_SECRETS=1 ;;
esac
if [ "$FILE_SECRETS" = 1 ]; then
  log "credential path: FILE-BACKED (compose.secrets.yaml selected)"
else
  log "credential path: legacy .env values (recommended: compose.secrets.yaml, see docs/file-secrets.md)"
fi

# --- 2a. .env --------------------------------------------------------------
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
  if [ "$FILE_SECRETS" = 1 ]; then
    # On this path a token in .env is the problem, not its absence: supplied both
    # ways, the entrypoint refuses and the gateway never starts.
    if grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env; then
      warn ".env still carries a gateway token value, and compose.secrets.yaml also mounts one."
      warn "  The entrypoint refuses a secret supplied twice, so the gateway will exit."
      warn "  Blank the .env line (keep 'OPENCLAW_GATEWAY_TOKEN=') and keep the file under"
      warn "  secrets/runtime/ as the single source."
    fi
    for legacy_secret in PRETORIN_API_KEY SLACK_APP_TOKEN SLACK_BOT_TOKEN; do
      if grep -qE "^${legacy_secret}=.+" .env; then
        warn ".env still carries a ${legacy_secret} value; on the file-secret path it belongs in"
        warn "  secrets/runtime/. Both at once is refused by the entrypoint."
      fi
    done
  else
    grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env \
      || warn ".env has no OPENCLAW_GATEWAY_TOKEN value; the gateway will exit 1."
  fi
elif [ "$FILE_SECRETS" = 1 ]; then
  # NON-SECRETS ONLY. Copied verbatim from .env.example, which ships every secret
  # line empty — so no substitution, and nothing here to leak into
  # `docker inspect`. The gateway token is generated into its own file below.
  log "writing .env (mode 600) with NON-SECRETS ONLY (file-secret path)"
  ( umask 077 && cp .env.example .env )
  chmod 600 .env
  # Assert the shipped example really is value-free, rather than trusting it: a
  # future edit that pastes a placeholder secret in here would silently create the
  # dual-source conflict this branch exists to avoid.
  if grep -qE '^(PRETORIN_API_KEY|OPENCLAW_GATEWAY_TOKEN|SLACK_APP_TOKEN|SLACK_BOT_TOKEN)=.+' .env; then
    die "generated .env carries a secret value, which the file-secret path forbids —
  .env.example must ship these lines empty. Fix .env.example, then re-run."
  fi
else
  log "writing .env (mode 600) with a generated gateway token (legacy value path)"
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
  log "  PRETORIN_API_KEY is empty. Add a key to .env before onboarding."
fi

# --- 2b. secret files (file-secret path only) ------------------------------
# init-file-secrets.sh is write-if-absent and generates the gateway token when it
# is empty, so running it here is what makes the documented Quickstart actually
# complete: the operator is left with files to paste values into rather than a
# deployment that exits 1 on the first `up`.
if [ "$FILE_SECRETS" = 1 ]; then
  log "preparing secret files (never overwrites an existing value)"
  bash "${REPO_ROOT}/scripts/init-file-secrets.sh" 2>&1 | sed 's/^/  /' ||     die "init-file-secrets.sh failed; see the output above."

  SECRET_DIR="${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}"
  # Report what still needs a value, by name. A silent empty file becomes a
  # provider auth error three steps later, which is the worst place to learn it.
  NEEDS_VALUE=()
  for required in pretorin-api-key; do
    [ -s "${SECRET_DIR}/${required}" ] || NEEDS_VALUE+=("${required}")
  done
  if [ ! -s "${SECRET_DIR}/openai-api-key" ] && [ ! -s "${SECRET_DIR}/anthropic-api-key" ]; then
    NEEDS_VALUE+=("openai-api-key OR anthropic-api-key (exactly one)")
  fi
  if [ "${#NEEDS_VALUE[@]}" -gt 0 ]; then
    log "  still empty, and needed before an agent turn:"
    for n in "${NEEDS_VALUE[@]}"; do log "    ${SECRET_DIR}/${n}"; done
  fi
  grep -qE '^[0-9a-f]{64}$' "${SECRET_DIR}/openclaw-gateway-token" 2>/dev/null \
    || warn "${SECRET_DIR}/openclaw-gateway-token has no usable token; the gateway will exit 1."
fi

# --- 3. targets ------------------------------------------------------------
#
# THE CLONE/UPDATE LOGIC IS NOT HERE ANY MORE. It lives in
# scripts/sync-targets.sh, which is the single implementation shared with the
# Slack /target-sync command and the target_sync agent tool. One definition of
# "safe" — fast-forward only, never reset, never discard, refuse and report —
# instead of two that drift, and its --self-test drives those same functions.
#
# What stays here is the part that is HOST-ONLY by design: deciding which git
# credential exists, and minting the GitHub App installation token.

mkdir -p "$TARGETS_DIR"

# Private targets need one installation token covering all of them, minted once
# before anything is cloned. Collected in a first pass so a missing credential is
# reported before the first clone rather than halfway through.
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

# Prefer the process environment, fall back to .env. Deliberately NOT `source
# .env`: that file is operator-editable and sourcing it would execute whatever it
# contains. Same helper, same reasoning, as scripts/github-app-token.sh.
env_val() {
  local name="$1" val
  eval "val=\${${name}:-}"
  if [ -z "$val" ] && [ -r .env ]; then
    val="$(grep -E "^${name}=" .env | head -1 | cut -d= -f2- | tr -d '\r' || true)"
  fi
  printf '%s' "$val"
}

# THE CREDENTIAL LADDER, AND THE ONE RUNG THAT MUST NOT EXIST.
#
#   public target                 -> anonymous. No credential is consulted at all.
#   private + GitHub App          -> mint an installation token. IF THAT FAILS,
#                                    STOP. There is deliberately no fall-through
#                                    to the PAT: an operator who configured an App
#                                    expects the App, and quietly using a
#                                    longer-lived personal credential instead is
#                                    exactly the kind of downgrade nobody notices.
#   private + no App + a PAT      -> use the PAT. Pilot-acceptable, and said out
#                                    loud on every run so it cannot become the
#                                    silent default.
#   private + neither             -> refuse, naming both fixes.
GIT_TOKEN_FILE=""
GIT_TOKEN_SOURCE="none"
PAT_FILE="${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}/github-readonly-pat"

if [ "${#PRIVATE_SLUGS[@]}" -gt 0 ]; then
  log "${#PRIVATE_SLUGS[@]} private target(s): ${PRIVATE_SLUGS[*]}"
  if [ -n "$(env_val GITHUB_APP_ID)" ]; then
    log "  private credential: GitHub App (the recommended mechanism)"
    GH_TOKEN_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-gh-token.XXXXXX")"
    chmod 600 "$GH_TOKEN_FILE"
    # Fails closed with its own diagnostics: missing App id, unreadable key,
    # repository not in the installation, permission never granted.
    bash scripts/github-app-token.sh "$GH_TOKEN_FILE" "${PRIVATE_SLUGS[@]}" \
      || die "could not mint a GitHub App token for the private target(s).
  Nothing was cloned. See the messages above, or README.md ('Private repositories').
  GITHUB_APP_ID is set, so this script will NOT fall back to the PAT: fix the App,
  or clear GITHUB_APP_ID if you deliberately want the PAT path."
    GIT_TOKEN_FILE="$GH_TOKEN_FILE"
    GIT_TOKEN_SOURCE="github-app"
  elif [ -s "$PAT_FILE" ]; then
    GIT_TOKEN_FILE="$PAT_FILE"
    GIT_TOKEN_SOURCE="pat"
    log "  private credential: fine-grained PAT from ${PAT_FILE}"
    warn "no GitHub App is configured, so the PAT is being used to clone private targets."
    warn "  Acceptable for the internal pilot. It must be fine-grained, limited to the"
    warn "  selected repositories, and carry Contents: Read-only and nothing else."
    warn "  The GitHub App is the recommended mechanism — README.md ('Private repositories')."
  else
    die "a private target is declared but no git credential is configured.
  Nothing was cloned. Pick one:
    - GitHub App (recommended): set GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY_FILE
      in .env. See README.md ('Private repositories').
    - Fine-grained PAT (internal pilot): put a selected-repositories,
      Contents: Read-only token in ${PAT_FILE}
      (create the file with scripts/init-file-secrets.sh, then paste the value).
    - Or drop 'private: true' from targets.yaml if the repository is public."
  fi
fi

# One implementation, invoked with explicit configuration rather than inherited
# globals, so the same call is readable from here and from the image.
if ! TARGET_COUNT="$(
      CC_TARGETS_FILE="$TARGETS_FILE" \
      CC_TARGETS_DIR="$TARGETS_DIR" \
      CC_PARSE_TARGETS="$PARSE" \
      CC_GIT_TOKEN_FILE="$GIT_TOKEN_FILE" \
      CC_GIT_TOKEN_SOURCE="$GIT_TOKEN_SOURCE" \
      CC_SYNC_REQUESTER="host:$(id -un 2>/dev/null || echo unknown)" \
      CC_SYNC_ROUTE="bootstrap" \
      bash scripts/sync-targets.sh --bootstrap )"; then
  die "could not prepare the target repositories; see the messages above."
fi

[ "${TARGET_COUNT:-0}" -gt 0 ] 2>/dev/null \
  || die "no targets parsed from ${TARGETS_FILE}."
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
  # What the image will report as its own version. A local build is NOT a
  # release and must never claim to be one: it says 0.0.0-dev, plus the commit
  # it came from when there is one to name. Outside a git checkout the plain
  # default in compose.build.yaml applies.
  if SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null)"; then
    export IMAGE_SELF_VERSION="0.0.0-dev+${SHORT_SHA}"
    log "  image self-version: ${IMAGE_SELF_VERSION}"
  fi
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

SECRET_DIR="${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}"
if [ "$FILE_SECRETS" = 1 ]; then
  NEXT_STEPS="  1. paste values into the secret files (nothing secret goes in .env):
       ${SECRET_DIR}/pretorin-api-key
       ${SECRET_DIR}/openai-api-key   OR   ${SECRET_DIR}/anthropic-api-key
     The gateway token was generated for you. Checklist: docs/file-secrets.md
  2. scripts/onboard-targets.sh                 # register targets with Pretorin
  3. docker compose up -d                       # gateway on http://127.0.0.1:18789"
  SLACK_HINT="in ${SECRET_DIR}/slack-app-token and slack-bot-token, plus SLACK_CHANNEL_ID in .env,"
else
  NEXT_STEPS="  1. put a PRETORIN_API_KEY in .env             (see .env.example)
     A read-only key is sufficient for everything here; a write-enabled key is
     also supported. The key's own scopes decide, not any setting in this repo.
  2. scripts/onboard-targets.sh                 # register targets with Pretorin
  3. docker compose up -d                       # gateway on http://127.0.0.1:18789

  This is the LEGACY credential path: values in .env reach \`docker inspect\`. The
  recommended path mounts them as files instead —
    export COMPOSE_FILE=compose.yaml:compose.secrets.yaml
    scripts/init-file-secrets.sh    # migrates what is already in .env
  See docs/file-secrets.md."
  SLACK_HINT="and SLACK_CHANNEL_ID in .env,"
fi

cat <<EOF

bootstrap: done.
  targets:   ${TARGET_COUNT} under ${TARGETS_DIR} (bind-mounted read-only at /workspace/targets)$([ "${#PRIVATE_SLUGS[@]}" -gt 0 ] && printf '\n             %s private, cloned with a read-only GitHub App token that\n             stayed on this host and has been deleted' "${#PRIVATE_SLUGS[@]}")
  scope:     ${SYSTEM_ID} / ${FRAMEWORK_ID}
  image:     $([ "$DO_BUILD" = 1 ] && echo 'built locally (compose.build.yaml)' || echo "pulled ${IMAGE_REF:-}")

Next:
${NEXT_STEPS}

Slack is optional. To have the agent answer in a Slack channel, import
slack/app-manifest.json at api.slack.com/apps/new, then supply the two tokens
${SLACK_HINT} BEFORE the first \`up\` — the
config is seeded once and never overwritten. See README.md ('Slack').
EOF
