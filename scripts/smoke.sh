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
PRIVATE_NAMES=()
# name/url/private/ref — private before ref, because tab is IFS whitespace and an
# absent ref would otherwise collapse the fields. See parse-targets.py.
while IFS=$'\t' read -r n _u p _r; do
  [ -n "$n" ] || continue
  TARGET_NAMES+=("$n")
  [ "$p" = "true" ] && PRIVATE_NAMES+=("$n")
done < <(python3 scripts/parse-targets.py list)
FIRST_TARGET="${TARGET_NAMES[0]}"

printf '\033[1mcompliance-claw smoke test\033[0m\n'
printf 'repo:    %s\n' "$REPO_ROOT"
printf 'scope:   %s / %s\n' "$SYSTEM_ID" "$FRAMEWORK_ID"
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
V="$(val pretorin version)"
# Read from versions.env rather than hardcoded here. Two literals in a test are
# two more places to forget on a bump — and a pin nothing reads is decoration, not
# a source of truth. OPENCLAW_VERSION in particular had no consumer at all until
# this line; the Dockerfile FROM carries the tag as a literal beside its digest.
# shellcheck disable=SC1091
. ./versions.env
has "pretorin matches versions.env (${PRETORIN_VERSION})" "$PRETORIN_VERSION" "$V"
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
  curl -fsS -m 5 http://127.0.0.1:18789/healthz >/dev/null 2>&1 \
    && pass "gateway answers /healthz on the published port" \
    || fail "gateway answers /healthz on the published port" "container healthy but the published port did not answer"
else
  skip "gateway answers /healthz on the published port" \
       "our container is not up; any reply on that port would come from another deployment"
fi

# Read once, up front: the expected plugin profile below is decided by what is
# actually in the config, and several later checks assert on the same text.
CFG="$(val cat /home/node/.openclaw/openclaw.json)"
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
    has "runtime plugin set is exactly 'slack' (Slack profile)" "slack" "$PLUGIN_NAMES"
    if [ "$PLUGIN_NAMES" = "slack" ]; then
      pass "no bundled plugin activates under the exclusive allowlist"
    else
      fail "no bundled plugin activates under the exclusive allowlist" "got: ${PLUGIN_NAMES}"
    fi
  else
    has "runtime plugin set is the 8 bundled (no-Slack profile)" "8 plugins" "$PLUGIN_LINE"
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
has "config registers the Pretorin MCP server" '/usr/local/bin/pretorin' "$CFG"
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
ok "compose.build.yaml restores the build path" \
   bash -c 'COMPOSE_FILE=compose.yaml:compose.build.yaml docker compose config --format json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)[\"services\"]
