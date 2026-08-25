#!/usr/bin/env bash
# pretorin-update.sh — move THIS DEPLOYMENT's Pretorin CLI, in place.
#
# Baked into the image at /opt/compliance-claw/pretorin-update.sh. Three callers,
# one implementation, so the locking, backup, verification, rollback, sanitized
# environment and audit trail exist exactly once:
#
#   1. the /pretorin-update Slack command  (bypasses the LLM entirely)
#   2. the pretorin_update agent tool      (model-visible, narrowly typed)
#   3. scripts/pretorin-update.sh          (the operator, on the host)
#
# WHAT THIS DOES NOT DO. It never touches the image, the OpenClaw config, .env,
# workspace/targets, or the seed. To move the IMAGE, use scripts/update.sh —
# which no longer moves the CLI, because the CLI now lives in a volume.
#
# THE TRUST ROOT, STATED PLAINLY. This script downloads and verifies nothing
# itself. It delegates to the CLI's own signed `pretorin update`, whose signature
# verification is what stands behind the new bytes. PRETORIN_SHA256 in
# versions.env governs the SEED only. See SECURITY.md.
set -euo pipefail

# --- paths (absolute, always) ----------------------------------------------
# Never a bare `pretorin`. PATH puts the active directory first, which is
# correct for everyone else, but this script is the one place that must be able
# to talk about the seed and the active binary in the same breath — so it names
# both explicitly and lets PATH resolve neither.
SEED="/opt/compliance-claw/pretorin-seed/pretorin"
STATE="/home/node/.pretorin"
ACTIVE_DIR="${STATE}/bin"
ACTIVE="${ACTIVE_DIR}/pretorin"
BACKUP="${ACTIVE_DIR}/pretorin.backup"
LOCK="${STATE}/.update.lock"
MARKER="${STATE}/.update-in-progress"
AUDIT="${STATE}/update-audit.log"

# How long the CLI gets before we call it hung. flock releases on process death,
# but a process stalled on a network read never dies — and without this, one
# stall refuses every future update for the life of the container.
UPDATE_TIMEOUT="${PRETORIN_UPDATE_TIMEOUT:-300}"

# --- sanitized environment --------------------------------------------------
# Re-exec under a minimal env so `pretorin update` cannot see a single
# credential. Done HERE, once, rather than at the three call sites, because a
# call site is a place to forget and only one of them would ever be tested.
#
# The allowlist is deliberately short. PRETORIN_UPDATE_REQUESTER/ROUTE are
# identity metadata the CALLER supplies out of band; they are not secrets, and
# nothing in the argument surface can set them.
if [ "${PRETORIN_UPDATE_SANITIZED:-}" != "1" ]; then
  exec env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="/home/node" \
    TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-C.UTF-8}" \
    PRETORIN_UPDATE_SANITIZED=1 \
    PRETORIN_UPDATE_TIMEOUT="$UPDATE_TIMEOUT" \
    PRETORIN_UPDATE_REQUESTER="${PRETORIN_UPDATE_REQUESTER:-unavailable}" \
    PRETORIN_UPDATE_ROUTE="${PRETORIN_UPDATE_ROUTE:-unknown}" \
    bash "$0" "$@"
fi

REQUESTER="${PRETORIN_UPDATE_REQUESTER:-unavailable}"
ROUTE="${PRETORIN_UPDATE_ROUTE:-unknown}"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

# --- small helpers ---------------------------------------------------------
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# `pretorin version` prints "pretorin version X.Y.Z" on its first line. Returns
# empty (not an error) when the binary is missing or will not run, because every
# caller here wants to distinguish "no version" from "a version".
version_of() {
  local bin="$1"
  [ -s "$bin" ] && [ -x "$bin" ] || return 0
  "$bin" version 2>/dev/null | awk 'NR==1 && $1=="pretorin" && $2=="version" {print $3; exit}'
}

