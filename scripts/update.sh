#!/usr/bin/env bash
#
# update.sh — move an EXISTING deployment to the release this checkout pins.
#
#   1. fast-forward the checkout        (git pull --ff-only)
#   2. pull the pinned image            (docker compose pull)
#   3. restart the gateway on it        (docker compose up -d)
#   4. report what the operator has to know, and change nothing else
#
#   scripts/update.sh
#
# Idempotent: a second run pulls nothing, recreates nothing, and says so.
#
# WHAT THIS IS NOT. It never runs `down -v`, never edits a config in the state
# volume, and never touches .env or workspace/targets. An update replaces the
# IMAGE; the volumes and everything in them — your model login, the seeded
# config, sessions, the agent workspace, Pretorin's active context and bound
# resolvers — survive untouched. That is also why a template fix in a new image
# does NOT reach a volume that already has a config: see the drift report below.
#
# It refuses rather than guesses. A dirty tree, a diverged branch or a checkout
# with no upstream are all states where "update" means something the script
# cannot decide for you, so it names the problem and the exact command.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf 'update: %s\n' "$*"; }
warn() { printf 'update: WARNING — %s\n' "$*" >&2; }
die()  { printf 'update: ERROR — %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument '${arg}'. This script takes no options." ;;
  esac
done

# ---------------------------------------------------------------------------
# Refusals, before anything is changed.
# ---------------------------------------------------------------------------

# The build overlay and this script want opposite things: it deploys an image
# built from local source, and `docker compose pull` on `compliance-claw:local`
# can only fail. An operator in the dev loop wants a rebuild, not an update.
case "${COMPOSE_FILE:-}" in
  *compose.build.yaml*)
    die "COMPOSE_FILE selects the local build overlay, so there is nothing to pull.

  This script updates a deployment that runs the PUBLISHED image. To rebuild
  from local source instead:

    docker compose build && docker compose up -d

  To switch this shell back to the published image:  unset COMPOSE_FILE"
    ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git checkout, so there is nothing to fast-forward.

  Update the image by hand instead:  docker compose pull && docker compose up -d"

if [ -n "$(git status --porcelain)" ]; then
  die "the working tree has uncommitted changes, and a fast-forward would fail.

  Review them:  git status
  Then either commit them, or:  git stash"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" != "HEAD" ] \
  || die "the checkout is in detached HEAD state, so there is no branch to pull.

  Pick the branch that carries the release you want:  git checkout master"

UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
[ -n "$UPSTREAM" ] \
  || die "branch '${BRANCH}' has no upstream, so there is nothing to pull from.

  Set one:  git branch --set-upstream-to=origin/${BRANCH} ${BRANCH}"

log "fetching ${UPSTREAM}"
git fetch --quiet "${UPSTREAM%%/*}" || die "could not fetch from ${UPSTREAM%%/*}."

# Diverged means local commits the remote does not have. --ff-only would fail
# with git's own message; this one names the branch and the choice.
BEHIND_AHEAD="$(git rev-list --left-right --count "${UPSTREAM}...HEAD")"
AHEAD="$(printf '%s' "$BEHIND_AHEAD" | awk '{print $2}')"
BEHIND="$(printf '%s' "$BEHIND_AHEAD" | awk '{print $1}')"

if [ "$AHEAD" -gt 0 ]; then
  die "branch '${BRANCH}' has ${AHEAD} commit(s) that ${UPSTREAM} does not, so it
  cannot be fast-forwarded.

  Inspect them:  git log --oneline ${UPSTREAM}..HEAD
  Then rebase:   git pull --rebase
  Or update from a clean branch:  git checkout master && scripts/update.sh"
fi

# ---------------------------------------------------------------------------
# The update itself.
# ---------------------------------------------------------------------------

