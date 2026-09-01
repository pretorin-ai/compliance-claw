#!/usr/bin/env bash
#
# smoke.sh — the Phase 4 verification gate, in two clearly separated sections.
#
#   SECTION A — no credentials. This is what CI runs. It proves the image, the
#               generated config, the mount posture, the stale-template warning,
#               the CWD fix, the secret containment of every secret class, the
#               private-target refusals, and that a FRESH volume comes up
#               Slack-configured with no manual JSON — all without a Pretorin key,
#               a model key, a Slack token or a GitHub App.
#
#   SECTION B — credentialed. Runs only when PRETORIN_API_KEY authenticates,
#               skips cleanly otherwise. Proves onboarding end to end, that the
#               bound repos are exactly targets.yaml, that a read tool works
#               through MCP, and that a write tool is rejected server-side.
#
# Usage:
#   scripts/smoke.sh                # both sections (B self-skips without a key)
#   scripts/smoke.sh --no-creds     # Section A only, even if a key is present
#
# State hygiene: every check that writes Pretorin state does so under a SCRATCH
# system/framework scope, so the operator's real preflight artifact is never
# touched by Section A. The sidecar marker and any scratch clones are restored or
# removed by the exit trap. Section B does run real onboarding — it is the same
# idempotent command the operator runs.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NO_CREDS=0
# WRITE_POSTURE is a TEST DECLARATION, never a deployment setting.
#
# `pretorin whoami` reports authentication but not scopes, so this harness cannot
# discover whether the key it holds can write. The probe further down is
# irreversible when it succeeds — it creates a real platform record — so the
# expected outcome has to be stated by whoever runs the suite.
#
# It used to be read from a key-mode variable in .env, which made a test argument
# look like configuration and, worse, implied Compliance Claw enforces a local
# read/write posture. It does not: the key's server-side scopes are the sole
# authorization boundary. So this is a flag.
#
# DEFAULT IS "unstated", and unstated means no write is ever attempted. That
# preserves the lesson from the incident this check was hardened after: an
# undeclared, write-enabled key once reached the probe and created a risk record.
WRITE_POSTURE=unstated
while [ $# -gt 0 ]; do
  case "$1" in
    --no-creds)           NO_CREDS=1 ;;
    --expect-read-only)   WRITE_POSTURE=read-only ;;
    --test-write-enabled) WRITE_POSTURE=write-enabled ;;
    -h|--help)
      cat <<'USAGE'
usage: smoke.sh [--no-creds] [--expect-read-only | --test-write-enabled]

  --no-creds             run Section A only (what CI runs)
  --expect-read-only     attempt a platform write and REQUIRE the platform to
                         reject it. Safe: nothing is created on success-to-reject.
  --test-write-enabled   attempt the same write and REQUIRE it to SUCCEED. This
                         CREATES A REAL PLATFORM RECORD. Opt-in only.

With neither posture flag, no write is attempted at all and the write-posture
rows report skipped-with-reason. These flags describe the KEY you are pointing at;
they change nothing about the deployment, which applies no local permission
filtering of its own.
USAGE
      exit 0 ;;
    *) printf 'smoke: unknown argument %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ISOLATION, BEFORE ANY DOCKER COMMAND. compose.yaml pins `name: compliance-claw`,
# so a run without its own project name attaches to the live deployment — and this
# suite writes to the volumes it attaches to (audit rows, a scratch preflight
# artifact, the template marker). There is deliberately no override.
case "${COMPOSE_PROJECT_NAME:-}" in
  "" | compliance-claw )
    printf 'smoke: ERROR — this suite writes to the volumes it runs against, so it\n' >&2
    printf '  needs a disposable Compose project, not the live "compliance-claw":\n' >&2
    printf '    COMPOSE_PROJECT_NAME=cc-smoke CC_TEST_PORT=18990 bash scripts/smoke.sh --no-creds\n' >&2
    printf '    COMPOSE_PROJECT_NAME=cc-smoke docker compose down -v\n' >&2
    exit 2 ;;
esac

PASS=0; FAIL=0; SKIP=0; WARN=0
FAILED_CHECKS=()

pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_CHECKS+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
note() { WARN=$((WARN+1)); printf '  \033[33mNOTE\033[0m  %s\n' "$1"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
head2() { printf '\n%s\n' "$1"; }

# ok <label> <command...> — passes when the command exits 0.
ok() { local label="$1"; shift; local out; if out="$("$@" 2>&1)"; then pass "$label"; else fail "$label" "$(printf '%s' "$out" | tail -3)"; fi; }
# notok <label> <command...> — passes when the command exits NON-zero.
notok() { local label="$1"; shift; local out; if out="$("$@" 2>&1)"; then fail "$label" "command unexpectedly succeeded"; else pass "$label"; fi; }
# has <label> <needle> <text>
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected to find: $2" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "did not expect to find: $2" ;; *) pass "$1" ;; esac; }

# `docker compose run` writes its own lifecycle lines ("Container ... Creating")
# and the entrypoint's messages to STDERR; the wrapped command owns stdout. So:
#   cli  ...            -> stdout only, for extracting a value
#   cli  ... 2>&1       -> both, for checks that assert on entrypoint output
# Merging the two when reading a value is how the first version of this file
# compared a version number against a container id.
cli()  { docker compose run --rm -T cli "$@"; }
val()  { docker compose run --rm -T cli "$@" 2>/dev/null | tr -d '\r'; }
inbox() { docker compose exec -T openclaw bash -s; }   # script arrives on stdin

SCRATCH_SYS="smoke-system"
SCRATCH_FW="smoke-framework"
SCRATCH_YAML=""
STAMP_BACKUP=""
GATEWAY_STARTED=0
SCRATCH_CLONES=()

cleanup() {
  local rc=$?
  set +e
  [ -n "$SCRATCH_YAML" ] && rm -f "$SCRATCH_YAML"
  for d in ${SCRATCH_CLONES[@]+"${SCRATCH_CLONES[@]}"}; do rm -rf "$d"; done
  # Remove the scratch preflight artifact and restore the template marker.
  cli bash -c "rm -f /home/node/.pretorin/preflight/preflight_${SCRATCH_SYS}_${SCRATCH_FW}.json" >/dev/null 2>&1
  if [ -n "$STAMP_BACKUP" ]; then
    cli bash -c "printf '%s\n' '${STAMP_BACKUP}' > /home/node/.openclaw/.compliance-claw-templates" >/dev/null 2>&1
  fi
  [ "$GATEWAY_STARTED" = 1 ] && docker compose down >/dev/null 2>&1
  exit $rc
}
trap cleanup EXIT

# WHICH FILE DESCRIBES THIS DEPLOYMENT. efforts.yaml is the runtime authority;
# targets.yaml survives only as input to `clawctl migrate` and is not mounted
# anywhere. Reading the wrong one here would make every target-shaped row below
# assert against repositories the deployment does not actually serve.
EFFORTS_FILE_SMOKE="${CC_EFFORTS_FILE:-efforts.yaml}"
TARGET_NAMES=()
PRIVATE_NAMES=()
# name/url/private/ref — private before ref, because tab is IFS whitespace and an
# absent ref would otherwise collapse the fields. See parse-targets.py.
if [ -f "$EFFORTS_FILE_SMOKE" ]; then
  EFFORT_NAMES=()
  while read -r e; do [ -n "$e" ] && EFFORT_NAMES+=("$e"); done \
    < <(python3 scripts/parse-efforts.py efforts "$EFFORTS_FILE_SMOKE")
  IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID _ \
    < <(python3 scripts/parse-efforts.py scope "${EFFORT_NAMES[0]}" "$EFFORTS_FILE_SMOKE")
  while IFS=$'\t' read -r n _u p _r; do
    [ -n "$n" ] || continue
    TARGET_NAMES+=("$n")
    [ "$p" = "true" ] && PRIVATE_NAMES+=("$n")
  done < <(python3 scripts/parse-efforts.py targets-all "$EFFORTS_FILE_SMOKE")
else
  EFFORT_NAMES=()
  IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID < <(python3 scripts/parse-targets.py scope)
  while IFS=$'\t' read -r n _u p _r; do
    [ -n "$n" ] || continue
    TARGET_NAMES+=("$n")
    [ "$p" = "true" ] && PRIVATE_NAMES+=("$n")
  done < <(python3 scripts/parse-targets.py list)
fi
FIRST_TARGET="${TARGET_NAMES[0]}"

# The same four fields (name/url/private/ref) from whichever file is authoritative,
# so a fixture built here describes the repositories this deployment actually has.
smoke_target_list() {
  if [ -f "$EFFORTS_FILE_SMOKE" ]; then
    python3 scripts/parse-efforts.py targets-all "$EFFORTS_FILE_SMOKE"
  else
    python3 scripts/parse-targets.py list
  fi
}

printf '\033[1mcompliance-claw smoke test\033[0m\n'
printf 'repo:    %s\n' "$REPO_ROOT"
printf 'scope:   %s / %s\n' "$SYSTEM_ID" "$FRAMEWORK_ID"
printf 'efforts: %s\n' "${EFFORT_NAMES[*]:-<none: legacy targets.yaml>}"
printf 'targets: %s\n' "${TARGET_NAMES[*]}"
printf 'private: %s\n' "${PRIVATE_NAMES[*]:-<none>}"
# compose.yaml pulls by default. Anything here that re-runs bootstrap therefore
# needs the released image to exist — except in build mode, which bootstrap.sh
# detects from COMPOSE_FILE on its own.
case "${COMPOSE_FILE:-}" in
  *compose.build.yaml*) printf 'image:   local build (COMPOSE_FILE overlay)\n' ;;
  *)                    printf 'image:   published (compose.yaml pulls; use the build overlay pre-release)\n' ;;
esac

# ===========================================================================
head1 "SECTION A — no credentials (this is what CI runs)"
# ===========================================================================

head2 "A1. versions and supply chain"
# The seed and the active CLI are different files on purpose, so asking "what
# version is this?" has two correct answers. `val pretorin version` resolves
# PATH, which puts the ACTIVE binary first — right for an operator, wrong for a
# pin assertion, because a deployment that has updated its CLI is SUPPOSED to be
# ahead of versions.env. So the pin is asserted against the seed by its explicit
# path, and the active binary is reported as a NOTE.
# Just the version token. `pretorin version` prints three lines and the third is
# `path:`, which differs between the seed and the active copy BY DEFINITION — so
# comparing whole outputs made the "unmodified" branch unreachable and every run
# emitted a spurious "expected after a CLI update" note.
pver() { val "$1" version | awk 'NR==1 && $2=="version" {print $3; exit}'; }
V_SEED="$(pver /opt/compliance-claw/pretorin-seed/pretorin)"
V_ACTIVE="$(pver pretorin)"
# Read from versions.env rather than hardcoded here. Two literals in a test are
# two more places to forget on a bump — and a pin nothing reads is decoration, not
# a source of truth. OPENCLAW_VERSION in particular had no consumer at all until
# this line; the Dockerfile FROM carries the tag as a literal beside its digest.
# shellcheck disable=SC1091
. ./versions.env
has "pretorin SEED matches versions.env (${PRETORIN_VERSION})" "$PRETORIN_VERSION" "$V_SEED"

# The active CLI. A NOTE, never a FAIL: being ahead of the seed is the whole
# point of the feature, and CI runs this on a fresh volume where the two agree.
# sha256 as well as version, because a same-version swap is invisible to a
# version comparison and is exactly what an agent with exec could do.
SEED_SHA="$(val sha256sum /opt/compliance-claw/pretorin-seed/pretorin | awk '{print $1}')"
ACTIVE_SHA="$(val sha256sum /home/node/.pretorin/bin/pretorin | awk '{print $1}')"
if [ -z "$V_ACTIVE" ]; then
  fail "the active Pretorin CLI runs" "nothing at /home/node/.pretorin/bin/pretorin reported a version"
elif [ "$V_ACTIVE" = "$V_SEED" ] && [ "$ACTIVE_SHA" = "$SEED_SHA" ]; then
  pass "active Pretorin CLI is the image seed, unmodified (${V_ACTIVE})"
elif [ "$V_ACTIVE" = "$V_SEED" ]; then
  note "active CLI reports ${V_ACTIVE} like the seed but the BYTES DIFFER — investigate"
  printf '        active %s\n        seed   %s\n' "$ACTIVE_SHA" "$SEED_SHA"
else
  note "active CLI is ${V_ACTIVE}; the image seeds ${V_SEED} (expected after a CLI update)"
fi

# The config must point MCP at the SAME file PATH resolves, or an update lands
# somewhere the agent never runs. This is the assertion the "two meanings of
# pretorin version" hazard used to require prose to explain.
CFG_CMD="$(val openclaw config get mcp.servers.pretorin.command | tr -d '"[:space:]')"
if [ "$CFG_CMD" = "/home/node/.pretorin/bin/pretorin" ]; then
  pass "mcp.servers.pretorin.command is the active binary"
else
  fail "mcp.servers.pretorin.command is the active binary" "config says: ${CFG_CMD:-<unset>}"
fi
has "openclaw matches versions.env (${OPENCLAW_VERSION})" "$OPENCLAW_VERSION" "$(val openclaw --version)"
# The FROM line restates the tag next to its digest, because FROM cannot source a
# file. If they drift, the image is not the version versions.env claims it is.
if grep -q "ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}@sha256:" Dockerfile; then
  pass "Dockerfile FROM tag agrees with OPENCLAW_VERSION"
else
  fail "Dockerfile FROM tag agrees with OPENCLAW_VERSION" \
       "versions.env says ${OPENCLAW_VERSION}; FROM says $(grep -oE 'openclaw/openclaw:[^@]+' Dockerfile | head -1)"
fi
ok  "image runs as x86_64" bash -c '[ "$(docker compose run --rm -T cli uname -m | tr -d "\r\n")" = x86_64 ]'