sha_of() {
  local f="$1"
  [ -s "$f" ] || return 0
  sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

# One audit line per invocation, and it goes to TWO places on purpose.
#
# The file is the operator's trail. Stderr is the copy that survives the threat
# model this feature actually has: the agent runs as `node` with unsandboxed
# exec and can rewrite anything under ${STATE}, so a file it can edit is not
# evidence on its own. Stderr is inherited from the Gateway, so on the plugin
# routes the line lands in `docker compose logs`, outside the volume and outside
# the agent's reach. On the operator route it lands in the operator's terminal —
# `docker logs` only shows PID 1's streams — which the README says rather than
# implying the log copy is universal.
#
# Never fatal: losing the audit line must not turn a completed update into a
# failure, and must never abort a container start.
audit() {
  local outcome="$1" requested="$2" normalized="$3" previous="$4" resulting="$5"
  local line
  line="$(printf 'v=1 ts=%s requested=%s normalized=%s previous=%s resulting=%s outcome=%s requester=%s route=%s' \
    "$(now_utc)" "${requested:--}" "${normalized:--}" "${previous:--}" "${resulting:--}" \
    "$outcome" "$REQUESTER" "$ROUTE")"
  printf '%s\n' "$line" >&2
  { umask 077; printf '%s\n' "$line" >> "$AUDIT"; } 2>/dev/null || \
    log "pretorin-update: WARNING — could not append to ${AUDIT}; the line above is the only copy."
}

# --- input classification (pure, offline, self-tested) ---------------------
# Prints "<mode> <normalized>" or fails. This is the SINGLE authority on what a
# valid version is: the plugin's tool schema is a plain string and the command
# passes its argument through untouched, so there is one definition to keep
# right instead of three that drift.
#
# `latest` maps to the EMPTY normalized value on purpose: the CLI refuses the
# literal string "latest" ("not an installable version"), while `pretorin
# update` with NO argument already means install-the-latest-stable and does its
# own release selection, signature verification, no-downgrade and prerelease
# exclusion. Passing nothing is both simpler and stricter than resolving a
# version ourselves.
classify_input() {
  local raw="${1-}" norm
  case "$raw" in
    latest)
      printf 'latest \n'
      return 0 ;;
    v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*)
      # Character allowlist FIRST. A shell glob is not an anchored pattern, and
      # `grep -E '^...$'` matches per LINE — so "0.28.7\n0.28.8" would sail
      # through a structure check alone by virtue of its first line. Found by
      # --self-test, which is the whole reason it exists.
      case "$raw" in *[!0-9.v]*) return 1 ;; esac
      norm="${raw#v}"
      printf '%s' "$norm" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || return 1
      printf 'exact %s\n' "$norm"
      return 0 ;;
    *)
      return 1 ;;
  esac
}

refuse_input() {
  local raw="${1-}" cur
  cur="$(version_of "$ACTIVE")"
  log "pretorin-update: refusing \"${raw}\" — not a version."
  log "  Accepted: latest, or X.Y.Z (a leading v is accepted and stripped)."
  log "  Prereleases such as 0.29.0-rc2 are refused on purpose: an unattended,"
  log "  Slack-triggered update on a shared instance is the wrong place for one."
  log "  Nothing was downloaded; the active binary is untouched (${cur:-none})."
  audit refused_input "${raw:-<empty>}" "" "${cur}" "${cur}"
  exit 2
}

usage() {
  cat >&2 <<'USAGE'
usage: pretorin-update.sh [latest | X.Y.Z | vX.Y.Z | --status | --dry-run [target] | --self-test]

  latest        update to the latest stable release (the CLI selects it)
  X.Y.Z         update to exactly that version
  --status      what is installed, what the image seeds, and the last audit record
  --dry-run     say what would happen; change nothing
  --self-test   offline validation of the input rules; no network, no credentials

  With no argument this prints status and this message. It never updates.
USAGE
}

# --- status ----------------------------------------------------------------
# Answers the question an operator actually has after this feature ships:
# "what am I running, and is it what the image shipped?"
#
# Compares sha256 as well as version. A version comparison alone cannot see a
# same-version swap, and a same-version swap is exactly what an agent with exec
# could do — the audit file cannot be trusted to record that, so at least make
# it visible here.
show_status() {
  local av as sv ss lock_note=""
  av="$(version_of "$ACTIVE")"; as="$(sha_of "$ACTIVE")"
  sv="$(version_of "$SEED")";   ss="$(sha_of "$SEED")"

  printf 'active  %s  %s  %s\n' "${av:-<none>}" "${as:-<none>}" "$ACTIVE"
  printf 'seed    %s  %s  %s\n' "${sv:-<none>}" "${ss:-<none>}" "$SEED"
  if [ -n "$av" ] && [ -n "$sv" ]; then
    if [ "$av" = "$sv" ] && [ "$as" = "$ss" ]; then
      printf 'state   active binary is the image seed, unmodified\n'
    elif [ "$av" = "$sv" ]; then
      printf 'state   SAME VERSION AS THE SEED BUT DIFFERENT BYTES — investigate\n'
    else
      printf 'state   updated away from the seed (expected after a CLI update)\n'
    fi
  fi

  # A lock whose holder is gone is the one state that looks like a live update
  # and is not. Report it here rather than making an operator guess why every
  # attempt is refused.
  if [ -e "$LOCK" ] && command -v flock >/dev/null 2>&1; then
    if flock -n "$LOCK" true 2>/dev/null; then
      lock_note="free"
    else
      lock_note="HELD by a live update"
    fi
    printf 'lock    %s\n' "$lock_note"
  fi
  [ -e "$MARKER" ] && printf 'marker  %s (an update was interrupted, or one is running)\n' "$(cat "$MARKER" 2>/dev/null || echo present)"

  if [ -s "$AUDIT" ]; then
    printf 'last    %s\n' "$(tail -1 "$AUDIT")"
  else
    printf 'last    (no update has been recorded on this deployment)\n'
  fi
}

