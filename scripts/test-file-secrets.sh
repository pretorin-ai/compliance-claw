#!/usr/bin/env bash
# Credential-free regression test for the file-secret contract.
# Requires Docker and a locally built image containing the current entrypoint:
#
#   export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.build.yaml
#   docker compose build cli
#   scripts/test-file-secrets.sh compliance-claw:local
#
# Uses only fake canary values and an isolated Compose project. It never reads
# `.env`, starts Slack, calls Pretorin, or calls a model provider.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="${1:-compliance-claw:local}"
PROJECT="cc-file-secrets-test-$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-file-secrets-test.XXXXXX")"
VOL_OPENCLAW="${PROJECT}-openclaw"
VOL_PRETORIN="${PROJECT}-pretorin"
CANARY_PRETORIN="CANARY-PRETORIN-FILE-31f9a6"
CANARY_OPENAI="CANARY-OPENAI-FILE-7d2e4b"
CANARY_GATEWAY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

cleanup() {
  docker rm -f "${PROJECT}-runtime" >/dev/null 2>&1 || true
  docker volume rm "$VOL_OPENCLAW" "$VOL_PRETORIN" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "file-secret-test: image not found: ${IMAGE}" >&2; exit 1; }

mkdir -p "$TMP/secrets" "$TMP/targets"
chmod 700 "$TMP/secrets"
printf '%s' "$CANARY_PRETORIN" > "$TMP/secrets/pretorin-api-key"
printf '%s' "$CANARY_GATEWAY"  > "$TMP/secrets/openclaw-gateway-token"
printf '%s' ''                 > "$TMP/secrets/slack-app-token"
printf '%s' ''                 > "$TMP/secrets/slack-bot-token"
printf '%s' "$CANARY_OPENAI"  > "$TMP/secrets/openai-api-key"
printf '%s' ''                 > "$TMP/secrets/anthropic-api-key"
chmod 604 "$TMP/secrets"/*

docker volume create "$VOL_OPENCLAW" >/dev/null
docker volume create "$VOL_PRETORIN" >/dev/null

# Direct docker run keeps this gate independent of the operator's Compose files
# and `.env`. Paths and mounts match compose.secrets.yaml exactly.
docker run -d --platform linux/amd64 \
  --name "${PROJECT}-runtime" \
  -e PRETORIN_API_KEY_FILE=/run/secrets/pretorin_api_key \
  -e OPENCLAW_GATEWAY_TOKEN_FILE=/run/secrets/openclaw_gateway_token \
  -e SLACK_APP_TOKEN_FILE=/run/secrets/slack_app_token \
  -e SLACK_BOT_TOKEN_FILE=/run/secrets/slack_bot_token \
  -e OPENAI_API_KEY_FILE=/run/secrets/openai_api_key \
  -e ANTHROPIC_API_KEY_FILE=/run/secrets/anthropic_api_key \
  --mount "type=bind,src=${TMP}/secrets/pretorin-api-key,dst=/run/secrets/pretorin_api_key,readonly" \
  --mount "type=bind,src=${TMP}/secrets/openclaw-gateway-token,dst=/run/secrets/openclaw_gateway_token,readonly" \
  --mount "type=bind,src=${TMP}/secrets/slack-app-token,dst=/run/secrets/slack_app_token,readonly" \
  --mount "type=bind,src=${TMP}/secrets/slack-bot-token,dst=/run/secrets/slack_bot_token,readonly" \
  --mount "type=bind,src=${TMP}/secrets/openai-api-key,dst=/run/secrets/openai_api_key,readonly" \
  --mount "type=bind,src=${TMP}/secrets/anthropic-api-key,dst=/run/secrets/anthropic_api_key,readonly" \
  --mount "type=volume,src=${VOL_OPENCLAW},dst=/home/node/.openclaw" \
  --mount "type=volume,src=${VOL_PRETORIN},dst=/home/node/.pretorin" \
  --mount "type=bind,src=${TMP}/targets,dst=/workspace/targets,readonly" \
  "$IMAGE" bash -lc '
    test "$PRETORIN_API_KEY" = "CANARY-PRETORIN-FILE-31f9a6"
    test "$OPENAI_API_KEY" = "CANARY-OPENAI-FILE-7d2e4b"
    test "$OPENCLAW_GATEWAY_TOKEN" = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    sleep 300
  ' >/dev/null

sleep 1
docker inspect --format '{{.State.Running}}' "${PROJECT}-runtime" | grep -qx true

CONFIG_ENV="$(docker inspect --format '{{json .Config.Env}}' "${PROJECT}-runtime")"
case "$CONFIG_ENV" in
  *CANARY*|*"$CANARY_GATEWAY"*)
    echo "file-secret-test: FAIL — secret value appears in docker inspect" >&2
    exit 1 ;;
esac
printf '%s' "$CONFIG_ENV" | python3 -c '
import json,sys
env=json.load(sys.stdin)
direct=("PRETORIN_API_KEY=","OPENCLAW_GATEWAY_TOKEN=","SLACK_APP_TOKEN=","SLACK_BOT_TOKEN=","OPENAI_API_KEY=","ANTHROPIC_API_KEY=")
assert not any(item.startswith(direct) for item in env)
assert "PRETORIN_API_KEY_FILE=/run/secrets/pretorin_api_key" in env
assert "OPENCLAW_GATEWAY_TOKEN_FILE=/run/secrets/openclaw_gateway_token" in env
# The PAT is delivered as a MOUNT ONLY. Every other secret here is exported into
# PID 1 by the entrypoint, which unsandboxed tool execution then inherits; the
# git credential helper reads this one from its path instead. A *_FILE variable
# appearing here would mean somebody wired it into load_secret_file.
assert not any(item.startswith("GITHUB_READONLY_PAT") for item in env), \
    "the PAT must never be an environment variable, not even as a _FILE path"
'

# Ambiguous dual-source configuration must fail closed.
if docker run --rm --platform linux/amd64 \
  -e PRETORIN_API_KEY=direct-value \
  -e PRETORIN_API_KEY_FILE=/run/secrets/pretorin \
  --mount "type=bind,src=${TMP}/secrets/pretorin-api-key,dst=/run/secrets/pretorin,readonly" \
  "$IMAGE" pretorin version >"$TMP/conflict.log" 2>&1; then
  echo "file-secret-test: FAIL — direct and file values were both accepted" >&2
  exit 1
fi
grep -q 'both set' "$TMP/conflict.log"

# ===========================================================================
# DELIVERY MATRIX — each service sees exactly its allowed set, AND NOTHING MORE.
# ===========================================================================
#
# One workflow, different reach. Over-delivery is the failure this catches: it is
# invisible in normal operation (everything works, some container just holds a
# credential it never needed) and it is exactly the kind of thing that drifts when
# someone copies a service block.
#
# Read the EXPECTED sets from compose.secrets.yaml rather than restating them, so
# the test cannot pass while the compose file says something else. `docker compose
# config` is used only to read the wiring under test; no operator `.env` value
# reaches the containers below, which are still plain `docker run`.
echo "file-secret-test: checking the per-service delivery matrix"

MATRIX="$(COMPOSE_FILE=compose.yaml:compose.secrets.yaml \
          COMPOSE_PROJECT_NAME="${PROJECT}-matrix" \
          docker compose --profile cli config --format json 2>/dev/null \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for name in ("openclaw", "cli"):
    svc = d["services"][name]
    got = sorted(x["source"] for x in svc.get("secrets", []))
    print(name, ",".join(got))
')"
[ -n "$MATRIX" ] || { echo "file-secret-test: FAIL — could not render the compose secret matrix" >&2; exit 1; }
printf '%s\n' "$MATRIX" | sed 's/^/  wiring: /'

EXPECT_OPENCLAW="anthropic_api_key,github_readonly_pat,openai_api_key,openclaw_gateway_token,pretorin_api_key,slack_app_token,slack_bot_token"
EXPECT_CLI="pretorin_api_key,slack_app_token,slack_bot_token"
GOT_OPENCLAW="$(printf '%s\n' "$MATRIX" | awk '$1=="openclaw"{print $2}')"
GOT_CLI="$(printf '%s\n' "$MATRIX" | awk '$1=="cli"{print $2}')"

[ "$GOT_OPENCLAW" = "$EXPECT_OPENCLAW" ] || {
  echo "file-secret-test: FAIL — openclaw secret set changed" >&2
  echo "  expected: ${EXPECT_OPENCLAW}" >&2
  echo "  got     : ${GOT_OPENCLAW}" >&2
  exit 1
}
# The one that matters. A model key or the gateway token appearing here is
# over-delivery: `cli` runs no agent turns and starts no gateway.
[ "$GOT_CLI" = "$EXPECT_CLI" ] || {
  echo "file-secret-test: FAIL — cli secret set changed (over- or under-delivery)" >&2
  echo "  expected: ${EXPECT_CLI}" >&2
  echo "  got     : ${GOT_CLI}" >&2
  exit 1
}

# And prove it at RUNTIME, not just in the wiring: give a container exactly the
# `cli` set and assert the excluded credentials are genuinely absent from the
# process environment the entrypoint builds. Distinct canaries per file, so a
# leak names itself.
CANARY_SLACK_APP="CANARY-SLACKAPP-FILE-5c1d77"
CANARY_ANTHROPIC="CANARY-ANTHROPIC-FILE-9b3e02"
printf '%s' "$CANARY_SLACK_APP" > "$TMP/secrets/slack-app-token"
printf '%s' "$CANARY_ANTHROPIC" > "$TMP/secrets/anthropic-api-key"
chmod 604 "$TMP/secrets"/*

docker run --rm --platform linux/amd64 \
  -e PRETORIN_API_KEY_FILE=/run/secrets/pretorin_api_key \
  -e SLACK_APP_TOKEN_FILE=/run/secrets/slack_app_token \
  --mount "type=bind,src=${TMP}/secrets/pretorin-api-key,dst=/run/secrets/pretorin_api_key,readonly" \
  --mount "type=bind,src=${TMP}/secrets/slack-app-token,dst=/run/secrets/slack_app_token,readonly" \
  "$IMAGE" bash -c '
    set -e
    # Allowed: present.
    test "$PRETORIN_API_KEY" = "CANARY-PRETORIN-FILE-31f9a6"
    test "$SLACK_APP_TOKEN"  = "CANARY-SLACKAPP-FILE-5c1d77"
    # Excluded: must be unset AND their canaries must appear nowhere in the env.
    test -z "${OPENAI_API_KEY:-}"
    test -z "${ANTHROPIC_API_KEY:-}"
    test -z "${OPENCLAW_GATEWAY_TOKEN:-}"
    if env | grep -qE "CANARY-OPENAI|CANARY-ANTHROPIC|0123456789abcdef"; then
      echo "a credential outside the allowed set reached the environment" >&2
      exit 1
    fi
  ' >"$TMP/matrix-runtime.log" 2>&1 || {
    echo "file-secret-test: FAIL — the cli-shaped container did not see exactly its allowed set" >&2
    tail -5 "$TMP/matrix-runtime.log" >&2
    exit 1
  }

# The adapter is derived, not configured: no key visible -> device-login value;
# an OpenAI key visible -> the API-key value. Unset would make the whole config
# invalid, so the entrypoint must never leave it empty.
adapter_for() {
  docker run --rm --platform linux/amd64 "$@" "$IMAGE" \
    bash -c 'printf "%s" "${OPENAI_REQUEST_ADAPTER:-<unset>}"' 2>/dev/null | tail -1
}
A_NOKEY="$(adapter_for)"
A_KEY="$(adapter_for -e OPENAI_API_KEY_FILE=/run/secrets/openai_api_key \
  --mount "type=bind,src=${TMP}/secrets/openai-api-key,dst=/run/secrets/openai_api_key,readonly")"
printf '  adapter: no model key -> %s | openai key -> %s\n' "$A_NOKEY" "$A_KEY"
[ "$A_NOKEY" = "openai-chatgpt-responses" ] || {
  echo "file-secret-test: FAIL — adapter without a key should be openai-chatgpt-responses, got '${A_NOKEY}'" >&2; exit 1; }
[ "$A_KEY" = "openai-responses" ] || {
  echo "file-secret-test: FAIL — adapter with an OpenAI key should be openai-responses, got '${A_KEY}'" >&2; exit 1; }

# ===========================================================================
# FRESH BOOTSTRAP ON THE FILE-SECRET PATH
# ===========================================================================
#
# The regression this guards: bootstrap.sh used to generate a gateway token into
# .env unconditionally. On the file-secret path that is not merely redundant — the
# token is then supplied twice, the entrypoint refuses ("... and ..._FILE are both
# set"), and the gateway exits before serving. So the documented Quickstart has to
# produce a .env with NO secret values at all.
#
# Runs in a SCRATCH COPY of the repo, so the operator's real .env and
# secrets/runtime are never touched. bootstrap is allowed to fail at the target
# clone (the fixture points at a URL that cannot resolve) — everything under test
# happens before that, and stopping there keeps the test off the network.
echo "file-secret-test: checking a fresh bootstrap on the file-secret path"

SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH"
cp -R scripts "$SCRATCH/"
cp .env.example versions.env Dockerfile compose.yaml compose.secrets.yaml compose.build.yaml "$SCRATCH/"
# DELIBERATELY UNREACHABLE, AND THAT HAS A COST WORTH NAMING. Bootstrap dies at
# the clone, which is what keeps this gate fast, offline and credential-free —
# but it also means everything AFTER the target phase is never exercised here:
# the COMPOSE_FILE handling, the image validation, and whether bootstrap creates
# deployment state. A defect lived in exactly that region (a fresh file-secret
# deployment came up permanently Slack-less) and this file could not have seen
# it. scripts/test-fresh-slack-seed.sh covers that region on purpose; if you add
# a check here that needs bootstrap to COMPLETE, it belongs there instead.
cat > "$SCRATCH/targets.yaml" <<'FIXTURE'
system_id: 00000000-0000-0000-0000-000000000000
framework_id: soc2
targets:
  - name: unreachable-fixture
    url: https://github.invalid/pretorin-ai/does-not-exist.git
    ref: main
FIXTURE

# --- the file-secret path ---------------------------------------------------
( cd "$SCRATCH" && COMPOSE_FILE=compose.yaml:compose.secrets.yaml     bash scripts/bootstrap.sh >bootstrap-fs.log 2>&1 ) || true

[ -f "$SCRATCH/.env" ] || {
  echo "file-secret-test: FAIL — bootstrap wrote no .env on the file-secret path" >&2
  tail -15 "$SCRATCH/bootstrap-fs.log" >&2; exit 1; }

# THE ASSERTION. Every secret line must be present-but-empty: present so the
# operator can see what exists, empty so nothing collides with a mounted file.
if grep -qE '^(PRETORIN_API_KEY|OPENCLAW_GATEWAY_TOKEN|SLACK_APP_TOKEN|SLACK_BOT_TOKEN)=.+' "$SCRATCH/.env"; then
  echo "file-secret-test: FAIL — .env carries a secret value on the file-secret path:" >&2
  grep -nE '^(PRETORIN_API_KEY|OPENCLAW_GATEWAY_TOKEN|SLACK_APP_TOKEN|SLACK_BOT_TOKEN)=.+' "$SCRATCH/.env"     | sed 's/=.*/=<redacted>/' >&2
  exit 1