# Release-image probes must name the seed by its absolute path. The binary is
# deliberately off PATH and `bash -lc` rebuilds PATH, so a bare `pretorin` exits
# 127 — which is why the v0.3.1 run pushed an image and then tagged nothing.
# Two probes are expected: the built image, and the digest pulled back from GHCR.
REL_YML=".github/workflows/release.yml"
SEED_BIN="/opt/compliance-claw/pretorin-seed/pretorin"
BARE_PROBE="$(grep -nE "(-lc|run) +'([^']*[^/-])?pretorin " "$REL_YML" || true)"
SEED_PROBES="$(grep -cE "(-lc|run) +'[^']*${SEED_BIN}" "$REL_YML" || true)"
if [ -n "$BARE_PROBE" ]; then
  fail "release.yml probes Pretorin only by its seed path" "bare invocation: ${BARE_PROBE}"
elif [ "${SEED_PROBES:-0}" -lt 2 ]; then
  fail "release.yml probes Pretorin only by its seed path" \
       "expected the built-image and pulled-image probes; found ${SEED_PROBES}"
else
  pass "release.yml probes Pretorin only by its seed path (${SEED_PROBES} probes)"
fi

head2 "A2. Pretorin MCP tool surface (mock-based, no key)"
S="$(val pretorin mcp-smoke-test)"
has "mcp-smoke-test passes" "PASSED" "$S"

head2 "A3. targets.yaml parser"
ok "parse-targets.py --self-test" python3 scripts/parse-targets.py --self-test

head2 "A3bb. Target sync — offline rules and real-git outcomes"
# The SAME implementation bootstrap.sh runs and the SAME implementation the two
# Slack routes run, exercised against temporary local repositories. No network,
# no credentials, no containers, so it is the first thing to fail when the sync
# semantics break rather than the fortieth.
ok "sync-targets.sh --self-test (offline, host copy)" \
   bash scripts/sync-targets.sh --self-test

# And the copy that actually ships, at the path the plugin hardcodes. A wrapper
# present on the host but missing or unrunnable in the image is a feature that
# works in CI and not in Slack.
ok "sync-targets.sh --self-test (offline, image copy)" \
   docker compose run --rm -T cli /opt/compliance-claw/sync-targets.sh --self-test
ok "the sync wrapper ships at the documented path" \
   docker compose run --rm -T cli test -x /opt/compliance-claw/sync-targets.sh
ok "the parser ships beside it (name validation, not YAML in bash)" \
   docker compose run --rm -T cli test -r /opt/compliance-claw/parse-targets.py

# THE TWO DEFECTS FOUND IN REVIEW, GATED IN THE REAL CONTAINER TOO.
#
# Both were silent, and both are the kind that a green suite would otherwise keep
# hiding: a broken target list reported as a clean run, and one timeout wedging
# synchronization for good.
SYNC_BROKEN_PARSER="$(mktemp -d "${TMPDIR:-/tmp}/cc-sync-parser.XXXXXX")"
# POINT THE EFFORTS DISPATCH AT NOTHING, so these cases exercise the LEGACY
# targets.yaml branch they were written for. sync-targets.sh now prefers
# efforts.yaml, so without this the checkout's own efforts.yaml is picked up, the
# substituted broken parser is never reached, and the case silently asserts on a
# perfectly healthy run.
SYNC_NO_EFFORTS="${SYNC_BROKEN_PARSER}/absent-efforts.yaml"
printf 'import sys\nsys.stderr.write("simulated parser failure\\n")\nraise SystemExit(2)\n' \
  > "${SYNC_BROKEN_PARSER}/broken.py"
mkdir -p "${SYNC_BROKEN_PARSER}/targets"
printf 'system_id: s\nframework_id: f\ntargets:\n  - name: demo\n    url: https://example.invalid/d.git\n' \
  > "${SYNC_BROKEN_PARSER}/targets.yaml"
sync_broken() {
  CC_TARGETS_FILE="${SYNC_BROKEN_PARSER}/targets.yaml" \
  CC_EFFORTS_FILE="$SYNC_NO_EFFORTS" \
  CC_TARGETS_DIR="${SYNC_BROKEN_PARSER}/targets" \
  CC_PARSE_TARGETS="${SYNC_BROKEN_PARSER}/broken.py" \
  bash scripts/sync-targets.sh "$1" 2>/dev/null
}
for req in all demo; do
  notok "an unreadable target list fails the run (${req})" bash -c \
    "CC_TARGETS_FILE='${SYNC_BROKEN_PARSER}/targets.yaml' CC_EFFORTS_FILE='${SYNC_NO_EFFORTS}' CC_TARGETS_DIR='${SYNC_BROKEN_PARSER}/targets' CC_PARSE_TARGETS='${SYNC_BROKEN_PARSER}/broken.py' bash scripts/sync-targets.sh ${req}"
done
BROKEN_OUT="$(sync_broken all || true)"
has  "  and says so, rather than reporting a clean run" "targets_unreadable" "$BROKEN_OUT"
hasnt "  and never claims overall=ok"                   "overall=ok"        "$BROKEN_OUT"
BROKEN_ONE="$(sync_broken demo || true)"
hasnt "  and never blames the requested name for it" "is not declared in" "$BROKEN_ONE"
notok "bootstrap mode also refuses an unreadable list" bash -c \
  "CC_TARGETS_FILE='${SYNC_BROKEN_PARSER}/targets.yaml' CC_EFFORTS_FILE='${SYNC_NO_EFFORTS}' CC_TARGETS_DIR='${SYNC_BROKEN_PARSER}/targets' CC_PARSE_TARGETS='${SYNC_BROKEN_PARSER}/broken.py' bash scripts/sync-targets.sh --bootstrap"

# The exact state a SIGKILLed wrapper leaves: a lock naming a pid in this
# namespace that no longer exists. It used to answer "already running" forever.
SYNC_LOCK_NS="$( [ -r /proc/sys/kernel/random/boot_id ] \
  && printf 'boot-%s' "$(cat /proc/sys/kernel/random/boot_id)" \
  || printf 'host-%s' "$(hostname 2>/dev/null || echo unknown)" )"
mkdir -p "${SYNC_BROKEN_PARSER}/targets/.target-sync.lock"
printf 'pid=4194304 ns=%s ts=2026-01-01T00:00:00Z route=timeout\n' "$SYNC_LOCK_NS" \
  > "${SYNC_BROKEN_PARSER}/targets/.target-sync.lock/owner"
WEDGED="$(CC_TARGETS_FILE="${SYNC_BROKEN_PARSER}/targets.yaml" CC_EFFORTS_FILE="$SYNC_NO_EFFORTS" \
  CC_TARGETS_DIR="${SYNC_BROKEN_PARSER}/targets" bash scripts/sync-targets.sh all 2>&1 || true)"
hasnt "a lock left by a dead owner does not wedge sync forever" "sync_already_running" "$WEDGED"
has   "  and the reclaim is announced, not silent"              "reclaiming a stale lock" "$WEDGED"
[ ! -d "${SYNC_BROKEN_PARSER}/targets/.target-sync.lock" ] \
  && pass "  and the lock is released afterwards" \
  || fail "  and the lock is released afterwards"

# The property that must NOT regress in exchange: a live owner keeps its lock.
mkdir -p "${SYNC_BROKEN_PARSER}/targets/.target-sync.lock"
printf 'pid=%s ns=%s ts=2026-01-01T00:00:00Z route=live\n' "$$" "$SYNC_LOCK_NS" \
  > "${SYNC_BROKEN_PARSER}/targets/.target-sync.lock/owner"
LIVE="$(CC_TARGETS_FILE="${SYNC_BROKEN_PARSER}/targets.yaml" CC_EFFORTS_FILE="$SYNC_NO_EFFORTS" \
  CC_TARGETS_DIR="${SYNC_BROKEN_PARSER}/targets" bash scripts/sync-targets.sh all 2>/dev/null || true)"
has "a lock held by a LIVE process is still respected" "sync_already_running" "$LIVE"
rm -rf "$SYNC_BROKEN_PARSER"

# The plugin must give the wrapper a chance to run its trap, and must signal the
# whole process group — a SIGKILL-only path is what created the wedge.
if grep -q 'detached: true' plugins/target-sync/index.js \
   && grep -q 'signalGroup("SIGTERM")' plugins/target-sync/index.js \
   && grep -q 'process.kill(-child.pid' plugins/target-sync/index.js; then
  pass "the plugin terminates the process GROUP, SIGTERM before SIGKILL"
else
  fail "the plugin terminates the process GROUP, SIGTERM before SIGKILL" \
       "a SIGKILL-only timeout leaves the global lock held forever"
fi

# ONE IMPLEMENTATION, ASSERTED. The whole design rests on bootstrap and Slack
# running the same file; a re-implementation creeping into either would be
# invisible until the two disagreed in production.
if grep -q 'sync-targets.sh --bootstrap' scripts/bootstrap.sh \
   && ! grep -qE '^\s*(git_auth|assert_no_credential)\(\)' scripts/bootstrap.sh; then
  pass "bootstrap delegates to sync-targets.sh and keeps no copy of the git logic"
else
  fail "bootstrap delegates to sync-targets.sh and keeps no copy of the git logic"
fi
if grep -q '/opt/compliance-claw/sync-targets.sh' plugins/target-sync/index.js \
   && ! grep -qE "spawn\(\s*[\"']git" plugins/target-sync/index.js; then
  pass "the plugin shells out to the wrapper and runs no git of its own"
else
  fail "the plugin shells out to the wrapper and runs no git of its own"
fi

head2 "A3b. CLI updater — offline input rules and the drift contract"
# The input rules are pure: no network, no credentials, no volume. They are also
# the whole authorization surface of the model-visible route, so they get a gate
# that runs on every push rather than a hand-check once.
ok "pretorin-update --self-test (offline)" \
   docker compose run --rm -T cli /opt/compliance-claw/pretorin-update.sh --self-test

# The updater must never be reachable as a bare name: PATH puts the active CLI
# first, and a bare `pretorin` inside the wrapper would silently operate on
# whichever file PATH found. --self-test asserts this internally; assert here
# that the wrapper is actually present in the image at the documented path.
ok "the updater wrapper ships at the documented path" \
   docker compose run --rm -T cli test -x /opt/compliance-claw/pretorin-update.sh

# BOTH DIRECTIONS. A drift warning with no update.sh branch is invisible to an
# operator running update.sh; an update.sh branch with no warning is a dead grep
# that reports "config is current" forever. Both have shipped in this repo, which
# is why this is a gate and not a convention.
DW_DECLARED="$(grep -oE '# DRIFT-WARNING: .+' scripts/entrypoint.sh | sed 's/# DRIFT-WARNING: //' | sort)"
DW_GREPPED="$(grep -oE "grep -q '[^']+'" scripts/update.sh | sed "s/grep -q '//;s/'\$//" | sort)"
if [ -n "$DW_DECLARED" ] && [ "$DW_DECLARED" = "$DW_GREPPED" ]; then
  pass "every entrypoint drift warning has an update.sh branch, and vice versa"
else
  fail "every entrypoint drift warning has an update.sh branch, and vice versa" \
       "declared: $(printf '%s' "$DW_DECLARED" | tr '\n' '|') vs grepped: $(printf '%s' "$DW_GREPPED" | tr '\n' '|')"
fi

head2 "A3c. write-posture safety property (no credentials needed)"
# ASSERTED WHERE IT ALWAYS RUNS. The property is "without an explicit posture
# flag, no platform write is ever attempted" — true with or without credentials,
# so it belongs in the section CI executes rather than behind a credential gate.
# The probe itself still lives in B4, where a key exists to probe with.
case "$WRITE_POSTURE" in
  unstated)
    pass "no posture flag -> no write probe will be attempted (WRITE_POSTURE=unstated)" ;;
  read-only)
    pass "--expect-read-only -> the probe will run and REQUIRE a server-side rejection" ;;
  write-enabled)
    note "--test-write-enabled -> the probe WILL CREATE A REAL PLATFORM RECORD" ;;
esac
# And prove the parser cannot be bypassed: an unknown argument must refuse rather
# than fall through to a default posture.
if bash "$0" --nonsense-argument >/dev/null 2>&1; then
  fail "an unknown argument is refused" "it was accepted, so a typo could silently select a posture"
else
  pass "an unknown argument is refused rather than defaulting"
fi

head2 "A3c2. the seeded slash command is the one the Slack app registers"
# Slack rejects an unregistered /foo BEFORE it reaches the gateway, so a mismatch
# between these two files is invisible in our logs and looks like the bot being
# down. Static, so it runs with no credentials and no Slack profile.
SEED_CMD="$(python3 -c '
import re
s = open("scripts/slack-channel.patch.json5").read()
m = re.search(r"slashCommand:\s*\{[^}]*name:\s*\"([^\"]+)\"", s)
print(m.group(1) if m else "")' 2>/dev/null)"
APP_CMD="$(python3 -c '
import json
c = json.load(open("slack/app-manifest.json"))["features"]["slash_commands"]
print(c[0]["command"].lstrip("/") if c else "")' 2>/dev/null)"
if [ -n "$SEED_CMD" ] && [ "$SEED_CMD" = "$APP_CMD" ]; then
  pass "the seeded slashCommand name matches the manifest's command (/${SEED_CMD})"
else
  fail "the seeded slashCommand name matches the manifest's command" \
       "seed='${SEED_CMD}' manifest='${APP_CMD}' — Slack would reject it unsent"
fi

head2 "A3d. no operator message is executed instead of printed"
# An UNQUOTED heredoc runs command substitution on its body, so a command name
# written in backticks for a human to read gets EXECUTED on the host. This is not
# hypothetical: the credentialed acceptance run caught onboard-targets.sh doing
# it, and the failure DELETED the command name from the very sentence whose job
# was to name it. Static check, so CI runs it with no credentials.
if HD_OUT="$(python3 scripts/lint-heredocs.py scripts/*.sh 2>&1)"; then
  pass "no unescaped backtick inside an expanding heredoc"
else
  fail "no unescaped backtick inside an expanding heredoc" \
       "$(printf '%s' "$HD_OUT" | tr '\n' ' ')"
fi
# And prove the checker is live rather than vacuously green: re-introduce the
# exact defect in a COPY and require a non-zero exit. A linter nothing has ever
# seen fail is not a gate.
HD_TMP="$(mktemp -d)"
sed 's/(Not \\`openclaw mcp reload\\`/(Not `openclaw mcp reload`/' \
  scripts/onboard-targets.sh > "${HD_TMP}/regressed.sh"