assert all(s.get(\"build\") for s in d.values()), \"a service has no build section\"
assert all(s[\"image\"]==\"compliance-claw:local\" for s in d.values()), \"image is not the local tag\"
"'

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

# The whole state volume, with canary values actually present in the environment.
CANARY_HITS="$(SLACK_BOT_TOKEN="$SLACK_CANARY_BOT" SLACK_APP_TOKEN="$SLACK_CANARY_APP" \
  docker compose run --rm -T \
    -e SLACK_BOT_TOKEN="$SLACK_CANARY_BOT" -e SLACK_APP_TOKEN="$SLACK_CANARY_APP" \
    cli bash -c 'grep -rl "CANARY-SLACK-" /home/node/.openclaw /home/node/.pretorin 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r\n')"
if [ "${CANARY_HITS:-x}" = 0 ]; then
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
NEG_YAML="$(mktemp "${TMPDIR:-/tmp}/smoke-neg.XXXXXX")"
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
priv_yaml() {
  printf 'system_id: %s\nframework_id: %s\ntargets:\n  - name: smoke-private\n    url: %s\n    private: true\n' \
    "$SCRATCH_SYS" "$SCRATCH_FW" "${1:-https://github.com/pretorin-ai/does-not-exist.git}" > "$PRIV_YAML"
}

# 1. private target, no GitHub App configured at all.
priv_yaml
OUT="$(TARGETS_FILE="$PRIV_YAML" GITHUB_APP_ID= GITHUB_APP_PRIVATE_KEY_FILE= \
       bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a private target with no GitHub App" \
  || fail "bootstrap refuses a private target with no GitHub App" "it succeeded"
has "the refusal names GITHUB_APP_ID" "GITHUB_APP_ID" "$OUT"
hasnt "the refusal does not hang on a credential prompt" "Username for" "$OUT"

# 2. App id present, key file missing.
OUT="$(TARGETS_FILE="$PRIV_YAML" GITHUB_APP_ID=123456 \
       GITHUB_APP_PRIVATE_KEY_FILE=secrets/definitely-not-here.pem \
       bash scripts/bootstrap.sh 2>&1)"; RC=$?
[ "$RC" != 0 ] && pass "bootstrap refuses a private target with a missing key file" \
  || fail "bootstrap refuses a private target with a missing key file" "it succeeded"
has "the refusal names the key path" "definitely-not-here.pem" "$OUT"

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
has "existing config + Slack env warns specifically" "Slack is configured in .env but NOT in this volume" "$T2_OUT"
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
  # FAIL SAFE ON AN ABSENT DECLARATION. This used to default to "read-only" when
  # PRETORIN_KEY_MODE was missing, which is backwards: the probe below CREATES A
  # REAL PLATFORM RECORD if the key turns out to be write-enabled, and a .env
  # written before Phase 4 has no such line at all (never-clobber means it is
  # never added retroactively). Observed exactly that — an undeclared,
  # write-enabled key, and the probe succeeded and created a risk.
  #
  # Absence of a declaration now means "do not do the irreversible thing".
  KEY_MODE="${PRETORIN_KEY_MODE:-$(grep -E '^PRETORIN_KEY_MODE=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')}"
  KEY_MODE="${KEY_MODE:-undeclared}"
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
  if [ "$KEY_MODE" = "undeclared" ]; then
    skip "write-tool rejection probe" \
      "PRETORIN_KEY_MODE is not set in .env. This probe CREATES A REAL RECORD if the
        key has write scope, so an undeclared key is never probed. Add
        PRETORIN_KEY_MODE=read-only to .env if that is what you are running."
  elif [ "$KEY_MODE" != "read-only" ]; then
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
  # The prompt deliberately does NOT contain the commit SHA or the remote URL.
  # The assertions below check for those exact values, read from git on the host,
  # so a response that merely echoes the prompt cannot pass. The first version of
  # this check looked for "a hex string" and "a filename-shaped token", which an
  # error message full of paths and hashes satisfied — it reported a pass while
  # the turn had actually died on ProviderAuthError.
  REAL_SHA="$(git -C "workspace/targets/${FIRST_TARGET}" rev-parse HEAD)"
  REAL_URL="$(git -C "workspace/targets/${FIRST_TARGET}" remote get-url origin)"
  TURN="$(cli openclaw agent --agent main -m \
    "Select the ${FIRST_TARGET} target under /workspace/targets. Report its repository URL, its HEAD commit SHA, and one repository-relative file path you read. Do not call any Pretorin write tool." 2>&1)"
  LOWT="$(printf '%s' "$TURN" | tr 'A-Z' 'a-z')"
  case "$LOWT" in
    *providerautherror*|*failovererror*|*"missing-provider-auth"*|*"no api key"*|*"auth store"*|*"embedded fallback"*)
      skip "agent turn provenance check" \
           "no usable model credentials in this deployment (the turn never reached a model)" ;;
    *)
      P=0
      case "$TURN" in *"$REAL_URL"*) P=$((P+1)) ;; esac
      # Accept the abbreviated form too, but it must be THIS commit.
      case "$TURN" in *"$REAL_SHA"*|*"${REAL_SHA:0:7}"*) P=$((P+1)) ;; esac
      # A path that exists in the target, quoted repository-relative.
      for f in README.md docker-compose.yml dev.env; do
        case "$TURN" in *"$f"*) P=$((P+1)); break ;; esac
      done
      if [ "$P" -ge 3 ]; then
        pass "agent response carries repo + commit + path provenance"
      else
        fail "agent response carries repo + commit + path provenance" \
             "matched ${P}/3: url=${REAL_URL} sha=${REAL_SHA:0:7}; turn output was: $(printf '%s' "$TURN" | tail -3)"
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
