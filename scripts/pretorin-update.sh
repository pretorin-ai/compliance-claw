#!/usr/bin/env bash
# pretorin-update.sh — move THIS DEPLOYMENT's Pretorin CLI, from the host.
#
#   scripts/pretorin-update.sh                 # what is installed, and the last update
#   scripts/pretorin-update.sh latest          # update to the latest stable release
#   scripts/pretorin-update.sh 0.28.7          # update to exactly that version
#   scripts/pretorin-update.sh --dry-run       # say what would happen, change nothing
#   scripts/pretorin-update.sh --self-test     # offline check of the input rules
#
# WHAT THIS IS NOT. This does NOT update the image. `scripts/update.sh` does
# that, and since the CLI moved into the pretorin-state volume, update.sh no
# longer moves the CLI. The two are separate on purpose and each names the other.
#
# WHY `run --rm cli` AND NOT `exec openclaw`. The pretorin-state volume is
# mounted on BOTH services, so this works with no gateway running at all — which
# is the case that matters, because a gateway that will not start is exactly when
# you need to change the CLI. (README's "exec openclaw, not run --rm cli" rule is
# about AGENT TURNS, which need the gateway's loopback. This needs no gateway.)
set -euo pipefail

log()  { printf 'pretorin-update: %s\n' "$*" >&2; }
warn() { printf 'pretorin-update: WARNING — %s\n' "$*" >&2; }
die()  { printf 'pretorin-update: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

[ -f compose.yaml ] || die "run this from the repository (compose.yaml not found)."
command -v docker >/dev/null 2>&1 || die "docker is required and missing."

IN_IMAGE="/opt/compliance-claw/pretorin-update.sh"

# Pass the argument list through untouched. The in-image script is the single
# authority on what a valid version is, so there is nothing to validate twice —
# and a second, drifting validator here is exactly what that rule avoids.
run_in_container() { docker compose run --rm -T cli "$IN_IMAGE" "$@"; }

# --- read-only and offline modes go straight through ------------------------
case "${1-}" in
  --self-test|--status|--dry-run|"")
    run_in_container "$@"
    exit $?
    ;;
esac

# --- the update ------------------------------------------------------------
# Capture stdout so the resulting version can drive activation; stderr stays on
# the terminal so the operator sees progress and the audit line as they happen.
set +e
OUT="$(run_in_container "$@")"
RC=$?
set -e
[ -n "$OUT" ] && printf '%s\n' "$OUT"

if [ "$RC" -ne 0 ]; then
  die "the update did not succeed (exit ${RC}). Nothing was activated."
fi

NEW_VERSION="$(printf '%s' "$OUT" | awk -F= '/^ACTIVE_VERSION=/{print $2; exit}')"
[ -n "$NEW_VERSION" ] || die "could not read the resulting version. Nothing was activated."

# --- activation ------------------------------------------------------------
# Replacing the file is not the deliverable. The CLI swaps the binary by rename,
# so any RUNNING `pretorin mcp-serve` child keeps the old inode — the CLI says so
# itself. OpenClaw caches that child and keys the cache on the config object,
# never on the file, so without a recycle it serves the old CLI until the ~10
# minute idle TTL expires. Restarting the gateway is what completes the update.
if ! docker compose ps --status running --services 2>/dev/null | grep -qx openclaw; then
  log "the gateway is not running, so there is nothing to recycle."
  log "${NEW_VERSION} is installed and will be used the next time it starts."
  exit 0
fi

log "activating ${NEW_VERSION}: restarting the gateway so MCP picks it up"
docker compose restart openclaw

# Probe, rather than assume. The observable comes free from the atomic-rename
# behaviour: a child still running the replaced binary has a /proc/<pid>/exe
# that reads "(deleted)". After a restart there must be none.
STALE="$(docker compose exec -T openclaw sh -c '
  found=0
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    if tr "\0" " " < "$d/cmdline" 2>/dev/null | grep -q "pretorin mcp-serve"; then
      exe="$(readlink "$d/exe" 2>/dev/null || true)"
      case "$exe" in *"(deleted)"*) echo "$d $exe"; found=1 ;; esac
    fi
  done
  exit 0
' 2>/dev/null || true)"

if [ -n "$STALE" ]; then
  warn "an MCP child is still running the replaced binary after the restart:"
  printf '%s\n' "$STALE" >&2
  warn "run 'docker compose restart openclaw' again, or check 'docker compose logs openclaw'."
  exit 1
fi

log "active: ${NEW_VERSION}. No MCP child is running a replaced binary."
log "the image was NOT changed. To move the image, use scripts/update.sh."