if python3 scripts/lint-heredocs.py "${HD_TMP}/regressed.sh" >/dev/null 2>&1; then
  fail "the heredoc checker detects the defect it was written for" \
       "the reintroduced backtick was not flagged, so the check proves nothing"
else
  pass "the heredoc checker detects the defect it was written for"
fi
rm -rf "$HD_TMP"

head2 "A4. gateway starts, config and templates are seeded"
if docker compose ps --status running --services 2>/dev/null | grep -qx openclaw; then
  note "gateway already running; leaving it up at the end"
else
  GATEWAY_STARTED=1
  # Output is NOT discarded. `up -d` fails for ordinary reasons — most commonly a
  # port already bound by another compose project — and swallowing that turns a
  # gateway that never started into a silent prerequisite for twenty later checks.
  if ! UP_OUT="$(docker compose up -d 2>&1)"; then
    fail "gateway starts" "$(printf '%s' "$UP_OUT" | tail -3)"
  fi
fi

# Readiness is asserted against THIS PROJECT'S CONTAINER, not against the host
# port. `curl 127.0.0.1:18789/healthz` proves only that something is listening —
# and when a second compose project holds that port, the reply comes from a
# DIFFERENT deployment entirely. Observed: a run where `up -d` had failed on a
# port clash still reported "gateway answers /healthz", because the neighbouring
# gateway answered it. Every gateway-dependent check after that was meaningless.
#
# Docker's own healthcheck already probes 127.0.0.1:18789/healthz from inside the
# container, so container health is the same signal, correctly attributed.
READY=0
for _ in $(seq 1 60); do
  HSTATE="$(docker compose ps --format json 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("Service") == "openclaw":
        print("%s/%s" % (d.get("State"), d.get("Health") or "none"))
        break
' 2>/dev/null || true)"
  [ "$HSTATE" = "running/healthy" ] && { READY=1; break; }
  sleep 2
done
if [ "$READY" = 1 ]; then
  pass "this project's gateway container is running and healthy"
else
  fail "this project's gateway container is running and healthy" \
       "state was '${HSTATE:-absent}' after 120s. A port clash with another compose
        project is the usual cause; \`docker compose ps -a\` and COMPOSE_PROJECT_NAME."
fi
# The host port is only meaningful once our own container is known to be up.
# Skipped rather than run when it is not: a reply from a neighbouring project's
# gateway would be a pass that means nothing, which is the bug this block exists
# to prevent, reintroduced two lines lower down.
if [ "$READY" = 1 ]; then
  # Ask compose which port THIS project published, rather than assuming 18789.
  # An isolated test project runs on a different port, and a hardcoded one sends
  # the probe to whatever else is listening — most likely the real deployment.
  HPORT="$(docker compose port openclaw 18789 2>/dev/null | sed 's/.*://' | tr -d '\r\n')"
  if [ -z "$HPORT" ]; then
    skip "gateway answers /healthz on the published port" \
         "docker compose port did not report a published port for openclaw"
  elif curl -fsS -m 5 "http://127.0.0.1:${HPORT}/healthz" >/dev/null 2>&1; then
    pass "gateway answers /healthz on the published port (${HPORT})"
  else
    fail "gateway answers /healthz on the published port (${HPORT})" \
         "container healthy but the published port did not answer"
  fi
else
  skip "gateway answers /healthz on the published port" \
       "our container is not up; any reply on that port would come from another deployment"
fi

# Read once, up front: the expected plugin profile below is decided by what is
# actually in the config, and several later checks assert on the same text.
CFG="$(val cat /home/node/.openclaw/openclaw.json)"
# COMMENT-STRIPPED VIEW. The template is JSON5 and deliberately DOCUMENTS options
# it does not set — `// toolFilter: {` is the live example. A bare grep for a key
# name therefore finds the COMMENT and reports a setting that is not there. Same
# defect class as the absolute-path invariant check, which once matched its own
# explanatory comment. Found by the credentialed acceptance run, where "no local
# tool filter is configured" failed against a config that configures no filter.
#
# WHOLE-LINE COMMENTS ONLY: "http://127.0.0.1:18789" also contains //, so
# stripping from the first // anywhere would eat real values.
CFG_LIVE="$(printf '%s\n' "$CFG" | sed 's|^[[:space:]]*//.*$||')"
CFG_RAW="$CFG"
if printf '%s' "$CFG" | grep -q '/opt/compliance-claw/plugins/slack'; then
  SLACK_PROFILE=1
  printf '  config profile: SLACK (plugins.allow is exclusive, bundled set trimmed)\n'
else
  SLACK_PROFILE=0
  printf '  config profile: no Slack (Phase 4 baseline, 8 bundled plugins)\n'
fi

# The WHOLE log, not `tail -N`: the plugin banner is printed once at startup, so
# on a gateway that has been up for hours a tail no longer contains it — and then
# the codex-absence check below passes against an empty string, which is a lie
# rather than a pass.
#
# REGRESSION FIX. The Phase 4 pattern was '([0-9]* plugins:[^)]*)', which stopped
# matching entirely once Slack shipped, for two independent reasons:
#   - the banner says "1 plugin" (SINGULAR) when only one plugin activates
#   - it now carries a timing suffix: "(1 plugin: slack; 0.6s)"
# The check failed loudly rather than passing vacuously — Phase 4 fixed that class
# — but a check that can never pass is still a dead check.
LOGS="$(docker compose logs openclaw 2>&1)"
PLUGIN_LINE="$(printf '%s' "$LOGS" | grep -oE '\([0-9]+ plugins?: [^)]*\)' | tail -1)"
if [ -z "$PLUGIN_LINE" ]; then
  fail "runtime pin holds: plugin banner found in the log" \
       "no '(N plugin(s): ...)' line; the codex-absence check cannot be trusted without it"
else
  # Strip the wrapper and the "; 0.6s" timing so what is compared is the name set.
  PLUGIN_NAMES="$(printf '%s' "$PLUGIN_LINE" | sed -E 's/^\([0-9]+ plugins?: //; s/\)$//; s/;.*$//')"
  # TWO PROFILES, and which one applies is decided by the config, not by hope.
  # Slack's patch sets plugins.allow, which is an EXCLUSIVE allowlist and
  # therefore also trims the bundled set. Asserting a single expected number would
  # mean one of the two profiles is always failing.
  if [ "$SLACK_PROFILE" = 1 ]; then
    has "runtime plugin set includes slack (Slack profile)" "slack" "$PLUGIN_NAMES"
    has "runtime plugin set includes pretorin-update (Slack profile)" "pretorin-update" "$PLUGIN_NAMES"
    has "runtime plugin set includes target-sync (Slack profile)" "target-sync" "$PLUGIN_NAMES"
    # The allowlist is exclusive, so it must name EVERY local id and nothing
    # else: an id left out is a plugin silently disabled — the exact failure the
    # Slack patch's comments warn about — and a bundled id creeping in would mean
    # the trim stopped working. Compared as a sorted set so banner ordering, which
    # is not a contract, cannot fail this.
    EXPECTED_ALLOWED="pretorin-update slack target-sync"
    GOT_ALLOWED="$(printf '%s' "$PLUGIN_NAMES" | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "$GOT_ALLOWED" = "$EXPECTED_ALLOWED" ]; then
      pass "the exclusive allowlist activates exactly the local plugins"
    else
      fail "the exclusive allowlist activates exactly the local plugins" \
           "expected '${EXPECTED_ALLOWED}', got '${GOT_ALLOWED}'"
    fi
  else
    # 10, not 8: the base template adds two local load paths and deliberately
    # sets NO plugins.allow, so the bundled eight still load and both local
    # plugins join them. That is what keeps this profile — the one CI runs — able
    # to exercise every route without a Slack workspace.
    has "runtime plugin set is the 8 bundled + 2 local (no-Slack profile)" "10 plugins" "$PLUGIN_LINE"
    has "  updater plugin present: pretorin-update" "pretorin-update" "$PLUGIN_NAMES"
    has "  sync plugin present: target-sync" "target-sync" "$PLUGIN_NAMES"
    for p in browser canvas device-pair file-transfer memory-core ollama phone-control talk-voice; do
      has "  bundled plugin present: ${p}" "$p" "$PLUGIN_NAMES"
    done
  fi
  # Independent of the profile, and still the point of the pin: the Codex
  # app-server harness must not be the runtime. The allowlist would now mask codex
  # on its own, so the log line below is what actually proves the pin.
  hasnt "codex plugin absent from the banner" "codex" "$PLUGIN_LINE"
fi

# Assert on values, not on formatting. OpenClaw can rewrite this file as strict
# JSON (observed: `gateway: {` becomes `"gateway": {` and every comment is
# dropped), so matching JSON5 syntax makes this check fail on a healthy
# deployment. These three survive any reformat.
has "config seeded into the state volume" '18789' "$CFG"
has "config registers the Pretorin MCP server" '/home/node/.pretorin/bin/pretorin' "$CFG"
# The seed path must NOT appear: if it does, this config predates the re-point
# and CLI updates would land somewhere MCP never runs.
hasnt "config does not still point MCP at the image seed" '/usr/local/bin/pretorin' "$CFG"
has "config carries the updater plugin load path" '/opt/compliance-claw/plugins/pretorin-update' "$CFG"
has "config carries the sync plugin load path" '/opt/compliance-claw/plugins/target-sync' "$CFG"
hasnt "config no longer loads a skill directory" 'extraDirs' "$CFG"

# The updater plugin, checked through OpenClaw's own diagnostics rather than by
# reading the startup banner. `plugins doctor` is what surfaces a rejected
# manifest, suspicious file ownership or an undeclared tool contract — every one
# of which otherwise presents to an operator as "the command just does not
# exist".
#
# NOT `plugins validate`: that command only understands defineToolPlugin metadata
# and always fails on a mixed command+tool plugin like this one.
PDOCTOR="$(val openclaw plugins doctor 2>&1 || true)"
if printf '%s' "$PDOCTOR" | grep -q 'No plugin issues detected'; then
  pass "openclaw plugins doctor reports no issues"
else
  fail "openclaw plugins doctor reports no issues" "$(printf '%s' "$PDOCTOR" | head -4)"
fi

PINSPECT="$(val openclaw plugins inspect pretorin-update --runtime --json 2>&1 || true)"
has "updater plugin loads at runtime" 'pretorin-update' "$PINSPECT"
has "updater registers its agent tool" 'pretorin_update' "$PINSPECT"
hasnt "updater plugin passes OpenClaw file-safety checks" 'blocked plugin candidate' "$PINSPECT"

SINSPECT="$(val openclaw plugins inspect target-sync --runtime --json 2>&1 || true)"
has "sync plugin loads at runtime" 'target-sync' "$SINSPECT"
has "sync registers its agent tool" 'target_sync' "$SINSPECT"
hasnt "sync plugin passes OpenClaw file-safety checks" 'blocked plugin candidate' "$SINSPECT"
has "config keeps the key as a substitution, not a value" '${PRETORIN_API_KEY}' "$CFG"
has "config carries the MCP cwd fix" '/opt/compliance-claw/no-repo' "$CFG"

# The orphaned-allowlist trap: plugins.allow is exclusive, so a config that keeps
# it after channels.slack is removed silently runs with seven bundled plugins gone
# and no Slack to show for it, and nothing in the log explains why. The two must
# move together.
HAS_ALLOW=0; HAS_CHAN=0
printf '%s' "$CFG" | grep -q '"allow"' && HAS_ALLOW=1
printf '%s' "$CFG" | grep -qE '"slack"[[:space:]]*:[[:space:]]*\{' && HAS_CHAN=1
if [ "$HAS_ALLOW" = "$HAS_CHAN" ]; then
  pass "plugins.allow and channels.slack are both-or-neither (allow=${HAS_ALLOW} slack=${HAS_CHAN})"
else
  fail "plugins.allow and channels.slack are both-or-neither" \
       "allow=${HAS_ALLOW} slack=${HAS_CHAN} — an orphaned exclusive allowlist trims the bundled plugins for nothing"
fi
# THE TEMPLATE, NOT A SEEDED COPY. The entrypoint no longer writes AGENTS.md into
# the default workspace: with multi-effort there is no single agent to write
# instructions for, and `scripts/clawctl apply` renders one per effort into that
# effort's own workspace. Seeding the raw template would install a file full of
# unsubstituted @PLACEHOLDERS@ claiming a scope no agent has.
#
# So what is asserted here is that the template SHIPS and still carries the
# clauses every generated copy depends on. Whether a workspace has an AGENTS.md
# is now an apply-time question, covered by clawctl's own self-test.
AG="$(val cat /opt/compliance-claw/agents-md.template)"
has "the AGENTS.md template ships in the image" "Review targets" "$AG"
has "  it requires target selection" "state which target" "$AG"
has "  it requires evidence provenance" "commit SHA" "$AG"
has "  it pins the effort identity" "@EFFORT@" "$AG"
has "  it refuses conversational context switching" "cannot" "$AG"
has "  it redirects to the right channel via the mounted efforts.yaml" \
    "/etc/compliance-claw/efforts.yaml" "$AG"
# THE HONESTY CLAUSE. An agent that described its own routing as a security
# guarantee would be wrong, and the instructions say so explicitly.
has "  it never claims prompt routing is a security boundary" \
    "Do not describe this as a security guarantee" "$AG"
notok "the entrypoint does NOT seed a placeholder AGENTS.md into the workspace" \
      docker compose exec -T openclaw grep -q '@EFFORT@' /home/node/.openclaw/workspace/AGENTS.md
SHIPPED="$(val cat /opt/compliance-claw/config-template.version | tr -d '\n')"
STAMP_BACKUP="$(val cat /home/node/.openclaw/.compliance-claw-templates | tr -d '\n')"
if [ "$STAMP_BACKUP" = "$SHIPPED" ]; then
  pass "template marker written and current (v${SHIPPED})"
else
  fail "template marker written and current" "marker='${STAMP_BACKUP}' shipped='${SHIPPED}'"
fi