fi
echo "  .env holds no secret values"

# The gateway token still has to exist — just in its own file, generated.
grep -qE '^[0-9a-f]{64}$' "$SCRATCH/secrets/runtime/openclaw-gateway-token" || {
  echo "file-secret-test: FAIL — no generated gateway token in secrets/runtime/" >&2; exit 1; }
echo "  gateway token generated into secrets/runtime/openclaw-gateway-token"

for f in pretorin-api-key openclaw-gateway-token slack-app-token slack-bot-token          openai-api-key anthropic-api-key; do
  [ -f "$SCRATCH/secrets/runtime/$f" ] || {
    echo "file-secret-test: FAIL — secrets/runtime/${f} was not created" >&2; exit 1; }
done
echo "  all six secret files created"

# It must also SAY what is still missing, by name. A silent empty key file becomes
# an auth error three steps later, which is the worst place to learn it.
grep -q 'pretorin-api-key' "$SCRATCH/bootstrap-fs.log" || {
  echo "file-secret-test: FAIL — bootstrap did not name the still-empty pretorin-api-key" >&2
  tail -20 "$SCRATCH/bootstrap-fs.log" >&2; exit 1; }
echo "  bootstrap named the files still needing values"

# --- the legacy path, as a contrast ----------------------------------------
# Proves the branch is doing something: without the overlay selected, a token IS
# generated into .env. Without this, an accidental always-empty .env would pass.
rm -f "$SCRATCH/.env"
rm -rf "$SCRATCH/secrets"
( cd "$SCRATCH" && COMPOSE_FILE=compose.yaml     bash scripts/bootstrap.sh >bootstrap-legacy.log 2>&1 ) || true
grep -qE '^OPENCLAW_GATEWAY_TOKEN=[0-9a-f]{64}$' "$SCRATCH/.env" || {
  echo "file-secret-test: FAIL — the legacy path should still generate a token in .env" >&2
  tail -15 "$SCRATCH/bootstrap-legacy.log" >&2; exit 1; }
echo "  legacy path still generates a token in .env (branch is live, not vacuous)"

echo "file-secret-test: PASS — values loaded at runtime, absent from docker inspect, dual source refused,"
echo "                  delivery matrix holds per service, adapter derived per credential,"
echo "                  fresh bootstrap writes no .env secret on the file-secret path"
