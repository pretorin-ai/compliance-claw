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

echo "file-secret-test: PASS — values loaded at runtime, absent from docker inspect, dual source refused"