# --- self-test -------------------------------------------------------------
# The input rules are pure, need no network and no credentials, and are exactly
# the kind of thing that rots silently — so CI drives them. Same shape as
# parse-targets.py --self-test, which smoke.sh already runs.
self_test() {
  local fails=0 got rc

  check_accept() { # <input> <expected-mode> <expected-normalized>
    local in="$1" want_mode="$2" want_norm="$3"
    if got="$(classify_input "$in" 2>/dev/null)"; then
      local m="${got%% *}" n="${got#* }"
      n="${n%$'\n'}"
      if [ "$m" = "$want_mode" ] && [ "$n" = "$want_norm" ]; then
        printf '  ok    accept %-16s -> %s %s\n' "$in" "$m" "${n:-<none>}"
      else
        printf '  FAIL  accept %-16s -> %s %s (wanted %s %s)\n' "$in" "$m" "$n" "$want_mode" "$want_norm"
        fails=$((fails+1))
      fi
    else
      printf '  FAIL  accept %-16s -> refused\n' "$in"
      fails=$((fails+1))
    fi
  }

  check_refuse() { # <input>
    local in="$1"
    if classify_input "$in" >/dev/null 2>&1; then
      printf '  FAIL  refuse %-16s -> accepted\n' "$in"
      fails=$((fails+1))
    else
      printf '  ok    refuse %-16s\n' "$in"
    fi
  }

  printf 'pretorin-update --self-test\n'
  check_accept 'latest'   latest ''
  check_accept '0.28.7'   exact  '0.28.7'
  check_accept 'v0.28.7'  exact  '0.28.7'
  check_accept '1.0.0'    exact  '1.0.0'
  check_accept '10.20.30' exact  '10.20.30'

  # Garbage, injection attempts, and the prerelease form the CLI would accept
  # but this pilot will not.
  check_refuse ''
  check_refuse 'latest2'
  check_refuse 'LATEST'
  check_refuse '1.2'
  check_refuse '0.28'
  check_refuse '0.28.7; id'
  check_refuse '0.28.7 && id'
  check_refuse '0.28.7|id'
  check_refuse '$(id)'
  check_refuse '../../bin/sh'
  check_refuse '/usr/local/bin/pretorin'
  check_refuse '--flag'
  check_refuse '-v'
  check_refuse 'https://example.com/x'
  check_refuse '0.29.0-rc2'
  check_refuse 'v0.29.0-rc2'
  check_refuse '0.28.7extra'
  check_refuse 'v'
  check_refuse '0.28.7
0.28.8'

  # The absolute-path invariant. PATH puts the active directory first, so a bare
  # `pretorin` in this script would silently operate on whichever binary PATH
  # happened to find — and with the seed off PATH and the active dir possibly
  # empty, "whichever" is not a thing we can reason about. Assert the file names
  # both binaries explicitly and never bare.
  local bare
  bare="$(grep -vE '^[[:space:]]*#' "$0" \
          | grep -nE '(^|[^-[:alnum:]_/."$])pretorin[[:space:]]+(version|update|mcp-smoke-test)' \
          | grep -vE 'pretorin-update' || true)"
  if [ -n "$bare" ]; then
    printf '  FAIL  absolute-path invariant: a bare `pretorin` invocation exists\n'
    printf '%s\n' "$bare"
    fails=$((fails+1))
  else
    printf '  ok    absolute-path invariant (no bare `pretorin` invocation)\n'
  fi

  if [ "$fails" -eq 0 ]; then
    printf 'self-test PASSED\n'
    return 0
  fi
  printf 'self-test FAILED (%d)\n' "$fails"
  return 1
}