head2 "A4e. per-agent tool isolation, decided by OpenClaw itself"
# THE ASSERTION THAT MATTERS FOR MULTI-EFFORT, AND THE ONE EASIEST TO FAKE.
#
# Checking that the generated config CONTAINS a deny string proves only that we
# wrote a string. What has to be true is that OpenClaw, given that policy, refuses
# another effort's Pretorin tools and still allows this effort's own and the
# built-ins. So this asks OpenClaw's OWN matcher, imported out of the image, with
# exactly the policy scripts/openclaw-patch.py generates.
#
# The module is selected by SHAPE rather than by filename: upstream ships more
# than one build under hashed names, and picking by name grabbed the wrong one.
# If no matcher is found the row SKIPs loudly rather than passing silently.
POLICY_OUT="$(docker compose run --rm -T cli sh -c 'cat > /tmp/p.mjs && node /tmp/p.mjs' <<'PROBE' 2>&1 || true
import { readdirSync } from "node:fs";
const dir = "/app/dist";
let fn = null;
for (const f of readdirSync(dir).filter((f) => f.startsWith("tool-policy-match-"))) {
  const m = await import(`${dir}/${f}`);
  for (const v of Object.values(m)) {
    if (typeof v === "function" && v.length === 2) {
      try {
        if (v("read", { deny: ["read"] }) === false && v("read", {}) === true) { fn = v; break; }
      } catch {}
    }
  }
  if (fn) break;
}
if (!fn) { console.log("SKIP"); process.exit(0); }
const A = { deny: ["pretorin-eff-b__*"] };
const B = { deny: ["pretorin-eff-a__*"] };
const cases = [
  ["own-tool-allowed",   A, "pretorin-eff-a__check_context", true],
  ["other-tool-denied",  A, "pretorin-eff-b__check_context", false],
  ["other-tool-denied2", A, "pretorin-eff-b__start_task",    false],
  ["mirror-allowed",     B, "pretorin-eff-b__check_context", true],
  ["mirror-denied",      B, "pretorin-eff-a__check_context", false],
  ["builtin-kept",       A, "read",                          true],
  ["target-sync-kept",   A, "target_sync",                   true],
];
let bad = 0;
for (const [label, policy, tool, want] of cases) {
  if (fn(tool, policy) !== want) { bad++; console.log("BAD " + label); }
}
console.log(bad ? "FAILED" : "ALLPASS");
PROBE
)"
case "$POLICY_OUT" in
  *ALLPASS*)
    pass "OpenClaw's own matcher denies another effort's Pretorin tools"
    pass "  and still allows this effort's own tools and the built-ins" ;;
  *SKIP*)
    skip "per-agent tool isolation (OpenClaw's matcher module was not found)" \
         "upstream moved it; the generated policy is unverified by this row" ;;
  *)
    fail "OpenClaw's own matcher denies another effort's Pretorin tools" \
         "$(printf '%s' "$POLICY_OUT" | tail -4)" ;;
esac

head2 "A4b. the published image version agrees with versions.env"
V_REPO="$(awk -F= '/^IMAGE_REPO=/{print $2}' versions.env)"
V_VER="$(awk -F= '/^IMAGE_VERSION=/{print $2}' versions.env)"
# compose.yaml has to restate the literal because compose cannot source a file.
# That duplication is documented in both files; this is what keeps it honest.
if [ -n "$V_REPO" ] && [ -n "$V_VER" ]; then
  if grep -qE "^[[:space:]]*image:[[:space:]]*${V_REPO}:${V_VER}([[:space:]]|@|\$)" compose.yaml; then
    pass "compose.yaml image matches versions.env (${V_REPO}:${V_VER})"
  else
    fail "compose.yaml image matches versions.env" \
         "expected ${V_REPO}:${V_VER}; found: $(grep -E '^[[:space:]]*image:' compose.yaml | head -1 | tr -s ' ')"
  fi
else
  fail "versions.env declares IMAGE_REPO and IMAGE_VERSION"
fi
# The default compose file must never be able to build: with a build section
# present, `up` builds whenever the image is absent locally, which would let an
# unscanned, unsigned local image stand in for the released one.
if grep -qE '^[[:space:]]*build:' compose.yaml; then
  fail "compose.yaml has no build section (pull-only by default)" \
       "a build: section lets 'docker compose up' silently build instead of pulling"
else
  pass "compose.yaml has no build section (pull-only by default)"
fi
# VM READINESS. The gateway is long-running and must come back by itself after a
# host reboot; `cli` is a one-off runner and must not. Read from the RENDERED
# config, so putting the policy on the shared anchor — which would hand it to
# `cli` too — fails here rather than in production.
ok "the gateway restarts unless-stopped, and 'cli' has no restart policy" \
   bash -c 'docker compose --profile cli config --format json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)[\"services\"]
