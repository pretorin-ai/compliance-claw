#!/usr/bin/env bash
#
# smoke.sh — the Phase 4 verification gate, in two clearly separated sections.
#
#   SECTION A — no credentials. This is what CI runs. It proves the image, the
#               generated config, the mount posture, the stale-template warning,
#               and the CWD fix, all without a Pretorin key or a model key.
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
[ "${1:-}" = "--no-creds" ] && NO_CREDS=1

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

IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID < <(python3 scripts/parse-targets.py scope)
TARGET_NAMES=()
while IFS=$'\t' read -r n _u _r; do [ -n "$n" ] && TARGET_NAMES+=("$n"); done \
  < <(python3 scripts/parse-targets.py list)
FIRST_TARGET="${TARGET_NAMES[0]}"

printf '\033[1mcompliance-claw smoke test\033[0m\n'
printf 'repo:    %s\n' "$REPO_ROOT"
printf 'scope:   %s / %s\n' "$SYSTEM_ID" "$FRAMEWORK_ID"
printf 'targets: %s\n' "${TARGET_NAMES[*]}"

# ===========================================================================
head1 "SECTION A — no credentials (this is what CI runs)"
# ===========================================================================

head2 "A1. versions and supply chain"
V="$(val pretorin version)"
has "pretorin is the pinned 0.26.14" "0.26.14" "$V"
has "openclaw is the pinned 2026.7.1" "2026.7.1" "$(val openclaw --version)"
ok  "image runs as x86_64" bash -c '[ "$(docker compose run --rm -T cli uname -m | tr -d "\r\n")" = x86_64 ]'

head2 "A2. Pretorin MCP tool surface (mock-based, no key)"
S="$(val pretorin mcp-smoke-test)"
has "mcp-smoke-test passes" "PASSED" "$S"

head2 "A3. targets.yaml parser"
ok "parse-targets.py --self-test" python3 scripts/parse-targets.py --self-test

head2 "A4. gateway starts, config and templates are seeded"
if docker compose ps --status running --services 2>/dev/null | grep -qx openclaw; then
  note "gateway already running; leaving it up at the end"
else
  GATEWAY_STARTED=1
  docker compose up -d >/dev/null 2>&1
fi
READY=0
for _ in $(seq 1 60); do
  if curl -fsS -m 2 http://127.0.0.1:18789/healthz >/dev/null 2>&1; then READY=1; break; fi
  sleep 2
done
[ "$READY" = 1 ] && pass "gateway answers /healthz" || fail "gateway answers /healthz" "timed out after 120s"

LOGS="$(docker compose logs openclaw 2>&1 | tail -60)"
has   "runtime pin holds: 8 plugins" "8 plugins" "$LOGS"
PLUGIN_LINE="$(printf '%s' "$LOGS" | grep -o '([0-9]* plugins:[^)]*)' | tail -1)"
hasnt "codex plugin absent (agentRuntime pin active)" "codex" "$PLUGIN_LINE"

CFG="$(val cat /home/node/.openclaw/openclaw.json)"
has "config seeded into the state volume" 'gateway:' "$CFG"
has "config carries the MCP cwd fix" '/opt/compliance-claw/no-repo' "$CFG"
AG="$(val cat /home/node/.openclaw/workspace/AGENTS.md)"
has "AGENTS.md seeded" "Review targets" "$AG"
has "AGENTS.md requires target selection" "state which target" "$AG"
has "AGENTS.md requires provenance" "commit SHA" "$AG"
SHIPPED="$(val cat /opt/compliance-claw/config-template.version | tr -d '\n')"
STAMP_BACKUP="$(val cat /home/node/.openclaw/.compliance-claw-templates | tr -d '\n')"
if [ "$STAMP_BACKUP" = "$SHIPPED" ]; then
  pass "template marker written and current (v${SHIPPED})"
else
  fail "template marker written and current" "marker='${STAMP_BACKUP}' shipped='${SHIPPED}'"
fi

