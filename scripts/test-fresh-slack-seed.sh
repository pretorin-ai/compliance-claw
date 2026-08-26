#!/usr/bin/env bash
#
# test-fresh-slack-seed.sh — a FRESH deployment on the file-secret path must come
# up Slack-configured, with no manual patch.
#
#   export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.build.yaml
#   docker compose build cli
#   scripts/test-fresh-slack-seed.sh
#
# WHY THIS EXISTS AS ITS OWN GATE. The defect it guards was invisible to every
# test in this repository, and the reason is worth stating so the gap is not
# reopened:
#
#   - scripts/test-file-secrets.sh points bootstrap at an UNREACHABLE target on
#     purpose, so bootstrap dies at the clone and never reaches the image phase
#     where the defect lived.
#   - scripts/smoke.sh's Slack seeding rows invoke the image with `docker run`
#     directly, which is precise about the entrypoint but bypasses bootstrap.sh,
#     Compose, COMPOSE_FILE and the overlay stack entirely.
#
# Each was correct about its own subject. The defect lived in the INTERACTION
# between them: bootstrap rewriting COMPOSE_FILE, and then starting a container
# that seeded configuration before the operator's credentials were in scope.
#
# THE DEFECT, IN ORDER:
#   1. the operator exports compose.yaml:compose.secrets.yaml:compose.build.yaml
#   2. `bootstrap.sh --build` replaced that with compose.yaml:compose.build.yaml,
#      dropping the overlay that mounts the Slack tokens
#   3. its architecture probe ran `docker compose run --rm -T cli uname -m`,
#      which starts a container, runs the entrypoint and mounts the real state
#      volume — so it SEEDED ~/.openclaw/openclaw.json
#   4. that seed could not see the Slack tokens, so it wrote a Slack-less config
#   5. the gateway started later WITH the tokens, found a config already present,
#      and correctly refused to overwrite it (never-clobber, working as intended)
#
# Result: credentials present, Slack absent, permanently, with openclaw.json
# roughly 35 seconds older than the gateway container as the only evidence.
#
# ISOLATED AND CREDENTIAL-FREE. Its own Compose project, its own volumes, its own
# secret directory, canary token values, a derived port, and `down -v` on every
# exit path. It never touches the operator's project, volumes, containers or
# secrets, and it holds no real credential of any kind.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="cc-freshslack-$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-fresh-slack.XXXXXX")"
# Derived, not fixed: two isolated projects publishing one port collide, and the
# second one's health probe then gets answered by the first one's gateway.
PORT="$(( 19100 + ($$ % 400) ))"

CANARY_BOT="CANARY-FRESH-BOT-4a91c7"
CANARY_APP="CANARY-FRESH-APP-08b3de"
CANARY_CHANNEL="C0FRESHSEED1"
GATEWAY_TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
note() { printf '        %s\n' "$1"; }

