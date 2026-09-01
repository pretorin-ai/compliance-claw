#!/usr/bin/env bash
#
# onboard-targets.sh — register every target in targets.yaml with Pretorin as a
# host-local source resolver, then verify and provision the scope.
#
#   scripts/onboard-targets.sh                 # full onboarding (needs a key)
#   scripts/onboard-targets.sh --verify-only   # assert only, read-only, no writes
#   scripts/onboard-targets.sh --local-only    # skip the platform steps (CI/no key)
#
# THIS IS THE LEGACY SINGLE-EFFORT PATH, AND IT IS UNCHANGED ON PURPOSE.
# targets.yaml stays runtime-authoritative for this release; the effort-aware
# path is `scripts/clawctl apply`, which drives the SAME sequence from
# scripts/onboard-lib.sh with per-effort environment pinning and no `context
# set`. One definition of the sequence, two callers — see onboard-lib.sh for the
# sweep-then-bind ordering and why it is load-bearing.
#
# Runs on the host and drives the `cli` compose service, echoing every command it
# issues so the sequence is auditable rather than magic. All state it writes is
# host-local Pretorin state in the pretorin-state volume; nothing is written to
# the Pretorin platform, so a READ-ONLY API key is sufficient and is the
# documented default.
#
#   1. whoami            fail fast if the key cannot authenticate
#   2. context set       active scope (platform read)
#   3-7. sweep, bind, verify, provision, assert   -> scripts/onboard-lib.sh
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGETS_FILE="${TARGETS_FILE:-targets.yaml}"
PARSE="scripts/parse-targets.py"

LOCAL_ONLY=0
VERIFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --local-only)  LOCAL_ONLY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'onboard: ERROR — unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# The sequence, the command renderer and the artifact analysis all live here.
# shellcheck source=scripts/onboard-lib.sh
. "${REPO_ROOT}/scripts/onboard-lib.sh"

log()  { ol_log "$@"; }
warn() { ol_warn "$@"; }
die()  { ol_die "$@"; }

# Every Pretorin invocation goes through the same one-off container as the
# operator's own `docker compose run --rm cli ...`, so what this script does is
# reproducible by hand. -T because there is no TTY in CI and because Pretorin's
# boxed output is noise when the caller is a script.
pcli()       { ol_pcli "$@"; }
pcli_quiet() { ol_pcli_quiet "$@"; }

# --- scope + targets -------------------------------------------------------

[ -f "$TARGETS_FILE" ] || die "${TARGETS_FILE} not found."
IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID < <(python3 "$PARSE" scope "$TARGETS_FILE")
TARGET_NAMES=()
while IFS=$'\t' read -r NAME _URL _PRIVATE _REF; do
  [ -n "$NAME" ] && TARGET_NAMES+=("$NAME")
done < <(python3 "$PARSE" list "$TARGETS_FILE")
[ "${#TARGET_NAMES[@]}" -gt 0 ] || die "no targets in ${TARGETS_FILE}."

# Hand the shared sequence its configuration. OL_RUN_ENV is EMPTY on this path:
# the legacy deployment supplies its single credential through compose, and its
# scope through the stored context set below.
OL_SYSTEM_ID="$SYSTEM_ID"
OL_FRAMEWORK_ID="$FRAMEWORK_ID"
OL_TARGETS=("${TARGET_NAMES[@]}")
OL_LABEL="$TARGETS_FILE"
OL_RUN_ENV=()
OL_DRY_RUN=0

SCOPE=(--system "$SYSTEM_ID" --framework "$FRAMEWORK_ID")
log "scope: system=${SYSTEM_ID} framework=${FRAMEWORK_ID}"
log "targets: ${TARGET_NAMES[*]}"

# The clones have to exist before anything is bound, or verify probes a path that
# is not there and every resolver comes back unreachable.
for name in "${TARGET_NAMES[@]}"; do
  [ -d "workspace/targets/${name}/.git" ] \
    || die "workspace/targets/${name} is not a git clone. Run scripts/bootstrap.sh first."
done

# --- 7 (standalone). --verify-only ----------------------------------------

assert_state() {
  ol_assert || die "preflight state does not match ${TARGETS_FILE}."
}

if [ "$VERIFY_ONLY" = 1 ]; then
  assert_state
  exit 0
fi

# --- 1. whoami -------------------------------------------------------------

if [ "$LOCAL_ONLY" = 1 ]; then
  log "--local-only: skipping the platform steps (no active context, no platform"
  log "  source profile). Resolver binding, verification and provisioning are all"
  log "  host-local and need no key."
else
  AUTHED="$(pcli_quiet --json whoami | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authenticated"))' 2>/dev/null || echo False)"
  [ "$AUTHED" = "True" ] || die "Pretorin says not authenticated.
  Supply a valid Pretorin API key by whichever path this deployment uses:
    recommended   a value in secrets/runtime/pretorin-api-key, with
                  compose.secrets.yaml in COMPOSE_FILE (see docs/file-secrets.md)
    legacy        PRETORIN_API_KEY=... in .env
  Supplying it BOTH ways is refused, so pick one. A read-only key is sufficient
  for onboarding; a write-enabled key also works, because the key's own scopes
  decide what is permitted and nothing here filters on top of them.
  Or run with --local-only to bind resolvers without touching the platform."
  log "authenticated"

  # --- 2. active context -------------------------------------------------
  # Every command below passes --system/--framework explicitly, so this step is
  # not what makes onboarding work: it is what makes the AGENT work on THIS path.
  # check_context and start_task read the active scope from local config, so
  # without this the agent has no idea which system it is reviewing for.
  #
  # THE EFFORT PATH DOES NOT DO THIS, AND MUST NOT. Stored context is a single
  # global, so it cannot describe more than one effort; `clawctl` pins scope per
  # process with PRETORIN_SYSTEM_ID / PRETORIN_FRAMEWORK_ID instead, which
  # override it. Measured against CLI 0.28.7 — see docs/plans/effort-config.md,
  # evidence row #1.
  pcli context set --system "$SYSTEM_ID" --framework "$FRAMEWORK_ID" --no-verify
  ACTIVE="$(pcli_quiet --json context show | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s" % (d.get("active_system_id"), d.get("active_framework_id"), d.get("valid")))')"
  [ "$ACTIVE" = "${SYSTEM_ID}|${FRAMEWORK_ID}|True" ] \
    || die "active context is '${ACTIVE}', expected '${SYSTEM_ID}|${FRAMEWORK_ID}|True'."
  log "active context set and valid"
fi

# --- 3-6. the shared sequence ---------------------------------------------

ol_sweep
ol_bind
ol_verify
ol_provision

# --- 7. assert -------------------------------------------------------------

assert_state

cat <<EOF

onboard: done.
  scope:    ${SYSTEM_ID} / ${FRAMEWORK_ID}
  targets:  ${TARGET_NAMES[*]}

If the gateway is already running, its live sessions may still hold the previous
view (the preflight artifact carries a 3600s TTL and each session keeps its own
pretorin mcp-serve child, reaped after mcp.sessionIdleTtlMs = 10 min):
  docker compose restart openclaw

(Not \`openclaw mcp reload\` from the cli service: it only disposes the calling
process's own cached runtimes, so it cannot touch the gateway's children.)
EOF