if [ "$BEHIND" -gt 0 ]; then
  log "fast-forwarding ${BRANCH} by ${BEHIND} commit(s)"

  # THIS SCRIPT IS ONE OF THE FILES THE MERGE CAN REWRITE, and bash reads a
  # script lazily — it keeps a byte offset into the file and reads more as it
  # goes. Replacing the file underneath a running bash makes it resume at that
  # offset in the NEW bytes, which is how a self-updating script ends up
  # executing a fragment of a line. Observed here: a widened excerpt did not take
  # effect until the following run, which is the harmless end of that spectrum.
  #
  # So: notice when the merge changed this file, and hand over to the new copy.
  # The guard makes a loop impossible — after the merge the branch is up to date,
  # so the re-executed copy takes the `already up to date` path and never gets
  # back here. Handing over is also the RIGHT semantic: a release that improves
  # the updater should be the one that performs the rest of this update.
  BEFORE="$(git rev-parse "HEAD:scripts/update.sh" 2>/dev/null || true)"
  git merge --ff-only --quiet "$UPSTREAM"
  AFTER="$(git rev-parse "HEAD:scripts/update.sh" 2>/dev/null || true)"

  if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ] && [ -z "${UPDATE_SH_REEXEC:-}" ]; then
    log "this update changed update.sh itself; continuing with the new copy"
    UPDATE_SH_REEXEC=1 exec bash "${REPO_ROOT}/scripts/update.sh" "$@"
  fi
else
  log "${BRANCH} is already up to date with ${UPSTREAM}"
fi

# Read from the one place versions are declared, so the message cannot name a
# version the deployment does not use.
IMAGE_REF="$(awk -F= '/^IMAGE_REPO=/{r=$2} /^IMAGE_VERSION=/{v=$2} END{print r":"v}' versions.env)"
log "this checkout pins ${IMAGE_REF}"

log "pulling the pinned image"
docker compose pull --quiet 2>/dev/null || docker compose pull || die \
  "could not pull ${IMAGE_REF}.

  The package is not public, so the pull needs a login:  docker login ghcr.io
  A classic token needs the read:packages scope."

log "starting the gateway on it"
docker compose up -d

# ---------------------------------------------------------------------------
# Report. Nothing below this line changes anything.
# ---------------------------------------------------------------------------

# The container itself is the authority on config drift, and it already computes
# this on every start. Re-running the entrypoint through the one-shot `cli`
# service surfaces the same warning here rather than reimplementing the
# comparison — one source of truth, and it cannot drift from the entrypoint's.
STARTUP="$(docker compose run --rm -T cli true 2>&1 || true)"

printf '\n'
if printf '%s' "$STARTUP" | grep -q 'predates the image'; then
  warn "this volume's config predates the image you just pulled."
  printf '%s\n' "$STARTUP" | grep -A15 'predates the image' | sed 's/^/  /'
  cat >&2 <<'DRIFT'

  NOTHING WAS OVERWRITTEN, and this script will not edit a config. Templates are
  seeded write-if-absent, so the config already in the volume stays authoritative
  and the new image's template fixes are not active. Two ways out:

    merge by hand — diff your config against the template shipped in the image:
      docker compose run --rm cli cat /opt/compliance-claw/openclaw-config.template.json
      docker compose run --rm cli cat /home/node/.openclaw/openclaw.json
    then record that you have merged it:
      docker compose run --rm cli bash -c \
        'cat /opt/compliance-claw/config-template.version > /home/node/.openclaw/.compliance-claw-templates'

    or reset — DESTROYS both volumes, including your model login:
      docker compose down -v && scripts/bootstrap.sh && scripts/onboard-targets.sh
DRIFT
elif printf '%s' "$STARTUP" | grep -q 'Slack is configured in .env but NOT'; then
  warn "Slack is configured in .env but absent from this volume's config."
  printf '%s\n' "$STARTUP" | grep -A10 'Slack is configured in .env but NOT' | sed 's/^/  /'
else
  log "the volume's config is current with this image."
fi

printf '\n'
log "onboarding was NOT touched. Bound sources, the active context and the recipe"
log "set live in the Pretorin state volume and survive an update like this one."
log "Re-run scripts/onboard-targets.sh only after 'down -v', or when targets.yaml"
log "changes — it is idempotent either way."
printf '\n'
log "done. Check it came up:  docker compose ps"
log "and that the version is what you expect:"
log "  docker compose run --rm cli cat /opt/compliance-claw/versions.env | grep IMAGE_VERSION"