# Everything this test creates, and nothing else. The operator's default project
# is never named here, so `down -v` cannot reach it.
cleanup() {
  local rc=$?
  set +e
  if [ -n "${KEEP_TMP:-}" ]; then
    printf 'fresh-slack-seed: KEEP_TMP set; logs left in %s\n' "$TMP" >&2
  fi
  COMPOSE_PROJECT_NAME="$PROJECT" CC_TEST_PORT="$PORT" \
  COMPLIANCE_CLAW_SECRET_DIR="${TMP}/secrets" \
  COMPOSE_FILE="$STACK" docker compose down -v >/dev/null 2>&1
  [ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"
  exit $rc
}

STACK="compose.yaml:compose.secrets.yaml:compose.build.yaml:compose.test.yaml"
trap cleanup EXIT INT TERM

printf '\n\033[1mfresh deployment, file-secret path: Slack must configure itself\033[0m\n'
printf '  project %s, port %s, secrets in %s\n\n' "$PROJECT" "$PORT" "${TMP}/secrets"

# --- the operator's starting state ------------------------------------------
# Canary values only. Slack is never contacted: the gateway is never started in
# this test, and the assertion is about what the SEED writes, not about whether
# a websocket connects.
mkdir -p "${TMP}/secrets"
chmod 700 "${TMP}/secrets"
printf '%s' "$CANARY_BOT"     > "${TMP}/secrets/slack-bot-token"
printf '%s' "$CANARY_APP"     > "${TMP}/secrets/slack-app-token"
printf '%s' "$GATEWAY_TOKEN"  > "${TMP}/secrets/openclaw-gateway-token"
for empty in pretorin-api-key openai-api-key anthropic-api-key github-readonly-pat; do
  : > "${TMP}/secrets/${empty}"
done
# Docker bind-mounts secrets and cannot remap uid, so the container user must be
# able to read them. Same rule as scripts/init-file-secrets.sh.
chmod 604 "${TMP}/secrets"/*

export COMPOSE_PROJECT_NAME="$PROJECT"
export CC_TEST_PORT="$PORT"
export COMPLIANCE_CLAW_SECRET_DIR="${TMP}/secrets"
export SLACK_CHANNEL_ID="$CANARY_CHANNEL"
# EXACTLY WHAT THE OPERATOR EXPORTS, in the order they export it. The build
# overlay is already present, which is the shape that triggered the defect:
# bootstrap saw it, decided to build, and then rewrote the whole variable.
export COMPOSE_FILE="$STACK"

# --- run the documented command ---------------------------------------------
# The real bootstrap, not a re-implementation of it. Targets come from the
# committed targets.yaml, so this clones or fetches the public target exactly as
# a first-time operator's run would.
BOOT_LOG="${TMP}/bootstrap.log"
bash scripts/bootstrap.sh --build >"$BOOT_LOG" 2>&1
BOOT_RC=$?

if [ "$BOOT_RC" -eq 0 ]; then
  ok "bootstrap --build completes on the file-secret path"
else
  bad "bootstrap --build completes on the file-secret path" "exit ${BOOT_RC}"
  tail -20 "$BOOT_LOG" | sed 's/^/        /'
fi

# --- 1. the overlay stack survived ------------------------------------------
# Asserted on what bootstrap PRINTS, because that is the value it exported for
# everything downstream. A run that dropped compose.secrets.yaml here is a run
# whose every later `docker compose` command was blind to the secrets.
# ANCHORED TO BOOTSTRAP'S OWN LINE. A bare `grep COMPOSE_FILE=` matched the
# static usage hint that init-file-secrets.sh prints — which always names the
# full recommended stack — so the first version of this check passed against the
# very build it was written to fail. A test that cannot fail is worse than none.
BOOT_STACK="$(grep -E '^bootstrap: +COMPOSE_FILE=' "$BOOT_LOG" | tail -1 | sed 's/.*COMPOSE_FILE=//')"
if [ -z "$BOOT_STACK" ]; then
  bad "bootstrap reported the Compose stack it selected" "no 'bootstrap: COMPOSE_FILE=' line"
else
  case "$BOOT_STACK" in
    *compose.secrets.yaml*) ok "bootstrap --build preserved the operator's file-secret overlay" ;;
    *) bad "bootstrap --build preserved the operator's file-secret overlay" \
           "it selected: ${BOOT_STACK}" ;;
  esac
  case "$BOOT_STACK" in
    *compose.test.yaml*) ok "  and every other selected overlay with it" ;;
    *) bad "  and every other selected overlay with it" "it selected: ${BOOT_STACK}" ;;
  esac
fi

# --- 2. it reached and completed the image phase ----------------------------
# Without this the two assertions above could pass vacuously on a run that died
# at the clone — which is exactly how the existing file-secret test misses this
# whole area.
# Deliberately accepts EITHER wording. This row's job is to prove the run got
# this far at all, so the rows below cannot pass vacuously on a bootstrap that
# died at the clone — which is precisely how the existing file-secret test never
# sees this code. The behavioural assertion is the next row, and row 3.
if grep -qE 'bootstrap: image (is|runs as) ' "$BOOT_LOG"; then
  ok "bootstrap reached and completed the image-validation phase"
else
  bad "bootstrap reached and completed the image-validation phase" \
      "no architecture line in the log; the defect's neighbourhood was never entered"
fi
if grep -q 'no container was started' "$BOOT_LOG"; then
  ok "  and validated the image by inspection rather than by running it"
else
  bad "  and validated the image by inspection rather than by running it" \
      "the architecture check started a container, which seeds configuration"
fi

# --- 3. NO deployment state was created -------------------------------------
# THE HEART OF IT. Bootstrap must leave the state volume untouched, because
# seeding is write-if-absent and never-clobber: whatever is written here is what
# the deployment keeps forever.
# Found by Compose's own project label, not by guessing at the separator.
# Compose joins project and volume with an UNDERSCORE; the first version of this
# check looked for a hyphen, found nothing, and cheerfully reported "no state
# volume at all" on a run that had just created one.
STATE_VOLUME="$(docker volume ls \
  --filter "label=com.docker.compose.project=${PROJECT}" \
  --format '{{.Name}}' 2>/dev/null | grep 'openclaw-state' | head -1)"
if [ -n "$STATE_VOLUME" ] && docker volume inspect "$STATE_VOLUME" >/dev/null 2>&1; then
  SEEDED_EARLY="$(docker run --rm --platform linux/amd64 \
    --mount "type=volume,src=${STATE_VOLUME},dst=/state" \
    --entrypoint sh alpine:3.20 -c 'test -f /state/openclaw.json && echo yes || echo no' 2>/dev/null \
    | tr -d '\r\n')"
  if [ "$SEEDED_EARLY" = no ]; then
    ok "bootstrap created no OpenClaw configuration"
  else
    bad "bootstrap created no OpenClaw configuration" \
        "openclaw.json already exists after bootstrap; the deployment is now stuck with it"
  fi
else
  ok "bootstrap created no OpenClaw configuration (no state volume at all)"
fi

# --- 4. the legitimate seed configures Slack, with no manual patch ----------
# One ordinary `run --rm cli`, which is the first thing the documented flow does
# after bootstrap. This is where the seed is SUPPOSED to happen, and by now the
# secrets overlay is in scope, so it can see the Slack tokens.
SEED_LOG="${TMP}/seed.log"
docker compose run --rm -T cli true >"$SEED_LOG" 2>&1
SEED_RC=$?
[ "$SEED_RC" -eq 0 ] || note "seeding container exit ${SEED_RC} (see below)"

CFG="$(docker compose run --rm -T cli cat /home/node/.openclaw/openclaw.json 2>/dev/null)"
if [ -n "$CFG" ]; then
  ok "the seeding step wrote a configuration"
else
  bad "the seeding step wrote a configuration" "$(tail -5 "$SEED_LOG")"
fi

# Structural, not a substring. "slack" appears in the config as a plugin id even
# when the CHANNEL is absent, so a substring match would report the bug as fixed.
# The question is specifically whether channels.slack exists and is enabled.
# ASKED OF OPENCLAW, NOT OF A PARSER WE WROTE.
#
# The seeded template is JSON5 with UNQUOTED KEYS, and `openclaw config patch`
# rewrites it as strict JSON only when it applies the Slack half. So the failure
# case — the unpatched file — is precisely the one Python's json module cannot
# read, and a stdlib parser reports the bug as "unreadable" rather than as "no
# Slack": the right verdict for the wrong reason, which is how a test starts
# lying later. Handling JSON5 by regex was tried and is not worth owning.
#
# `openclaw config get` is the runtime's own reader, so this asks the component
# that will actually act on the file.
SLACK_ENABLED="$(docker compose run --rm -T cli \
  openclaw config get channels.slack.enabled 2>/dev/null | tr -d '\r\n[:space:]')"
case "$SLACK_ENABLED" in
  true)  SLACK_ENABLED=yes ;;
  false|'' | null | undefined ) SLACK_ENABLED=no ;;
  *) SLACK_ENABLED="unexpected(${SLACK_ENABLED})" ;;
esac
if [ "$SLACK_ENABLED" = yes ]; then
  ok "the fresh configuration contains Slack, with no manual patch"
else
  bad "the fresh configuration contains Slack, with no manual patch" \
      "channels.slack is ${SLACK_ENABLED}: credentials are present and Slack is absent, permanently"
fi
case "$CFG" in
  *"$CANARY_CHANNEL"*) ok "  and the channel allowlist carries the supplied channel id" ;;
  *) bad "  and the channel allowlist carries the supplied channel id" ;;
esac
case "$CFG" in
  *"$CANARY_BOT"*|*"$CANARY_APP"*)
    bad "  and no Slack token value reached the config" "a canary token is in openclaw.json" ;;
  *) ok "  and no Slack token value reached the config" ;;
esac

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'fresh-slack-seed: PASS — a fresh file-secret deployment configures Slack by itself (%d checks)\n' "$PASS"
  exit 0
fi
printf 'fresh-slack-seed: FAIL — %d of %d checks\n' "$FAIL" "$((PASS + FAIL))"
exit 1