head2 "A5. mount posture"
notok "targets are read-only in-container" cli touch /workspace/targets/smoke-canary
ok    "state volume is writable"           cli touch /home/node/.openclaw/.smoke-canary
ok    "pretorin state volume is writable"  cli touch /home/node/.pretorin/.smoke-canary
cli rm -f /home/node/.openclaw/.smoke-canary /home/node/.pretorin/.smoke-canary >/dev/null 2>&1
ok    "container runs as node"             bash -c '[ "$(docker compose run --rm -T cli id -un | tr -d "\r\n")" = node ]'

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
    if [ "$cl" = "/usr/local/bin/pretorin mcp-serve" ]; then
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
SCRATCH_YAML="$(mktemp -t smoke-targets)"
{
  printf 'system_id: %s\n' "$SCRATCH_SYS"
  printf 'framework_id: %s\n' "$SCRATCH_FW"
  printf 'targets:\n'
  while IFS=$'\t' read -r n u r; do
    [ -n "$n" ] || continue
    printf '  - name: %s\n    url: %s\n' "$n" "$u"
    [ -n "$r" ] && printf '    ref: %s\n' "$r"
  done < <(python3 scripts/parse-targets.py list)
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
NEG_YAML="$(mktemp -t smoke-neg)"
mkdir -p workspace/targets/smoke-mismatch
SCRATCH_CLONES+=("workspace/targets/smoke-mismatch" "workspace/targets/smoke-broken")
git -C workspace/targets/smoke-mismatch init -q . >/dev/null 2>&1
git -C workspace/targets/smoke-mismatch remote add origin https://example.invalid/other.git
printf 'system_id: %s\nframework_id: %s\ntargets:\n  - name: smoke-mismatch\n    url: https://example.invalid/expected.git\n' \
  "$SCRATCH_SYS" "$SCRATCH_FW" > "$NEG_YAML"
OUT="$(TARGETS_FILE="$NEG_YAML" bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a clone whose origin differs" \
  || fail "bootstrap refuses a clone whose origin differs"
has "the refusal names both URLs" "on disk:" "$OUT"

mkdir -p workspace/targets/smoke-broken   # a directory that is not a repo
printf 'system_id: %s\nframework_id: %s\ntargets:\n  - name: smoke-broken\n    url: https://example.invalid/x.git\n' \
  "$SCRATCH_SYS" "$SCRATCH_FW" > "$NEG_YAML"
OUT="$(TARGETS_FILE="$NEG_YAML" bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a broken/partial clone" \
  || fail "bootstrap refuses a broken/partial clone"
has "the refusal explains it will not delete" "remove it yourself" "$OUT"
[ -d workspace/targets/smoke-broken ] && pass "bootstrap did not delete the broken clone" \
  || fail "bootstrap did not delete the broken clone"
rm -f "$NEG_YAML"

head2 "A10. bootstrap is idempotent and never overwrites .env"
digest() { md5sum "$1" 2>/dev/null | awk '{print $1}' || md5 -q "$1"; }
if [ -e .env ]; then
  grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env && pass ".env carries a gateway token" \
    || fail ".env carries a gateway token"
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
  MODE="$(stat -f '%Lp' .env 2>/dev/null || stat -c '%a' .env)"
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

# ===========================================================================
head1 "SECTION B — credentialed integration test"
# ===========================================================================

if [ "$NO_CREDS" = 1 ]; then
  skip "entire credentialed section" "--no-creds was passed"
elif ! AUTH="$(val pretorin --json whoami)" \
     || ! printf '%s' "$AUTH" | grep -q '"authenticated": *true'; then
  skip "entire credentialed section" "PRETORIN_API_KEY is absent or does not authenticate"
else
  KEY_MODE="${PRETORIN_KEY_MODE:-$(grep -E '^PRETORIN_KEY_MODE=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')}"
  KEY_MODE="${KEY_MODE:-read-only}"
  printf '  key authenticates; declared mode: %s\n' "$KEY_MODE"

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

  head2 "B4. a write tool is rejected server-side"
  if [ "$KEY_MODE" != "read-only" ]; then
    skip "write-tool rejection probe" "PRETORIN_KEY_MODE=${KEY_MODE}: a write-enabled key would CREATE a real record"
  else
    ARGS="$(python3 - "$SYSTEM_ID" "$FRAMEWORK_ID" <<'PY'
import json, sys
print(json.dumps({
    "system_id": sys.argv[1],
    "framework_id": sys.argv[2],
    "title": "compliance-claw smoke probe - read-only key must be rejected",
    "category": "operational",
}))
PY
)"
    OUT="$(cli python3 /opt/compliance-claw/mcp-call.py create_risk "$ARGS" 2>&1)"; RC=$?
    if [ "$RC" = 0 ]; then
      fail "create_risk is rejected" "IT SUCCEEDED — this key has write scope, or the platform did not enforce"
    elif [ "$RC" = 3 ]; then
      LOW="$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')"
      case "$LOW" in
        *permission*|*forbidden*|*unauthor*|*scope*|*403*|*not\ allowed*|*read-only*)
          pass "create_risk rejected server-side on authorization" ;;
        *)
          note "create_risk was rejected but not visibly on authorization — INCONCLUSIVE"
          printf '        %s\n' "$(printf '%s' "$OUT" | head -2)" ;;
      esac
    else
      fail "create_risk is rejected" "transport failure (rc=${RC}), not a server verdict: $(printf '%s' "$OUT" | tail -2)"
    fi
  fi

  head2 "B5. mount posture still holds with credentials present"
  notok "targets still read-only" cli touch /workspace/targets/smoke-canary-2

  head2 "B6. agent turn with provenance (needs model credentials)"
  TURN="$(cli openclaw agent --agent main 2>&1 -m \
    "Select the ${FIRST_TARGET} target under /workspace/targets. Report its repository URL, its HEAD commit SHA, and one repository-relative file path you read. Do not call any Pretorin write tool." 2>&1)"
  LOWT="$(printf '%s' "$TURN" | tr 'A-Z' 'a-z')"
  case "$LOWT" in
    *providerautherror*|*"auth store"*|*"not authenticated"*|*"no api key"*|*login*)
      skip "agent turn provenance check" "no usable model credentials in this deployment" ;;
    *)
      P=0
      case "$LOWT" in *"github.com/pretorin-ai/${FIRST_TARGET}"*|*"${FIRST_TARGET}.git"*) P=$((P+1)) ;; esac
      printf '%s' "$TURN" | grep -qE '\b[0-9a-f]{7,40}\b' && P=$((P+1))
      printf '%s' "$TURN" | grep -qE '\.(py|js|ts|go|rb|java|yml|yaml|md|json|tf|sh)\b' && P=$((P+1))
      [ "$P" -ge 3 ] && pass "agent response carries repo + commit + path provenance" \
        || fail "agent response carries repo + commit + path provenance" \
                "matched ${P}/3 provenance markers; see the turn output above" ;;
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