# --- restore ---------------------------------------------------------------
# backup -> seed -> refuse. The seed is always present and supply-chain
# verified, which is what makes a total-loss state unreachable: even a corrupt
# backup leaves a known-good floor to stand on.
restore() {
  local why="$1"
  if [ -s "$BACKUP" ] && install -m 0755 "$BACKUP" "$ACTIVE" 2>/dev/null \
       && [ -n "$(version_of "$ACTIVE")" ]; then
    log "pretorin-update: restored the previous binary from backup (${why})."
    return 0
  fi
  log "pretorin-update: WARNING — the backup is unusable; falling back to the image seed."
  if [ -s "$SEED" ] && install -m 0755 "$SEED" "$ACTIVE" 2>/dev/null \
       && [ -n "$(version_of "$ACTIVE")" ]; then
    log "pretorin-update: restored the image seed $(version_of "$ACTIVE") (${why})."
    return 0
  fi
  log "pretorin-update: ERROR — neither the backup nor the seed could be restored."
  log "  The active binary at ${ACTIVE} may be unusable. Recover with:"
  log "    docker compose down && docker compose up -d     (re-seeds from the image)"
  return 1
}

# --- the update ------------------------------------------------------------
do_update() {
  local mode="$1" norm="$2" raw="$3" dry="$4"

  local prev prev_sha
  prev="$(version_of "$ACTIVE")"
  prev_sha="$(sha_of "$ACTIVE")"
  [ -n "$prev" ] || die "pretorin-update: no working CLI at ${ACTIVE}. Recreate the container to re-seed it."

  local target_desc
  if [ "$mode" = latest ]; then target_desc="the latest stable release"; else target_desc="$norm"; fi

  if [ "$dry" = 1 ]; then
    printf 'dry-run: would update %s -> %s\n' "$prev" "$target_desc"
    printf 'dry-run: nothing was downloaded, locked, backed up or changed\n'
    return 0
  fi

  # Backup FIRST, and verify it. An unverified backup is not a backup, and
  # disk-full during the copy is precisely the case rollback exists for — so it
  # aborts here, before the live binary has been touched at all.
  if ! install -m 0755 "$ACTIVE" "$BACKUP" 2>/dev/null; then
    log "pretorin-update: could not write the backup at ${BACKUP} — aborting."
    log "  The active binary is untouched (${prev}). Check free space in the volume."
    audit backup_failed "$raw" "$norm" "$prev" "$prev"
    exit 1
  fi
  if [ "$(sha_of "$BACKUP")" != "$prev_sha" ]; then
    log "pretorin-update: the backup does not match the active binary — aborting."
    log "  The active binary is untouched (${prev}). Check free space in the volume."
    audit backup_mismatch "$raw" "$norm" "$prev" "$prev"
    exit 1
  fi

  # The marker is what lets a killed update be recognised on the next container
  # start. It is written under the lock and cleared before the intentional
  # activation restart, so a restart we asked for never looks like a crash.
  printf 'started=%s requester=%s route=%s previous=%s\n' "$(now_utc)" "$REQUESTER" "$ROUTE" "$prev" > "$MARKER" 2>/dev/null || true

  log "pretorin-update: ${prev} -> ${target_desc}"

  # THE EXIT CODE IS NOT A SUCCESS SIGNAL. `pretorin update` exits 0 on every
  # refusal it knows how to describe ("not an installable version", "no release
  # manifest at vX.Y.Z"), so the only trustworthy answer is to ask the binary
  # afterwards what it is. Output is captured for the already-current case and
  # for the failure report; it is never parsed for success.
  local out rc=0
  if [ "$mode" = latest ]; then
    out="$(timeout "$UPDATE_TIMEOUT" "$ACTIVE" update 2>&1)" || rc=$?
  else
    out="$(timeout "$UPDATE_TIMEOUT" "$ACTIVE" update "$norm" 2>&1)" || rc=$?
  fi
  printf '%s\n' "$out" >&2

  if [ "$rc" -eq 124 ]; then
    log "pretorin-update: the CLI did not finish within ${UPDATE_TIMEOUT}s — treating it as hung."
    restore "timeout" || true
    rm -f "$MARKER" 2>/dev/null || true
    audit timeout "$raw" "$norm" "$prev" "$(version_of "$ACTIVE")"
    exit 1
  fi

  local now
  now="$(version_of "$ACTIVE")"

  local ok=0
  if [ "$mode" = exact ]; then
    # Exact means exact. Anything else — including a plausible-looking newer
    # version — is a failure, because the caller asked for a specific one.
    [ "$now" = "$norm" ] && ok=1
  else
    # latest: either the version moved, or the CLI said it was already current.
    if [ -n "$now" ]; then
      if [ "$now" != "$prev" ]; then
        ok=1
      elif printf '%s' "$out" | grep -qi 'already up to date'; then
        ok=1
      fi
    fi
  fi

  if [ "$ok" -ne 1 ]; then
    log "pretorin-update: the update did not take effect."
    log "  requested ${raw}   previous ${prev}   now ${now:-<unreadable>}"
    restore "verification failed" || true
    rm -f "$MARKER" 2>/dev/null || true
    audit rolled_back "$raw" "$norm" "$prev" "$(version_of "$ACTIVE")"
    exit 1
  fi

  # Liveness, both modes. Credential-free on purpose: this must work on a
  # deployment with no Pretorin key at all. It proves the binary runs and
  # self-describes its MCP surface; it does NOT prove that surface still matches
  # the deployed config, which is why it is called liveness and not health.
  if ! "$ACTIVE" mcp-smoke-test >/dev/null 2>&1; then
    log "pretorin-update: ${now} installed but failed its MCP liveness check."
    restore "liveness failed" || true
    rm -f "$MARKER" 2>/dev/null || true
    audit rolled_back "$raw" "$norm" "$prev" "$(version_of "$ACTIVE")"
    exit 1
  fi

  # The update is complete and verified. Clearing the marker here is what makes
  # the activation restart distinguishable from a crash.
  rm -f "$MARKER" 2>/dev/null || true

  if [ "$now" = "$prev" ]; then
    log "pretorin-update: already at ${now}; nothing changed."
    audit already_current "$raw" "$norm" "$prev" "$now"
  else
    log "pretorin-update: installed ${prev} -> ${now}."
    audit installed "$raw" "$norm" "$prev" "$now"
  fi

  # ACTIVATION IS NOT THIS SCRIPT'S JOB, AND SAYING SO MATTERS.
  #
  # The CLI replaces the file by rename, so a running `pretorin mcp-serve` child
  # keeps the old inode — the CLI says as much itself ("Already-running
  # processes keep the previous version until they restart"). OpenClaw caches
  # that child and keys the cache on the config object, never on the file, so it
  # will keep serving the old binary until it is recycled. The caller is what
  # recycles it: the plugin requests a gateway restart, and the host script runs
  # `docker compose restart openclaw`. Printing the manual step here means a
  # bare in-container invocation still tells the truth.
  printf 'ACTIVE_VERSION=%s\n' "$now"
  log "pretorin-update: the running MCP server keeps ${prev} until it is recycled."
  log "  Take effect now:  docker compose restart openclaw"
  log "  Or wait:          it is recycled automatically after ~10 min idle"
}