got=d[\"openclaw\"].get(\"restart\")
assert got == \"unless-stopped\", f\"openclaw restart is {got!r}\"
assert not d[\"cli\"].get(\"restart\"), \"cli has a restart policy\"
"'
# Is the RUNNING deployment actually on the image this checkout pins? An
# operator who pulled the repo but never restarted is running last release's
# bytes while every file here describes the new one — invisible, and exactly the
# state scripts/update.sh exists to fix.
#
# NOTE, never FAIL. Being mid-update is not being broken, and CI runs this with
# no deployment at all. Local comparison only: no registry call, so the
# no-credential section stays offline.
PINNED_DIGEST="$(awk '/^[[:space:]]*image:/{ if (match($0, /@sha256:[0-9a-f]+/)) { print substr($0, RSTART+1, RLENGTH-1); exit } }' compose.yaml)"
RUNNING_CID="$(docker compose ps -q openclaw 2>/dev/null | head -1)"
if [ -z "$PINNED_DIGEST" ]; then
  skip "the running image matches the digest compose.yaml pins" \
       "compose.yaml pins no digest (build overlay, or a tag-only reference)"
elif [ -z "$RUNNING_CID" ]; then
  skip "the running image matches the digest compose.yaml pins" \
       "no gateway container in this project; nothing to compare"
else
  # .Config.Image is the reference the container was CREATED from, which compose
  # sets to the digest-pinned literal. A container created before the pin moved
  # keeps the old one, which is the whole point. Falling back to the image's own
  # RepoDigests covers a container created from a bare tag or a local build.
  RUNNING_DIGEST="$(docker inspect "$RUNNING_CID" --format '{{.Config.Image}}' 2>/dev/null \
                    | grep -oE 'sha256:[0-9a-f]+' | head -1)"
  if [ -z "$RUNNING_DIGEST" ]; then
    RUNNING_IMG="$(docker inspect "$RUNNING_CID" --format '{{.Image}}' 2>/dev/null)"
    RUNNING_DIGEST="$(docker image inspect "$RUNNING_IMG" --format '{{join .RepoDigests "\n"}}' 2>/dev/null \
                      | grep -oE 'sha256:[0-9a-f]+' | head -1)"
  fi
  if [ -z "$RUNNING_DIGEST" ]; then
    skip "the running image matches the digest compose.yaml pins" \
         "the running container reports no digest (a local build has none until pushed)"
  elif [ "$RUNNING_DIGEST" = "$PINNED_DIGEST" ]; then
    pass "the running image matches the digest compose.yaml pins"
  else
    note "deployment is behind the repo pin: run scripts/update.sh"
    printf '        running %s\n        pinned  %s\n' "$RUNNING_DIGEST" "$PINNED_DIGEST"
  fi
fi

ok "compose.build.yaml restores the build path" \
   bash -c 'COMPOSE_FILE=compose.yaml:compose.build.yaml docker compose config --format json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)[\"services\"]
assert all(s.get(\"build\") for s in d.values()), \"a service has no build section\"
assert all(s[\"image\"]==\"compliance-claw:local\" for s in d.values()), \"image is not the local tag\"
"'

head2 "A4d. FILE-BACKED SECRET DEPLOYMENT"
# Static assertions run in CI without credentials. The overlay must remove the
# base env_file entirely, mount every secret explicitly, and expose only *_FILE
# paths plus documented non-secret configuration to Docker.
FILE_SECRET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-file-secrets.XXXXXX")"
for f in pretorin-api-key openclaw-gateway-token slack-app-token slack-bot-token \
         openai-api-key anthropic-api-key github-readonly-pat; do
  : > "${FILE_SECRET_DIR}/${f}"
done
FILE_SECRET_CONFIG="$(COMPLIANCE_CLAW_SECRET_DIR="$FILE_SECRET_DIR" \
  COMPOSE_FILE=compose.yaml:compose.secrets.yaml docker compose --profile cli config --format json 2>/dev/null || true)"
rm -rf "$FILE_SECRET_DIR"
if [ -n "$FILE_SECRET_CONFIG" ]; then
  pass "file-secret overlay renders"
else
  fail "file-secret overlay renders" "docker compose config returned no JSON"
fi
FILE_SECRET_CHECK="$(printf '%s' "$FILE_SECRET_CONFIG" | python3 -c '
import json,sys
d=json.load(sys.stdin)["services"]
secret_names={"PRETORIN_API_KEY","OPENCLAW_GATEWAY_TOKEN","SLACK_APP_TOKEN","SLACK_BOT_TOKEN","OPENAI_API_KEY","ANTHROPIC_API_KEY"}
for name,svc in d.items():
    assert not svc.get("env_file"), f"{name} still has env_file"
    env=svc.get("environment",{})
    assert not (secret_names & set(env)), f"{name} has direct secret values"
    # Shared by both services: the Pretorin key and the Slack pair. Everything
    # else is delivered per service, so it is asserted per service below.
    common={n+"_FILE" for n in {"PRETORIN_API_KEY","SLACK_APP_TOKEN","SLACK_BOT_TOKEN"}}
    assert common <= set(env), f"{name} lacks the shared *_FILE paths"
# THE DELIVERY MATRIX, ASSERTED AS AN EXACT SET IN BOTH DIRECTIONS.
#
# "<= set(env)" alone only catches under-delivery. Over-delivery is the failure
# that hides: everything works, some container just holds a credential it never
# needed, and nobody notices until it leaks. So each side is pinned exactly.
want_openclaw={"pretorin_api_key","slack_app_token","slack_bot_token",
               "openclaw_gateway_token","openai_api_key","anthropic_api_key",
               "github_readonly_pat"}
want_cli={"pretorin_api_key","slack_app_token","slack_bot_token"}
got_openclaw={x["source"] for x in d["openclaw"].get("secrets",[])}
got_cli={x["source"] for x in d["cli"].get("secrets",[])}
assert got_openclaw == want_openclaw, f"openclaw secrets {sorted(got_openclaw)} != {sorted(want_openclaw)}"
assert got_cli == want_cli, f"cli secrets {sorted(got_cli)} != {sorted(want_cli)}"
# Gateway-only, by env var too. A model key gives spend authority to a container
# that runs no turns; the gateway token would let a one-off cli start a second
# gateway against the same volumes.
for gateway_only in ("OPENAI_API_KEY_FILE","ANTHROPIC_API_KEY_FILE","OPENCLAW_GATEWAY_TOKEN_FILE"):
    assert gateway_only in d["openclaw"].get("environment",{}), f"openclaw lacks {gateway_only}"
    assert gateway_only not in d["cli"].get("environment",{}), f"cli should not receive {gateway_only}"
# THE PAT HAS NO ENVIRONMENT VARIABLE AT ALL, ON EITHER SERVICE, AND THAT IS THE
# WHOLE DESIGN. Every other secret is exported into PID 1 by the entrypoint, so
# unsandboxed tool execution in the agent process inherits it. The PAT is read
# from the mounted path by a git credential helper instead. NO APOSTROPHES IN
# THIS BLOCK: it lives inside a single-quoted python3 -c argument, so one would
# close the shell string and the whole file would stop parsing. That is not
# hypothetical — it happened twice while writing this, including once in this
# very comment. A GITHUB_READONLY_PAT_FILE
# appearing here would mean somebody wired it into load_secret_file, which would
# silently put a git credential into the model process environment.
for name,svc in d.items():
    env=svc.get("environment",{})
    assert "GITHUB_READONLY_PAT" not in env, f"{name} has a direct PAT value"
    assert "GITHUB_READONLY_PAT_FILE" not in env, \
        f"{name} exports the PAT as an environment variable; it must stay file-only"
# MOUNT POSTURE, ASSERTED IN BOTH DIRECTIONS. The writable maintenance alias
# belongs to the gateway alone, and the assessment mount must stay read-only on
# BOTH — a YAML merge key replaces a volumes list rather than appending to it, so
# this is exactly the mistake that ships silently.
def mounts(svc):
    return {v["target"]: v for v in d[svc].get("volumes",[])}
mo, mc = mounts("openclaw"), mounts("cli")
assert mo["/workspace/targets"].get("read_only"), "openclaw assessment mount is not read-only"
assert mc["/workspace/targets"].get("read_only"), "cli assessment mount is not read-only"
assert "/var/lib/compliance-claw/targets" in mo, "openclaw lacks the maintenance mount"
assert not mo["/var/lib/compliance-claw/targets"].get("read_only"), "maintenance mount is not writable"
assert "/var/lib/compliance-claw/targets" not in mc, "cli must not get the maintenance mount"
# THE LEGACY SINGLE-EFFORT PATH IS STILL SERVED. /target-sync runs inside the
# gateway and validates every requested name against a mounted declaration file,
# so a deployment that has not run `clawctl migrate` needs targets.yaml there or
# every request fails on an unreadable target list. Read-only, gateway only: a
# one-off command runner has no use for it.
assert "/etc/compliance-claw/targets.yaml" in mo, \
    "openclaw lacks targets.yaml; legacy /target-sync cannot resolve any name"
assert mo["/etc/compliance-claw/targets.yaml"].get("read_only"), \
    "targets.yaml must be mounted read-only"
assert "/etc/compliance-claw/targets.yaml" not in mc, "cli must not get targets.yaml"
# The gateway keeps the state volumes it had before this feature: a restated
# volumes list that dropped one would come up broken in a way no other row here
# would notice.
for required in ("/home/node/.openclaw","/home/node/.pretorin"):
    assert required in mo and required in mc, f"a service lost {required}"
print("ok")
' 2>&1 || true)"
if [ "$FILE_SECRET_CHECK" = ok ]; then
  pass "overlay removes env_file and mounts only file-secret references"
else
  fail "overlay removes env_file and mounts only file-secret references" "$FILE_SECRET_CHECK"
fi

# UPGRADING A DEPLOYMENT THAT PREDATES THIS SECRET.
#
# A release that adds a `secrets:` entry turns a missing file into a FAILED
# START, not a warning: the daemon refuses the bind with "bind source path does
# not exist" and the gateway container never comes up. On an existing deployment
# that is an outage caused by a credential it may not even use.
#
# WHAT THIS ROW CAN AND CANNOT PROVE CHEAPLY. `docker compose config` renders
# happily with the file missing — it neither errors nor warns — so it cannot
# stand in for the failure. Actually reproducing it means starting the gateway
# with a broken secret directory, which is not something to do inside a suite
# that shares a project with a running deployment. So the failure itself is
# recorded as measured evidence in docs/plans/target-sync.md (observed:
# `up -d openclaw` with the file absent, container never created), and what is
# gated here is the REPAIR — which is the part that has to keep working.
OLD_SECRET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-old-secrets.XXXXXX")"
for f in pretorin-api-key openclaw-gateway-token slack-app-token slack-bot-token \
         openai-api-key anthropic-api-key; do
  : > "${OLD_SECRET_DIR}/${f}"       # note: no github-readonly-pat
done
printf '%s' 'PRE-EXISTING-VALUE' > "${OLD_SECRET_DIR}/pretorin-api-key"
COMPLIANCE_CLAW_SECRET_DIR="$OLD_SECRET_DIR" bash scripts/init-file-secrets.sh >/dev/null 2>&1 || true
if [ -e "${OLD_SECRET_DIR}/github-readonly-pat" ]; then
  pass "init-file-secrets.sh creates the missing PAT file (write-if-absent)"
else
  fail "init-file-secrets.sh creates the missing PAT file (write-if-absent)"
fi
if [ ! -s "${OLD_SECRET_DIR}/github-readonly-pat" ]; then
  pass "  and creates it EMPTY, so it means \"no PAT\" rather than an empty token"
else
  fail "  and creates it EMPTY, so it means \"no PAT\" rather than an empty token"
fi
if [ "$(cat "${OLD_SECRET_DIR}/pretorin-api-key")" = PRE-EXISTING-VALUE ]; then
  pass "  and overwrites no existing secret while doing it"
else
  fail "  and overwrites no existing secret while doing it" "an existing value was replaced"
fi
# EVERY secret the overlay declares must be creatable this way, or the next
# release to add one reintroduces the same outage. Compared as a set against the
# overlay itself rather than against a list maintained here.
# Read with grep, not a YAML parser: compose.secrets.yaml uses Compose's own
# `!reset []` tag, which is not standard YAML and makes yaml.safe_load raise —
# which the first version of this row swallowed, compared against an empty list,
# and reported as a failure with no explanation.
DECLARED_SECRETS="$(grep -oE '\$\{COMPLIANCE_CLAW_SECRET_DIR:-[^}]*\}/[A-Za-z0-9._-]+' compose.secrets.yaml \
  | sed 's|.*/||' | sort -u | tr '\n' ' ' | sed 's/ $//')"
CREATED_SECRETS="$(ls -A "$OLD_SECRET_DIR" | sort | tr '\n' ' ' | sed 's/ $//')"
if [ -n "$DECLARED_SECRETS" ] && [ "$DECLARED_SECRETS" = "$CREATED_SECRETS" ]; then
  pass "init-file-secrets.sh creates exactly the files compose.secrets.yaml declares"
else
  fail "init-file-secrets.sh creates exactly the files compose.secrets.yaml declares" \
       "overlay declares [${DECLARED_SECRETS}]; the script created [${CREATED_SECRETS}]"
fi
# update.sh must run that repair BEFORE it stops anything, or the guard is just a
# nicer error message printed during an outage.
# Anchored to the START of a line, so the header comment that merely MENTIONS
# `docker compose up -d` is not mistaken for the command itself — the first
# version of this row compared the guard against a comment on line 7 and failed
# on a correct script.
if grep -q 'SECRET-FILE PREFLIGHT' scripts/update.sh \
   && [ "$(grep -n 'SECRET-FILE PREFLIGHT' scripts/update.sh | head -1 | cut -d: -f1)" \
        -lt "$(grep -n '^docker compose up -d' scripts/update.sh | head -1 | cut -d: -f1)" ]; then
  pass "update.sh repairs secret files before it restarts anything"
else
  fail "update.sh repairs secret files before it restarts anything"
fi
rm -rf "$OLD_SECRET_DIR"

head2 "A4c. SECRET CONTAINMENT — every secret class, not just the Pretorin key"
# Phase 3 canaried PRETORIN_API_KEY across the rendered config, the state volume,
# the image layers and the container logs. Phase 5 adds two more classes and they
# get the same treatment, because "the container never holds git credentials" is a
# claim this repository makes and an unasserted claim is not a gate.
#
# Slack tokens DO reach the container environment (that is how OpenClaw reads
# them) but must never be written to disk. The GitHub App private key must not
# reach the container at all — not the filesystem, not the environment.
SLACK_CANARY_BOT="CANARY-SLACK-BOT-7c1e9f2a4b"
SLACK_CANARY_APP="CANARY-SLACK-APP-3d8b6a5e0c"

# Config on disk: the Slack block must name no token at all, not even a ${VAR}.
hasnt "config holds no Slack bot token value"   "xoxb-" "$CFG"
hasnt "config holds no Slack app token value"   "xapp-" "$CFG"
# The SUBSTITUTION MARKER, not the bare name: the template's own comments mention
# SLACK_BOT_TOKEN by name to explain why it is deliberately absent, and matching
# that is a false positive. `${SLACK_BOT_TOKEN}` is what an actual config
# reference would look like.
hasnt "config holds no Slack token substitution" '${SLACK_BOT_TOKEN}' "$CFG"
hasnt "config holds no Slack app-token substitution" '${SLACK_APP_TOKEN}' "$CFG"

# The whole state volume, with canary values actually present as credentials.
#
# INJECTED THE WAY THE DEPLOYMENT SUPPLIES THEM, which differs by path. Passing
# `-e SLACK_BOT_TOKEN=...` while compose also mounts SLACK_BOT_TOKEN_FILE is a
# DUAL SOURCE, and the entrypoint refuses it by design — so on the file-secret
# path the old env-var injection made the container exit before the grep ever ran.
# The probe then reported "N file(s) contain a canary token" about a probe that
# had not executed. Correct refusal, wrong injection, and a failure message that
# described the opposite of what happened. Found by the credentialed acceptance
# run; this is the property most worth proving on the path the README recommends.
CANARY_RC=0
if printf '%s' "${COMPOSE_FILE:-}" | grep -q 'compose\.secrets\.yaml'; then
  # Canaries go in FILES, in a throwaway secret dir compose resolves at run time.
  CANARY_DIR="$(mktemp -d)"
  cp "${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}"/* "$CANARY_DIR"/ 2>/dev/null || true
  printf '%s' "$SLACK_CANARY_BOT" > "${CANARY_DIR}/slack-bot-token"
  printf '%s' "$SLACK_CANARY_APP" > "${CANARY_DIR}/slack-app-token"
  chmod 600 "$CANARY_DIR"/* 2>/dev/null || true
  CANARY_HITS="$(COMPLIANCE_CLAW_SECRET_DIR="$CANARY_DIR" docker compose run --rm -T \
    cli bash -c 'grep -rl "CANARY-SLACK-" /home/node/.openclaw /home/node/.pretorin 2>/dev/null | wc -l' \
    2>/dev/null | tr -d ' \r\n')" || CANARY_RC=$?
  rm -rf "$CANARY_DIR"
else
  CANARY_HITS="$(docker compose run --rm -T \
    -e SLACK_BOT_TOKEN="$SLACK_CANARY_BOT" -e SLACK_APP_TOKEN="$SLACK_CANARY_APP" \
    cli bash -c 'grep -rl "CANARY-SLACK-" /home/node/.openclaw /home/node/.pretorin 2>/dev/null | wc -l' \
    2>/dev/null | tr -d ' \r\n')" || CANARY_RC=$?
fi
# THREE OUTCOMES, NOT TWO. "the probe did not run" is not "the volume is clean",
# and it is not "the volume is dirty" either — it has to say so itself.
if [ "$CANARY_RC" != 0 ] || [ -z "${CANARY_HITS:-}" ]; then
  fail "no Slack token value anywhere in either state volume" \
       "the probe did not run (container exit ${CANARY_RC}); this proves nothing either way"
elif [ "$CANARY_HITS" = 0 ]; then
  pass "no Slack token value anywhere in either state volume"
else
  fail "no Slack token value anywhere in either state volume" "${CANARY_HITS} file(s) contain a canary token"
fi

# Image layers. `docker history` plus a filesystem sweep of the paths a secret
# could plausibly have been copied into.
IMG="$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(list(json.load(sys.stdin)["services"].values())[0]["image"])')"
ok "no .env baked into the image" \
   bash -c "docker run --rm --entrypoint bash '$IMG' -lc '! test -e /app/.env && ! test -e /opt/compliance-claw/.env'"
ok "no PEM private key anywhere in the image" \
   bash -c "docker run --rm --entrypoint bash '$IMG' -lc '! grep -rl \"BEGIN RSA PRIVATE KEY\" /opt/compliance-claw /app/skills 2>/dev/null | grep -q .'"
ok "no secrets/ directory in the image" \
   bash -c "docker run --rm --entrypoint bash '$IMG' -lc '! test -d /opt/compliance-claw/secrets && ! test -d /secrets'"
# The GitHub App key is host-only by design. Nothing mounts it, so it must be
# absent from a running container even when it exists on the host.
ok "the GitHub App key is not visible inside the container" \
   cli bash -c '! find / -maxdepth 4 -name "*.pem" 2>/dev/null | grep -qv "^/usr/lib\|^/etc/ssl\|node_modules"'
LOGCANARY="$(printf '%s' "$LOGS" | grep -c 'CANARY-SLACK-' || true)"
[ "${LOGCANARY:-0}" = 0 ] && pass "no Slack token value in the gateway logs" \
  || fail "no Slack token value in the gateway logs" "${LOGCANARY} line(s)"

head2 "A5. mount posture"
notok "targets are read-only in-container" cli touch /workspace/targets/smoke-canary
ok    "state volume is writable"           cli touch /home/node/.openclaw/.smoke-canary
ok    "pretorin state volume is writable"  cli touch /home/node/.pretorin/.smoke-canary
cli rm -f /home/node/.openclaw/.smoke-canary /home/node/.pretorin/.smoke-canary >/dev/null 2>&1
ok    "container runs as node"             bash -c '[ "$(docker compose run --rm -T cli id -un | tr -d "\r\n")" = node ]'

# THE TWO HALVES OF THE MAINTENANCE ALIAS, on the service that has it.
#
# `cli` deliberately has neither, so both are checked through the gateway. The
# assessment mount must stay read-only THERE too — it is the same container the
# agent runs in, and the row above only proves it for `cli`.
if [ "$GATEWAY_STARTED" = 1 ] || docker compose ps --status running --services 2>/dev/null | grep -qx openclaw; then
  notok "gateway: /workspace/targets is read-only (the assessment path)" \
        docker compose exec -T openclaw touch /workspace/targets/.smoke-assess-canary
  if docker compose exec -T openclaw test -d /var/lib/compliance-claw/targets >/dev/null 2>&1; then
    if docker compose exec -T openclaw sh -c \
         'touch /var/lib/compliance-claw/targets/.smoke-maint-canary 2>/dev/null && rm -f /var/lib/compliance-claw/targets/.smoke-maint-canary'; then
      pass "gateway: the maintenance alias is writable (the sync path)"
    else
      # A bind mount carries the HOST directory's ownership, so a CI runner whose
      # uid is not 1000 cannot write it. That is an environment fact, not a
      # regression, and reporting it as a pass would be a lie either way.
      note "the maintenance alias is present but not writable by uid $(docker compose exec -T openclaw id -u 2>/dev/null | tr -d '\r\n') — host directory ownership, not a mount-posture regression"
    fi
  else
    fail "gateway: the maintenance alias is mounted" "/var/lib/compliance-claw/targets is absent"
  fi
  # efforts.yaml, NOT targets.yaml. It is the declaration of which repositories
  # exist and which effort each belongs to, so it is both the name validator and
  # the scope: a request can only address what its own effort declares.
  ok "gateway: efforts.yaml is mounted for name validation" \
     docker compose exec -T openclaw test -r /etc/compliance-claw/efforts.yaml
  notok "gateway: efforts.yaml is read-only" \
        docker compose exec -T openclaw sh -c 'echo x >> /etc/compliance-claw/efforts.yaml'
  # LEGACY SUPPORT, PROVED INSIDE THE CONTAINER. targets.yaml is still there and
  # still read-only, so a deployment that has not migrated keeps a working
  # /target-sync — but efforts.yaml above is what this deployment actually uses.
  ok "gateway: legacy targets.yaml is still mounted for unmigrated deployments" \
     docker compose exec -T openclaw test -r /etc/compliance-claw/targets.yaml
  notok "gateway: legacy targets.yaml is read-only" \
        docker compose exec -T openclaw sh -c 'echo x >> /etc/compliance-claw/targets.yaml'
  # AND IT IS NOT WHAT SCOPES A REQUEST. With efforts.yaml present the wrapper
  # selects it, so a target that exists only in targets.yaml is still refused.
  ok "gateway: efforts.yaml, not targets.yaml, is what a request is scoped to" \
     docker compose exec -T openclaw sh -c '
       /opt/compliance-claw/sync-targets.sh no-such-target 2>&1 |
         grep -q "/etc/compliance-claw/efforts.yaml"'
  docker compose exec -T openclaw rm -f /workspace/targets/.smoke-assess-canary >/dev/null 2>&1 || true

  # THE INPUT CONTRACT, INSIDE THE REAL CONTAINER. The self-test proves the rules;
  # this proves the rules are what a request actually reaches, through the same
  # binary and the same mounts the plugin uses.
  for bad_req in '--upload-pack=/bin/sh' '../etc' 'no-such-target' 'all extra'; do
    notok "gateway: sync refuses $(printf '%s' "$bad_req")" \
          docker compose exec -T openclaw /opt/compliance-claw/sync-targets.sh "$bad_req"
  done
  SYNC_REFUSAL="$(docker compose exec -T openclaw /opt/compliance-claw/sync-targets.sh no-such-target 2>/dev/null || true)"
  has "gateway: the refusal names efforts.yaml as the only source of names" \
      "not declared in /etc/compliance-claw/efforts.yaml" "$SYNC_REFUSAL"
  has "gateway: the refusal is machine-readable" "invalid_target" "$SYNC_REFUSAL"
else
  skip "gateway mount and sync-refusal checks" "the gateway is not running"
fi

head2 "A6. THE CWD FIX — the mcp-serve child's working directory"
CWD_OUT="$(inbox <<'EOF' 2>&1
set -u
nohup openclaw mcp probe pretorin >/tmp/smoke-probe.out 2>&1 &
for _ in $(seq 1 60); do
  for d in /proc/[0-9]*; do
    cl="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | sed 's/ *$//')"
    # Exact match, not a substring: the shell running this probe would otherwise
    # match itself, which is how the first version of this check lied.
    # (No apostrophes in this heredoc: bash 3.2 scans quotes inside a heredoc
    #  nested in $( ), so a contraction here breaks the enclosing parse.)
    if [ "$cl" = "/home/node/.pretorin/bin/pretorin mcp-serve" ]; then
      echo "CHILD_CWD=$(readlink "$d/cwd")"
      exit 0
    fi
  done
  sleep 0.25
done
echo "CHILD_NOT_FOUND"
EOF
)"
has   "mcp-serve child runs in the sentinel directory" "CHILD_CWD=/opt/compliance-claw/no-repo" "$CWD_OUT"
hasnt "mcp-serve child does NOT run in /app"           "CHILD_CWD=/app" "$CWD_OUT"
ok    "sentinel directory holds no repo and no markdown" \
      cli bash -c '! ls -A /opt/compliance-claw/no-repo | grep -qE "\.git$|\.md$"'

# TARGET SYNC MUST NOT HAVE MOVED ANYTHING INTO THAT TREE. Pretorin derives
# host-local source resolvers from the current directory, so a targets.yaml or a
# clone appearing anywhere under /opt/compliance-claw would be CWD-discoverable
# from the sentinel. That is exactly why they are mounted at /etc/... and
# /var/lib/... instead, and why this is asserted rather than left to the comment.
ok    "no targets.yaml under the sentinel tree" \
      cli bash -c '! find /opt/compliance-claw -maxdepth 2 -name targets.yaml | grep -q .'
ok    "no git repository under the sentinel tree" \
      cli bash -c '! find /opt/compliance-claw -maxdepth 3 -name .git | grep -q .'
ok    "the maintenance mount is NOT inside the sentinel tree" \
      bash -c 'case /var/lib/compliance-claw/targets in /opt/compliance-claw/*) exit 1 ;; *) exit 0 ;; esac'

head2 "A7. stale-template warning (warn only, never overwrites)"
CFG_BEFORE="$(val md5sum /home/node/.openclaw/openclaw.json | awk '{print $1}')"
cli bash -c 'printf "1\n" > /home/node/.openclaw/.compliance-claw-templates' >/dev/null 2>&1
W="$(cli pretorin version 2>&1 >/dev/null)"
has "older marker warns" "predates the image" "$W"
has "warning names the cwd consequence" "cwd" "$W"
has "warning names the reset command" "down -v" "$W"
has "warning states target repos survive" "Bind-mounted target repos are NOT touched" "$W"
cli bash -c 'printf "not-a-number\n" > /home/node/.openclaw/.compliance-claw-templates' >/dev/null 2>&1
W="$(cli pretorin version 2>&1 >/dev/null)"
has "corrupt marker warns instead of aborting" "predates the image" "$W"
ok   "corrupt marker does not break the command" cli pretorin version
cli bash -c "rm -f /home/node/.openclaw/.compliance-claw-templates" >/dev/null 2>&1
W="$(cli pretorin version 2>&1 >/dev/null)"
has "missing marker warns (a Phase 3 volume)" "predates the image" "$W"
cli bash -c "printf '%s\n' '${SHIPPED}' > /home/node/.openclaw/.compliance-claw-templates" >/dev/null 2>&1
W="$(cli pretorin version 2>&1 >/dev/null)"
hasnt "current marker is silent" "predates the image" "$W"
CFG_AFTER="$(val md5sum /home/node/.openclaw/openclaw.json | awk '{print $1}')"
[ "$CFG_BEFORE" = "$CFG_AFTER" ] && pass "config never modified by the warning path" \
  || fail "config never modified by the warning path" "md5 ${CFG_BEFORE} -> ${CFG_AFTER}"

head2 "A8. onboarding mechanics with NO credentials (scratch scope)"
SCRATCH_YAML="$(mktemp "${TMPDIR:-/tmp}/smoke-targets.XXXXXX")"
{
  printf 'system_id: %s\n' "$SCRATCH_SYS"
  printf 'framework_id: %s\n' "$SCRATCH_FW"
  printf 'targets:\n'
  # FOUR fields, in the order name/url/private/ref. Reading them in any other
  # order silently mangles the scratch file.
  while IFS=$'\t' read -r n u p r; do
    [ -n "$n" ] || continue
    printf '  - name: %s\n    url: %s\n' "$n" "$u"
    [ "$p" = "true" ] && printf '    private: true\n'
    [ -n "$r" ] && printf '    ref: %s\n' "$r"
  done < <(smoke_target_list)
} > "$SCRATCH_YAML"

# Pollute exactly the way the CWD bug would: a bare `preflight init` with no
# --workspace, from the MCP server's inherited /app.
cli pretorin preflight init --system "$SCRATCH_SYS" --framework "$SCRATCH_FW" --no-verify >/dev/null 2>&1
# ...plus a non-path resolver, which a path-blind sweep would destroy.
cli pretorin preflight bind code_hosting_platform --type cli_tool --name smoke-gh \
    --param probe='gh auth status' --system "$SCRATCH_SYS" --framework "$SCRATCH_FW" >/dev/null 2>&1
POLLUTED="$(val pretorin --json preflight show --system "$SCRATCH_SYS" --framework "$SCRATCH_FW")"
has "simulated /app resolver is present before onboarding" '"/app"' "$POLLUTED"

if TARGETS_FILE="$SCRATCH_YAML" bash scripts/onboard-targets.sh --local-only >/tmp/smoke-onboard.log 2>&1; then
  pass "onboard-targets.sh --local-only completes with no key"
else
  fail "onboard-targets.sh --local-only completes with no key" "$(tail -5 /tmp/smoke-onboard.log)"
fi
ONB="$(cat /tmp/smoke-onboard.log)"
has "onboarding reports the swept resolver" "unbinding code_repository resolver 'app'" "$ONB"

FINAL="$(val pretorin --json preflight show --system "$SCRATCH_SYS" --framework "$SCRATCH_FW")"
hasnt "no /app resolver survives onboarding"      '"/app"' "$FINAL"
hasnt "no /app/docs resolver survives onboarding" '/app/docs' "$FINAL"
has   "the target repo is bound"    "${FIRST_TARGET}" "$FINAL"
has   "the non-path resolver survived the sweep" "smoke-gh" "$FINAL"
if TARGETS_FILE="$SCRATCH_YAML" bash scripts/onboard-targets.sh --verify-only >/tmp/smoke-verify.log 2>&1; then
  pass "--verify-only asserts the state is correct"
else
  fail "--verify-only asserts the state is correct" "$(tail -8 /tmp/smoke-verify.log)"
fi
if TARGETS_FILE="$SCRATCH_YAML" bash scripts/onboard-targets.sh --local-only >>/tmp/smoke-onboard.log 2>&1; then
  RECOUNT="$(val pretorin --json preflight show --system "$SCRATCH_SYS" --framework "$SCRATCH_FW" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(k["resolvers"]) for k in d["kinds"]))')"
  BASE="$(printf '%s' "$FINAL" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(k["resolvers"]) for k in d["kinds"]))')"
  [ "$RECOUNT" = "$BASE" ] && pass "re-running onboarding is idempotent (${BASE} resolvers)" \
    || fail "re-running onboarding is idempotent" "${BASE} -> ${RECOUNT} resolvers"
else
  fail "re-running onboarding is idempotent" "second run failed"
fi

head2 "A9. bootstrap refuses to clobber (negative paths)"
NEG_YAML="$(mktemp "${TMPDIR:-/tmp}/smoke-neg.XXXXXX")"
mkdir -p workspace/targets/smoke-mismatch
SCRATCH_CLONES+=("workspace/targets/smoke-mismatch" "workspace/targets/smoke-broken")
git -C workspace/targets/smoke-mismatch init -q . >/dev/null 2>&1
git -C workspace/targets/smoke-mismatch remote add origin https://example.invalid/other.git
# AN EFFORTS FIXTURE, because efforts.yaml is what bootstrap now reads. A
# targets.yaml fixture here would be ignored, bootstrap would clone the real
# deployment's repositories instead, and the assertions below would be checking a
# refusal that came from somewhere else entirely.
# A CANONICAL UUID, not SCRATCH_SYS. efforts.yaml refuses a friendly system name
# outright — Pretorin compares a write's resolved target against the pinned scope
# literally, so a name there rejects writes to the very system it names. The value
# is never used against a platform here; it only has to satisfy the schema so the
# run reaches the clone logic these rows are actually about.
NEG_UUID="00000000-0000-4000-8000-00000000dead"
neg_efforts() {
  printf 'efforts:\n  - name: smoke-neg\n    system_id: %s\n    framework_id: %s\n    credential_ref: default\n    slack_channel_id: C0SMOKENEG\n    targets:\n      - name: %s\n        url: %s\n' \
    "$NEG_UUID" "$SCRATCH_FW" "$1" "$2" > "$NEG_YAML"
}
neg_efforts smoke-mismatch https://example.invalid/expected.git
OUT="$(CC_EFFORTS_FILE="$NEG_YAML" bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a clone whose origin differs" \
  || fail "bootstrap refuses a clone whose origin differs"
has "the refusal names both URLs" "on disk:" "$OUT"

mkdir -p workspace/targets/smoke-broken   # a directory that is not a repo
neg_efforts smoke-broken https://example.invalid/x.git
OUT="$(CC_EFFORTS_FILE="$NEG_YAML" bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a broken/partial clone" \
  || fail "bootstrap refuses a broken/partial clone"
has "the refusal explains it will not delete" "remove it yourself" "$OUT"
[ -d workspace/targets/smoke-broken ] && pass "bootstrap did not delete the broken clone" \
  || fail "bootstrap did not delete the broken clone"
rm -f "$NEG_YAML"

head2 "A9b. bootstrap does not seed the deployment, and does not eat overlays"
# STATIC, CHEAP, AND IN CI. The behavioural proof is
# scripts/test-fresh-slack-seed.sh, which builds a whole isolated deployment;
# these two rows cost nothing and fail the moment either property is reverted.
#
# 1. The image check must not START A CONTAINER. `docker compose run` goes
#    through the entrypoint and mounts the state volume, so it SEEDS
#    ~/.openclaw/openclaw.json — and seeding is write-if-absent and
#    never-clobber, so whatever it writes is what the deployment keeps. A fresh
#    deployment ended up permanently Slack-less exactly this way.
# `^[^#]*` so the COMMENT that documents the old command — deliberately kept,
# because the reason it was removed is worth reading — is not mistaken for the
# command itself. The first version of this row failed on the fixed script.
if grep -qE '^[^#]*docker compose run .*(uname|arch)' scripts/bootstrap.sh; then
  fail "bootstrap validates the image without starting a container" \
       "the architecture check runs a container, which seeds configuration before credentials are in scope"
else
  pass "bootstrap validates the image without starting a container"
fi
ok "  and does so by inspection" \
   bash -c "grep -q 'docker image inspect' scripts/bootstrap.sh"

# 2. --build must APPEND the build overlay, never rebuild COMPOSE_FILE. The
#    replacement form silently dropped compose.secrets.yaml, which is how the
#    seed above could not see the Slack tokens.
if grep -qE '^\s*export COMPOSE_FILE="compose\.yaml:compose\.build\.yaml"' scripts/bootstrap.sh; then
  fail "bootstrap --build preserves operator-selected overlays" \
       "COMPOSE_FILE is assigned by replacement, which discards compose.secrets.yaml"
else
  pass "bootstrap --build preserves operator-selected overlays"
fi

head2 "A10. bootstrap is idempotent and never overwrites .env"
# Chosen by availability, not by exit code: a missing md5sum still leaves awk
# exiting 0, so an `||` chain silently returns an empty digest and every
# comparison passes vacuously. That is how this check first "passed" on macOS.
if command -v md5sum >/dev/null 2>&1; then
  digest() { md5sum "$1" | awk '{print $1}'; }
elif command -v md5 >/dev/null 2>&1; then
  digest() { md5 -q "$1"; }
else
  digest() { echo "no-md5-tool"; }
fi
if [ -e .env ]; then
  # PATH-AWARE, because the two credential paths want OPPOSITE things here and a
  # single assertion cannot be right for both. On the recommended file-secret path
  # a token VALUE in .env is a defect — the entrypoint refuses a dual source — and
  # bootstrap deliberately writes the key with an empty value. On the legacy path
  # the value in .env is the whole mechanism. Asserting "a token is present"
  # unconditionally is what made the acceptance run fail on the path the README
  # now recommends.
  if printf '%s' "${COMPOSE_FILE:-}" | grep -q 'compose\.secrets\.yaml'; then
    if grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env; then
      fail ".env carries NO gateway token value (file-secret path)" \
           "a value is in .env AND a file is mounted; the entrypoint refuses that dual source"
    else
      pass ".env carries NO gateway token value (file-secret path)"
    fi
    if [ -s "${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}/openclaw-gateway-token" ]; then
      pass "the gateway token lives in the mounted secret file instead"
    else
      fail "the gateway token lives in the mounted secret file instead" \
           "neither .env nor the secret file carries a token; the gateway would exit 1"
    fi
  else
    grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env && pass ".env carries a gateway token (legacy path)" \
      || fail ".env carries a gateway token (legacy path)"
  fi
  ENV_BEFORE="$(digest .env)"
  HEAD_BEFORE="$(git -C "workspace/targets/${FIRST_TARGET}" rev-parse HEAD)"
  if OUT="$(bash scripts/bootstrap.sh 2>&1)"; then
    pass "bootstrap re-run succeeds"
    has "bootstrap keeps the existing .env" "keeping it" "$OUT"
    has "bootstrap fetches instead of cloning" "updating ${FIRST_TARGET}" "$OUT"
  else
    fail "bootstrap re-run succeeds" "$(printf '%s' "$OUT" | tail -5)"
  fi
  # Asserted AFTER the run, because tightening a loose mode is something
  # bootstrap DOES rather than something it merely expects.
  # GNU first: on GNU coreutils `stat -f` is filesystem status and succeeds,
  # so a BSD-first chain never reaches its fallback.
  MODE="$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null || echo '?')"
  [ "$MODE" = "600" ] && pass ".env mode is 600 after bootstrap" \
    || fail ".env mode is 600 after bootstrap" "found ${MODE}"
  [ "$(digest .env)" = "$ENV_BEFORE" ] && pass ".env byte-identical after a bootstrap re-run" \
    || fail ".env byte-identical after a bootstrap re-run"
  [ "$(git -C "workspace/targets/${FIRST_TARGET}" rev-parse HEAD)" = "$HEAD_BEFORE" ] \
    && pass "target clone unchanged by a bootstrap re-run" \
    || note "target clone moved — upstream advanced, which is a fetch working, not a failure"
else
  skip ".env and bootstrap idempotency checks" "no .env present; run scripts/bootstrap.sh first"
fi

head2 "A11. private targets refuse rather than prompt (negative paths)"
# Mirrors A9's shape: the interesting behaviour of the private path is its
# refusals, and all three of them are reachable with no credentials at all.
PRIV_YAML="$(mktemp "${TMPDIR:-/tmp}/smoke-priv.XXXXXX")"
# AN EFFORTS FIXTURE, because bootstrap reads efforts.yaml now. A targets.yaml
# fixture here would simply be ignored: bootstrap would fall through to the real
# efforts.yaml and every row below would be asserting on a refusal that came from
# somewhere else — or on no refusal at all, if that file declares nothing private.
priv_yaml() {
  printf 'efforts:\n  - name: smoke-priv\n    system_id: %s\n    framework_id: %s\n    credential_ref: default\n    slack_channel_id: C0SMOKEPRIV\n    targets:\n      - name: smoke-private\n        url: %s\n        private: true\n' \
    "$NEG_UUID" "$SCRATCH_FW" "${1:-https://github.com/pretorin-ai/does-not-exist.git}" > "$PRIV_YAML"
}

# THE CREDENTIAL LADDER IS TESTED WITH AN EMPTY SECRET DIRECTORY, deliberately.
# These cases are about what happens when a credential is ABSENT, so they must
# not accidentally pick up the operator's real PAT and pass for the wrong reason.
NOCRED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/smoke-nocred.XXXXXX")"

# 1. private target, no GitHub App and no PAT: refuse, naming both fixes.
priv_yaml
OUT="$(CC_EFFORTS_FILE="$PRIV_YAML" GITHUB_APP_ID= GITHUB_APP_PRIVATE_KEY_FILE= \
       COMPLIANCE_CLAW_SECRET_DIR="$NOCRED_DIR" \
       bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a private target with no credential at all" \
  || fail "bootstrap refuses a private target with no credential at all" "it succeeded"
has "the refusal names GITHUB_APP_ID" "GITHUB_APP_ID" "$OUT"
has "the refusal also names the PAT file" "github-readonly-pat" "$OUT"
hasnt "the refusal does not hang on a credential prompt" "Username for" "$OUT"

# 2. App id present, key file missing.
OUT="$(CC_EFFORTS_FILE="$PRIV_YAML" GITHUB_APP_ID=123456 \
       GITHUB_APP_PRIVATE_KEY_FILE=secrets/definitely-not-here.pem \
       COMPLIANCE_CLAW_SECRET_DIR="$NOCRED_DIR" \
       bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a private target with a missing key file" \
  || fail "bootstrap refuses a private target with a missing key file" "it succeeded"
has "the refusal names the key path" "definitely-not-here.pem" "$OUT"

# 2b. CLONE-ONLY, AND THE PRIVATE TARGET IS ALREADY CLONED.
#
# `clawctl apply` runs bootstrap this way: make missing clones exist, touch
# nothing that already does. A credential is therefore only needed for a clone
# that has to happen — demanding one for a private target already on disk would
# refuse an operation that contacts no network at all, on exactly the deployments
# where every private target is already present. Found by running it.
CLONE_ONLY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/smoke-cloneonly.XXXXXX")"
mkdir -p "${CLONE_ONLY_DIR}/targets/smoke-private"
git -C "${CLONE_ONLY_DIR}/targets/smoke-private" init -q . >/dev/null 2>&1
git -C "${CLONE_ONLY_DIR}/targets/smoke-private" remote add origin \
  https://github.com/pretorin-ai/does-not-exist.git
priv_yaml
OUT="$(CC_CLONE_ONLY=1 CC_TARGETS_DIR="${CLONE_ONLY_DIR}/targets" \
       CC_EFFORTS_FILE="$PRIV_YAML" GITHUB_APP_ID= GITHUB_APP_PRIVATE_KEY_FILE= \
       COMPLIANCE_CLAW_SECRET_DIR="$NOCRED_DIR" \
       bash scripts/bootstrap.sh --targets-only 2>&1)"; RC=$?
[ "$RC" = 0 ] && pass "clone-only needs NO credential when the private target is already cloned" \
  || fail "clone-only needs no credential when the private target is already cloned" \
         "$(printf '%s' "$OUT" | tail -3)"
hasnt "  and it does not fetch the existing clone" "updating smoke-private" "$OUT"
has   "  it says the clone was left where it is" "left at its current commit" "$OUT"

# ...and the credential is STILL required when the clone is genuinely missing,
# so the exemption above cannot become a way to skip the ladder.
rm -rf "${CLONE_ONLY_DIR}/targets/smoke-private"
OUT="$(CC_CLONE_ONLY=1 CC_TARGETS_DIR="${CLONE_ONLY_DIR}/targets" \
       CC_EFFORTS_FILE="$PRIV_YAML" GITHUB_APP_ID= GITHUB_APP_PRIVATE_KEY_FILE= \
       COMPLIANCE_CLAW_SECRET_DIR="$NOCRED_DIR" \
       bash scripts/bootstrap.sh --targets-only 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "  but a MISSING private clone still demands a credential" \
  || fail "  but a missing private clone still demands a credential" "it succeeded"
rm -rf "$CLONE_ONLY_DIR"

# 2b. NO SILENT DOWNGRADE. An App that is configured but broken must NOT fall
#     through to the PAT, even when a perfectly good PAT is sitting right there.
#     An operator who set up an App expects the App; quietly substituting a
#     longer-lived personal credential is the kind of downgrade nobody notices.
printf '%s' 'CANARY-PAT-SHOULD-NOT-BE-USED' > "${NOCRED_DIR}/github-readonly-pat"
chmod 600 "${NOCRED_DIR}/github-readonly-pat"
OUT="$(CC_EFFORTS_FILE="$PRIV_YAML" GITHUB_APP_ID=123456 \
       GITHUB_APP_PRIVATE_KEY_FILE=secrets/definitely-not-here.pem \
       COMPLIANCE_CLAW_SECRET_DIR="$NOCRED_DIR" \
       bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "a broken GitHub App does NOT silently fall back to the PAT" \
  || fail "a broken GitHub App does NOT silently fall back to the PAT" "it succeeded"
hasnt "  and the refusal used no PAT" "fine-grained PAT from" "$OUT"
has   "  and it says why it will not fall back" "will NOT fall back" "$OUT"
hasnt "  and no token value was printed" "CANARY-PAT-SHOULD-NOT-BE-USED" "$OUT"

# 2c. NO App, PAT present: the pilot path is taken, said out loud, and the value
#     is never printed. The clone still fails (the repository does not exist and
#     the token is fake) — what is asserted here is WHICH credential was chosen.
OUT="$(CC_EFFORTS_FILE="$PRIV_YAML" GITHUB_APP_ID= GITHUB_APP_PRIVATE_KEY_FILE= \
       COMPLIANCE_CLAW_SECRET_DIR="$NOCRED_DIR" \
       bash scripts/bootstrap.sh 2>&1)"; RC=$?
has   "with no App, a present PAT is used for private targets" "fine-grained PAT from" "$OUT"
has   "  and the pilot-only status is stated on every run" "GitHub App is the recommended" "$OUT"
hasnt "  and the token value is never printed" "CANARY-PAT-SHOULD-NOT-BE-USED" "$OUT"
rm -rf "$NOCRED_DIR"

# 3. A private target must not be silently cloned anonymously.
[ ! -e workspace/targets/smoke-private ] \
  && pass "no clone was attempted for the refused private target" \
  || fail "no clone was attempted for the refused private target" "workspace/targets/smoke-private exists"

# 4. The parser rejects a private target that could never work.
notok "parser rejects private: true on a non-github host" \
  bash -c 'printf "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://gitlab.com/o/r.git\n    private: true\n" > '"$PRIV_YAML"' && python3 scripts/parse-targets.py list '"$PRIV_YAML"
notok "parser rejects a non-boolean private value" \
  bash -c 'printf "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://github.com/o/r.git\n    private: yes\n" > '"$PRIV_YAML"' && python3 scripts/parse-targets.py list '"$PRIV_YAML"
rm -f "$PRIV_YAML"

# 5. No clone under workspace/targets may carry a persisted git credential. This
#    is the assertion behind "the container never holds git credentials": the
#    clones are what the container actually sees.
LEAKS=0
for d in workspace/targets/*/; do
  [ -f "${d}.git/config" ] || continue
  if grep -qE 'x-access-token|ghs_|github_pat_|://[^/@]*:[^/@]*@' "${d}.git/config" 2>/dev/null; then
    LEAKS=$((LEAKS + 1))
    printf '        leak in %s.git/config\n' "$d"
  fi
done
[ "$LEAKS" = 0 ] && pass "no target clone has a credential in .git/config" \
  || fail "no target clone has a credential in .git/config" "${LEAKS} clone(s)"

head2 "A12. Slack seeds from a fresh volume with zero manual JSON"
# Runs against a THROWAWAY container, never the operator's volume: the whole claim
# is about what happens on a fresh seed, and the real volume is already seeded.
SLACK_IMG="$IMG"
slack_seed() {
  # $1.. -> -e flags; prints the seeded config state plus entrypoint stderr.
  #
  # NO --entrypoint OVERRIDE. The seeding this section exists to test IS the
  # entrypoint, so overriding it produces a container with no config at all and
  # every assertion below fails for a reason that has nothing to do with Slack.
  # The image's own ENTRYPOINT runs, seeds, then execs `tini -s -- bash -c ...`.
  docker run --rm --platform linux/amd64 "$@" "$SLACK_IMG" bash -c '
    grep -q "/opt/compliance-claw/plugins/slack" /home/node/.openclaw/openclaw.json \
      && echo "SLACK_IN_CONFIG=yes" || echo "SLACK_IN_CONFIG=no"
    openclaw --version >/dev/null 2>&1 && echo "STILL_WORKS=yes" || echo "STILL_WORKS=no"
    grep -c CANARY /home/node/.openclaw/openclaw.json 2>/dev/null | sed "s/^/CANARY_HITS=/"
  ' 2>&1
}
S_OK="$(slack_seed -e SLACK_BOT_TOKEN="$SLACK_CANARY_BOT" -e SLACK_APP_TOKEN="$SLACK_CANARY_APP" -e SLACK_CHANNEL_ID=C0SMOKE123)"
has  "fresh volume + 3 vars -> Slack is in the config" "SLACK_IN_CONFIG=yes" "$S_OK"
has  "  and the patch reports success"                 "Slack configured"    "$S_OK"
has  "  and no token value reached the config"         "CANARY_HITS=0"       "$S_OK"
ok   "  and the plugin loads from the image path" \
     bash -c "docker run --rm --platform linux/amd64 -e SLACK_BOT_TOKEN=x -e SLACK_APP_TOKEN=y -e SLACK_CHANNEL_ID=C0SMOKE123 '$SLACK_IMG' bash -c 'openclaw plugins inspect slack 2>/dev/null | grep -q \"^Status: loaded\"'"

S_NAME="$(slack_seed -e SLACK_BOT_TOKEN=x -e SLACK_APP_TOKEN=y -e SLACK_CHANNEL_ID='#a-channel-name')"
has  "channel NAME instead of ID is refused" "is not a Slack channel id" "$S_NAME"
has  "  and Slack is left unconfigured"      "SLACK_IN_CONFIG=no"        "$S_NAME"
has  "  and the container still works"       "STILL_WORKS=yes"           "$S_NAME"

S_INJ="$(slack_seed -e SLACK_BOT_TOKEN=x -e SLACK_APP_TOKEN=y -e SLACK_CHANNEL_ID='C123456","evil":{"x')"
has  "a channel id carrying JSON is refused before substitution" "not A-Z or 0-9" "$S_INJ"
has  "  and Slack is left unconfigured"                          "SLACK_IN_CONFIG=no" "$S_INJ"

S_PART="$(slack_seed -e SLACK_BOT_TOKEN=x -e SLACK_APP_TOKEN=y)"
has  "2-of-3 Slack vars warns instead of half-configuring" "only partially configured" "$S_PART"
has  "  and names what is missing"                         "SLACK_CHANNEL_ID"          "$S_PART"
has  "  and Slack is left unconfigured"                    "SLACK_IN_CONFIG=no"        "$S_PART"

S_NONE="$(slack_seed)"
hasnt "no Slack vars is silent (no warning)" "Slack"              "$S_NONE"
has   "  and the config is the Phase 4 baseline" "SLACK_IN_CONFIG=no" "$S_NONE"

# THE CRITICAL GAP this phase closes: an already-seeded volume plus Slack
# credentials used to be silent. Two passes over one throwaway volume.
T2_VOL="cc-smoke-t2-$$"
docker volume create "$T2_VOL" >/dev/null 2>&1
docker run --rm --platform linux/amd64 -v "$T2_VOL":/home/node/.openclaw \
  "$SLACK_IMG" bash -c true >/dev/null 2>&1
T2_OUT="$(docker run --rm --platform linux/amd64 -v "$T2_VOL":/home/node/.openclaw \
  -e SLACK_BOT_TOKEN=x -e SLACK_APP_TOKEN=y -e SLACK_CHANNEL_ID=C0SMOKE123 \
  "$SLACK_IMG" bash -c 'grep -c "plugins/slack" /home/node/.openclaw/openclaw.json || true' 2>&1)"
docker volume rm "$T2_VOL" >/dev/null 2>&1
has "existing config + Slack credentials warn specifically" "Slack credentials are supplied but NOT in this volume" "$T2_OUT"
has "  the warning offers the down -v reset"         "down -v"    "$T2_OUT"
has "  the warning offers the by-hand patch"         "config patch" "$T2_OUT"
hasnt "  and never-clobber still holds (config untouched)" "plugins/slack" "$(printf '%s' "$T2_OUT" | grep -v 'NOT in this volume')"

# ===========================================================================
head1 "SECTION B — credentialed integration test"
# ===========================================================================

if [ "$NO_CREDS" = 1 ]; then
  skip "entire credentialed section" "--no-creds was passed"
elif ! AUTH="$(val pretorin --json whoami)" \
     || ! printf '%s' "$AUTH" | grep -q '"authenticated": *true'; then
  skip "entire credentialed section" "PRETORIN_API_KEY is absent or does not authenticate"
else
  printf '  key authenticates; write posture stated for this run: %s\n' "$WRITE_POSTURE"

  head2 "B1. real onboarding against the declared scope"
  if bash scripts/onboard-targets.sh >/tmp/smoke-real-onboard.log 2>&1; then
    pass "onboard-targets.sh completes with a read-only key"
  else
    fail "onboard-targets.sh completes with a read-only key" "$(tail -8 /tmp/smoke-real-onboard.log)"
  fi
  RO="$(cat /tmp/smoke-real-onboard.log)"
  has "the platform source profile loaded (read scope is enough)" "Seeded platform recommendations" "$RO"
  has "active context set and validated" "active context set and valid" "$RO"

  head2 "B2. bound state is exactly targets.yaml"
  if bash scripts/onboard-targets.sh --verify-only >/tmp/smoke-real-verify.log 2>&1; then
    pass "--verify-only passes against the real scope"
  else
    fail "--verify-only passes against the real scope" "$(tail -10 /tmp/smoke-real-verify.log)"
  fi
  RV="$(cat /tmp/smoke-real-verify.log)"
  has   "every target resolver is connected" "connected" "$RV"
  has   "no resolver points outside the mount" "no /app resolver" "$RV"
  has   "degraded is reported as expected, not as failure" "EXPECTED for a local workspace" "$RV"
  ART="$(val pretorin --json preflight show --system "$SYSTEM_ID" --framework "$FRAMEWORK_ID")"
  hasnt "the real artifact has no /app resolver" '"/app"' "$ART"
  CTX="$(val pretorin --json context show)"
  has "active context is the targets.yaml system" "$SYSTEM_ID" "$CTX"

  head2 "B3. a read tool succeeds through MCP"
  if OUT="$(cli python3 /opt/compliance-claw/mcp-call.py list_frameworks 2>&1)"; then
    pass "list_frameworks returns through pretorin mcp-serve"
  else
    fail "list_frameworks returns through pretorin mcp-serve" "$(printf '%s' "$OUT" | tail -3)"
  fi

  head2 "B4. key scope decides write access — and nothing local does"
  # WHY THIS IS ASSERTED FROM BOTH SIDES.
  #
  # The design commitment is that Pretorin permissions are determined ENTIRELY by
  # the operator-supplied API key: Compliance Claw does not block writes and does
  # not filter tools by any local mode. A rejection is only evidence of that if
  # the same call SUCCEEDS with a write-enabled key — otherwise a local block
  # would look identical to a server-side one.
  #
  # So first prove nothing local is in the way, whatever the key is.
  if printf '%s' "$CFG_LIVE" | grep -q 'toolFilter'; then
    fail "no local tool filter is configured" "mcp.servers.pretorin.toolFilter is set; a rejection would be ambiguous"
  else
    pass "no local tool filter is configured"
  fi
  if printf '%s' "$CFG_LIVE" | grep -qE '"?deny"?[[:space:]]*:'; then
    fail "no local tools.deny is configured" "a deny list is set; a rejection would be ambiguous"
  else
    pass "no local tools.deny is configured"
  fi

  # ASSERTED POSITIVELY, not by the absence of output. "no flag means no write"
  # is a safety property, so it gets a row that passes for a stated reason rather
  # than a silence that could equally mean the block was skipped by accident.
  case "$WRITE_POSTURE" in
    unstated)
      WRITE_PROBE=""
      pass "no write posture stated -> no write probe executed (nothing was created)"
      skip "key-scope write probe" \
        "neither --expect-read-only nor --test-write-enabled was passed. This probe
        CREATES A REAL RECORD when the key can write, so it is never run on an
        unstated posture. Pass --expect-read-only for a read-only key." ;;
    read-only)    WRITE_PROBE=0 ;;
    write-enabled)
      WRITE_PROBE=1
      # Say it before doing it. The operator asked for this, but the record is
      # real and the announcement is what makes an accidental flag obvious.
      printf '  --test-write-enabled: about to attempt a REAL platform write (a risk record will be created)\n' ;;
  esac

  if [ -n "${WRITE_PROBE}" ]; then
    ARGS="$(python3 - "$SYSTEM_ID" "$FRAMEWORK_ID" <<'PY'
import json, sys
print(json.dumps({
    "system_id": sys.argv[1],
    "framework_id": sys.argv[2],
    "title": "compliance-claw smoke probe - key scope regression",
    "category": "operational",
}))
PY
)"
    OUT="$(cli python3 /opt/compliance-claw/mcp-call.py create_risk "$ARGS" 2>&1)"; RC=$?
    if [ "$WRITE_PROBE" = 0 ]; then
      # READ-ONLY KEY: the write must be refused, and refused BY PRETORIN.
      if [ "$RC" = 0 ]; then
        fail "read-only key: create_risk is rejected" \
             "IT SUCCEEDED — either the key is not read-only, or the platform did not enforce"
      elif [ "$RC" = 3 ]; then
        LOW="$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')"
        case "$LOW" in
          *permission*|*forbidden*|*unauthor*|*scope*|*403*|*not\ allowed*|*read-only*)
            pass "read-only key: create_risk rejected server-side on authorization" ;;
          *)
            note "create_risk was rejected but not visibly on authorization — INCONCLUSIVE"
            printf '        %s\n' "$(printf '%s' "$OUT" | head -2)" ;;
        esac
      else
        fail "read-only key: create_risk is rejected" \
             "transport failure (rc=${RC}), not a server verdict: $(printf '%s' "$OUT" | tail -2)"
      fi
    else
      # WRITE-ENABLED KEY: the SAME call must SUCCEED. This is the half that
      # proves the refusal above came from key scope and not from anything this
      # repo configures. It creates a real record, which is why it only runs on
      # an explicitly declared write key and never in CI.
      if [ "$RC" = 0 ]; then
        pass "write-enabled key: the same create_risk succeeds (a real record was created)"
      elif [ "$RC" = 3 ]; then
        fail "write-enabled key: the same create_risk succeeds" \
             "the platform REFUSED a declared write key: $(printf '%s' "$OUT" | head -2)"
      else
        fail "write-enabled key: the same create_risk succeeds" \
             "transport failure (rc=${RC}): $(printf '%s' "$OUT" | tail -2)"
      fi
    fi
  fi

  head2 "B5. mount posture still holds with credentials present"
  notok "targets still read-only" cli touch /workspace/targets/smoke-canary-2

  head2 "B6. agent turn with provenance (needs model credentials)"
  # The prompt deliberately does NOT contain the commit SHA or the remote URL.
  # The assertions below check for those exact values, read from git on the host,
  # so a response that merely echoes the prompt cannot pass. The first version of
  # this check looked for "a hex string" and "a filename-shaped token", which an
  # error message full of paths and hashes satisfied — it reported a pass while
  # the turn had actually died on ProviderAuthError.
  # RUN IT IN THE GATEWAY CONTAINER, not via `run --rm cli`.
  #
  # `openclaw agent` reaches the gateway over 127.0.0.1:18789. The `cli` service is
  # a SEPARATE container with nothing on its own loopback, so there the command
  # silently falls back to the embedded agent, whose model resolution is stricter
  # and dies with "Unknown model: ..." — it trips over agents.defaults.models, a
  # key OpenClaw writes into the config itself and that our template never sets.
  # Setting OPENCLAW_GATEWAY_URL does NOT fix it; resolution happens before
  # dispatch. `exec openclaw` works because there the gateway IS on localhost.
  #
  # This check used the `cli` path from the day it was written and could therefore
  # never have passed. It reported `skip` on every run — no credentials — so the
  # dead path stayed invisible, exactly like the plugin-banner grep did.
  REAL_SHA="$(git -C "workspace/targets/${FIRST_TARGET}" rev-parse HEAD)"
  REAL_URL="$(git -C "workspace/targets/${FIRST_TARGET}" remote get-url origin)"
  # `docker compose exec` DOES NOT INHERIT THE ENTRYPOINT'S EXPORTS. PID 1 reads
  # /run/secrets/* and exports them; an exec'd process is a new child of the
  # daemon, not of PID 1, so on the file-secret path OPENCLAW_GATEWAY_TOKEN is
  # simply unset here. The config resolves gateway.auth.token from ${VAR} at load
  # time, so `openclaw agent` then dies with
  #   GatewaySecretRefUnavailableError: gateway.auth.token is configured as a
  #   secret reference but is unavailable in this command path
  # BEFORE it ever reaches model resolution — which is why this looked like a
  # missing model key and was not one. Same defect class as the adapter marker,
  # and the reason docs/file-secrets.md now documents the exec footgun.
  #
  # Re-read the token from the mounted file INSIDE the container: the value never
  # crosses the docker CLI boundary and never lands in an exec environment on the
  # host. Falls through untouched on the legacy path, where env_file already
  # supplied it.
  CC_PROMPT="Select the ${FIRST_TARGET} target under /workspace/targets. Report its repository URL, its HEAD commit SHA, and one repository-relative file path you read. Do not call any Pretorin write tool."
  TURN="$(docker compose exec -T -e CC_PROMPT="$CC_PROMPT" openclaw sh -c '
    if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ] && [ -r /run/secrets/openclaw_gateway_token ]; then
      OPENCLAW_GATEWAY_TOKEN="$(cat /run/secrets/openclaw_gateway_token)"
      export OPENCLAW_GATEWAY_TOKEN
    fi
    openclaw agent --agent main -m "$CC_PROMPT"' 2>&1)"
  LOWT="$(printf '%s' "$TURN" | tr 'A-Z' 'a-z')"
  case "$LOWT" in
    *gatewaysecretrefunavailable*|*"secret reference but is unavailable"*)
      # NOT a credential problem: the turn could not even authenticate to the
      # gateway. Kept as its own branch so it can never be mistaken for "no model
      # key" again, which is exactly how it presented the first time.
      fail "agent turn reaches the gateway" \
           "gateway.auth.token did not resolve in the exec path; the token was not re-read from /run/secrets" ;;
    *providerautherror*|*failovererror*|*"missing-provider-auth"*|*"no api key"*|*"auth store"*|*"embedded fallback"*|*"no model"*|*"unknown model"*)
      skip "agent turn provenance check" \
           "no usable model credentials in this deployment (the turn never reached a model)" ;;
    *)
      P=0
      case "$TURN" in *"$REAL_URL"*) P=$((P+1)) ;; esac
      # Accept the abbreviated form too, but it must be THIS commit.
      case "$TURN" in *"$REAL_SHA"*|*"${REAL_SHA:0:7}"*) P=$((P+1)) ;; esac

      # THE PATH ASSERTION, done by resolving it rather than by guessing filenames.
      #
      # This used to be `for f in README.md docker-compose.yml dev.env`, which asked
      # "did the agent happen to pick one of three files I guessed?" — not the
      # property the criterion is about. It failed a perfectly correct answer of
      # `backend/app/auth.py`. What actually matters is that the reported path is
      # repository-relative AND resolves to a real file in the target, so that is
      # what is checked: every path-shaped token in the reply is tested against the
      # checkout on disk.
      FOUND_PATH=""
      for cand in $(printf '%s' "$TURN" | tr -d '`"'"'" | tr ' ,()[]' '\n' \
                    | grep -E '^[A-Za-z0-9_./-]+\.[A-Za-z0-9]+$' | sort -u); do
        case "$cand" in
          /*) continue ;;                       # absolute: not repository-relative
          *) [ -f "workspace/targets/${FIRST_TARGET}/${cand}" ] && { FOUND_PATH="$cand"; break; } ;;
        esac
      done
      [ -n "$FOUND_PATH" ] && P=$((P+1))

      # A container path instead of a repository-relative one is a distinct failure:
      # AGENTS.md tells the agent to report the repo-relative path, and evidence
      # carrying /workspace/targets/... is not reviewable by anyone who did not run
      # this container.
      case "$TURN" in
        *"/workspace/targets/"*)
          note "the reply mentions a /workspace/targets/ path; AGENTS.md asks for repository-relative paths" ;;
      esac

      if [ "$P" -ge 3 ]; then
        pass "agent response carries repo + commit + path provenance (path: ${FOUND_PATH})"
      else
        fail "agent response carries repo + commit + path provenance" \
             "matched ${P}/3: url=${REAL_URL} sha=${REAL_SHA:0:7} path=${FOUND_PATH:-<none resolved in the checkout>}; turn output was: $(printf '%s' "$TURN" | tail -3)"
      fi ;;
  esac
fi

# ===========================================================================
head1 "SUMMARY"
printf '  pass %d   fail %d   skip %d   note %d\n' "$PASS" "$FAIL" "$SKIP" "$WARN"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed checks:\n'
  for c in "${FAILED_CHECKS[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
printf '\nsmoke: all executed checks pass.\n'
exit 0