# --- main ------------------------------------------------------------------
main() {
  case "${1-}" in
    --self-test) self_test; exit $? ;;
  esac

  # Everything past here touches the volume, so it needs the state directory.
  [ -d "$STATE" ] || die "pretorin-update: ${STATE} is missing. Is the pretorin-state volume mounted?"

  local dry=0 arg
  case "${1-}" in
    "")        show_status; printf '\n'; usage; exit 0 ;;
    --status)  show_status; exit 0 ;;
    --dry-run) dry=1; arg="${2-latest}" ;;
    --*)       usage; exit 2 ;;
    *)         arg="$1" ;;
  esac

  local classified mode norm
  classified="$(classify_input "$arg")" || refuse_input "$arg"
  mode="${classified%% *}"
  norm="${classified#* }"; norm="${norm%$'\n'}"

  if [ "$dry" = 1 ]; then
    do_update "$mode" "$norm" "$arg" 1
    exit 0
  fi

  command -v flock >/dev/null 2>&1 || die "pretorin-update: flock is required and missing."

  # Non-blocking: a second caller is REFUSED, not queued. Queueing would let a
  # Slack user wait on a lock they cannot see, behind an update they did not ask
  # for. Refusing names the holder instead.
  exec 9>"$LOCK"
  if ! flock -n 9; then
    local held="unknown"
    [ -e "$MARKER" ] && held="$(cat "$MARKER" 2>/dev/null || echo unknown)"
    log "pretorin-update: another update is in progress (${held})."
    log "  Nothing was changed. Check the outcome with: pretorin-update.sh --status"
    exit 3
  fi

  do_update "$mode" "$norm" "$arg" 0
}

main "$@"
