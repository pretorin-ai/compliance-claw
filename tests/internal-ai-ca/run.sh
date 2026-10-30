#!/usr/bin/env bash
#
# tests/internal-ai-ca/run.sh — isolated check of the internal AI endpoint
# example in examples/internal-ai-ca/.
#
#   bash tests/internal-ai-ca/run.sh compliance-claw:local
#
# It uses the committed overlay and native config patch with a generated test
# CA, a mock OpenAI-compatible HTTPS endpoint and canary credentials, on an
# internal Docker network with no internet route. It checks that:
#
#   - the overlay keeps the state, target, secret and loopback-port settings
#     of the earlier Compose files, and fails closed without its CA setting;
#   - the patch needs the gateway's credential, so the cli dry run refuses it;
#   - with the approved CA, a gateway agent turn completes a TOOL round trip
#     (tool call, real tool execution, tool result, final answer);
#   - the same configuration rejects an endpoint certificate from another CA.
#
# It does not prove a real AI provider, real network, proxy or model quality.
# It writes only to its own Compose project and a temporary directory: the
# fixture overlay replaces both target mounts with an empty temporary directory.
# Run it from a disposable checkout, as for the other isolated tests.
set -euo pipefail

IMAGE="${1:?usage: run.sh IMAGE (for example compliance-claw:local)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Its own project and port, never inherited: CI and contributor shells can set
# COMPOSE_PROJECT_NAME for another stack, and cleanup below deletes volumes.
export COMPOSE_PROJECT_NAME="${INTERNAL_AI_TEST_PROJECT:-cc-internal-ai-ca}"
case "$COMPOSE_PROJECT_NAME" in
  compliance-claw|"") echo "internal-ai-ca: refusing project '${COMPOSE_PROJECT_NAME}': use a disposable name" >&2; exit 2 ;;
esac
export CC_TEST_PORT="${INTERNAL_AI_TEST_PORT:-18988}"
export COMPOSE_PATH_SEPARATOR=:
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.test.yaml:examples/internal-ai-ca/compose.internal-ai-ca.yaml:tests/internal-ai-ca/compose.fixture.yaml
export INTERNAL_AI_TEST_IMAGE="$IMAGE"
export INTERNAL_AI_TEST_CERT_SET=approved
unset COMPOSE_PROFILES CC_EFFORTS_FILE CC_TARGETS_DIR

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-internal-ai-ca.XXXXXX")"
# The container user (UID 1000) must enter it on a host where the runner is not UID 1000.
chmod 0755 "$TMP"
export INTERNAL_AI_TEST_DIR="$TMP"
export COMPLIANCE_CLAW_SECRET_DIR="$TMP/secrets"
export INTERNAL_AI_CA_FILE="$TMP/internal-ai-ca.pem"
FAILED=0

log() { printf 'internal-ai-ca: %s\n' "$*"; }
fail() {
  log "FAIL — $*"
  FAILED=1
}

cleanup() {
  local rc=$?
  if [ "$FAILED" != 0 ] || [ "$rc" != 0 ]; then
    log "gateway log tail:"
    docker compose logs --tail 60 openclaw 2>&1 | sed 's/^/  /' || true
    log "mock endpoint log:"
    docker compose logs mock-ai 2>&1 | sed 's/^/  /' || true
  fi
  docker compose --profile '*' down -v --remove-orphans >/dev/null 2>&1 || true
  # Files given to the container user can belong to another host UID.
  docker run --rm --platform linux/amd64 --network none --user 0 --entrypoint rm \
    -v "$TMP:/fixture" "$IMAGE" -rf /fixture/secrets /fixture/internal-ai-ca.pem >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- Test CAs and endpoint certificates ------------------------------------
mkdir -p "$TMP/ca" "$TMP/certs/approved" "$TMP/certs/untrusted" "$TMP/secrets" "$TMP/targets"
printf 'subjectAltName=DNS:ai.internal.test\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
  > "$TMP/ca/server.ext"
for set in approved untrusted; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Fixture ${set} test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$TMP/ca/${set}-ca.key" -out "$TMP/ca/${set}-ca.pem" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=ai.internal.test" \
    -keyout "$TMP/certs/${set}/server.key" -out "$TMP/ca/${set}.csr" 2>/dev/null
  openssl x509 -req -days 2 -in "$TMP/ca/${set}.csr" -CA "$TMP/ca/${set}-ca.pem" \
    -CAkey "$TMP/ca/${set}-ca.key" -CAcreateserial -extfile "$TMP/ca/server.ext" \
    -out "$TMP/certs/${set}/server.crt" 2>/dev/null
done
chmod 0644 "$TMP"/certs/*/server.key

# --- Canary secret files and the CA file ------------------------------------
for name in pretorin-api-key openclaw-gateway-password slack-app-token slack-bot-token \
  openai-api-key anthropic-api-key github-readonly-pat; do
  : > "$TMP/secrets/$name"
done
printf '%s\n' canary-internal-ai-gateway-token-test-only > "$TMP/secrets/openclaw-gateway-token"
printf '%s\n' canary-internal-ai-api-key-test-only > "$TMP/secrets/internal-ai-api-key"
cp "$TMP/ca/approved-ca.pem" "$INTERNAL_AI_CA_FILE"
chmod 0604 "$TMP"/secrets/*
# OpenClaw file SecretRef providers require a private file that belongs to the
# process user: UID 1000, mode 0400. This is the documented VM setting.
chmod 0400 "$TMP/secrets/internal-ai-api-key" "$INTERNAL_AI_CA_FILE"
# Docker Desktop already shows bind-mounted files as UID 1000 and refuses chown.
owner="$(docker run --rm --platform linux/amd64 --network none --entrypoint stat \
  -v "$TMP:/fixture:ro" "$IMAGE" -c %u /fixture/internal-ai-ca.pem)"
if [ "$owner" != 1000 ]; then
  docker run --rm --platform linux/amd64 --network none --user 0 --entrypoint chown \
    -v "$TMP:/fixture" "$IMAGE" 1000:1000 /fixture/secrets/internal-ai-api-key /fixture/internal-ai-ca.pem
fi

# --- Rendered Compose selection ---------------------------------------------
log "checking the rendered Compose selection"
docker compose --profile '*' config --format json > "$TMP/config.json"
python3 - "$TMP/config.json" <<'PY' || fail "rendered Compose selection"
import json, sys
services = json.load(open(sys.argv[1]))["services"]
def targets(service, key):
    return {item["target"] for item in services[service].get(key, [])}
gateway_volumes = targets("openclaw", "volumes")
cli_volumes = targets("cli", "volumes")
required_gateway = {"/home/node/.openclaw", "/home/node/.pretorin", "/workspace/targets",
                    "/var/lib/compliance-claw/targets", "/etc/compliance-claw/targets.yaml",
                    "/etc/compliance-claw/internal-ai/ca.pem"}
required_cli = {"/home/node/.openclaw", "/home/node/.pretorin", "/workspace/targets",
                "/etc/compliance-claw/internal-ai/ca.pem"}
problems = []
if not required_gateway <= gateway_volumes:
    problems.append(f"openclaw mounts missing: {sorted(required_gateway - gateway_volumes)}")
if not required_cli <= cli_volumes:
    problems.append(f"cli mounts missing: {sorted(required_cli - cli_volumes)}")
gateway_secrets = {item["source"] for item in services["openclaw"].get("secrets", [])}
cli_secrets = {item["source"] for item in services["cli"].get("secrets", [])}
base = {"pretorin_api_key", "slack_app_token", "slack_bot_token", "openclaw_gateway_token",
        "openclaw_gateway_password", "openai_api_key", "anthropic_api_key", "github_readonly_pat"}
if not base | {"internal_ai_api_key"} <= gateway_secrets:
    problems.append(f"openclaw secrets missing: {sorted(base | {'internal_ai_api_key'} - gateway_secrets)}")
if "internal_ai_api_key" in cli_secrets:
    problems.append("cli received the internal AI credential")
ports = services["openclaw"].get("ports", [])
if not ports or any(port.get("host_ip") != "127.0.0.1" for port in ports):
    problems.append(f"gateway port is not loopback-only: {ports}")
if services["openclaw"].get("env_file"):
    problems.append("legacy env_file returned")
for problem in problems:
    print(f"  {problem}")
sys.exit(1 if problems else 0)
PY
# --env-file /dev/null: a developer .env must not supply the missing setting.
if (unset INTERNAL_AI_CA_FILE; docker compose --env-file /dev/null --profile '*' config >/dev/null 2>"$TMP/no-ca.err"); then
  fail "Compose accepted the overlay without INTERNAL_AI_CA_FILE"
elif ! grep -q 'Set INTERNAL_AI_CA_FILE' "$TMP/no-ca.err"; then
  fail "missing CA setting did not name INTERNAL_AI_CA_FILE"
fi

# --- Native configuration ----------------------------------------------------
# The example's placeholders, replaced with the fixture endpoint and model.
sed -e 's#https://ai.internal.example/v1#https://ai.internal.test:8443/v1#' \
  -e 's#"internal-model-id"#"fixture-model"#' \
  examples/internal-ai-ca/internal-ai.patch.json5 > "$TMP/internal-ai.patch.json5"
grep -q 'ai.internal.test:8443' "$TMP/internal-ai.patch.json5" || fail "patch endpoint placeholder changed"
grep -q '"fixture-model"' "$TMP/internal-ai.patch.json5" || fail "patch model placeholder changed"

# The documented cli path: configuration work while the gateway is stopped.
log "gateway stopped: the cli dry run must refuse, the credential is gateway-only"
if docker compose run --rm -T cli openclaw config patch --stdin --dry-run \
  < "$TMP/internal-ai.patch.json5" > "$TMP/cli-dry-run.out" 2>&1; then
  fail "cli dry run resolved the gateway-only credential"
elif ! grep -q 'internal_ai_api_key' "$TMP/cli-dry-run.out"; then
  fail "cli dry run failed for another reason:"
  sed 's/^/  /' "$TMP/cli-dry-run.out" | tail -15
fi

log "starting the isolated gateway and mock endpoint (slow under amd64 emulation)"
docker compose up -d --wait --wait-timeout 720 openclaw mock-ai

gateway() { docker compose exec -T openclaw /usr/local/bin/compliance-claw-entrypoint "$@"; }
log "applying the native patch through the running gateway"
gateway openclaw config patch --stdin --dry-run < "$TMP/internal-ai.patch.json5" > "$TMP/patch.out" 2>&1 \
  || fail "gateway dry run: $(tail -3 "$TMP/patch.out")"
gateway openclaw config patch --stdin < "$TMP/internal-ai.patch.json5" >> "$TMP/patch.out" 2>&1 \
  || fail "gateway patch: $(tail -3 "$TMP/patch.out")"
gateway openclaw models set internal-ai/fixture-model >> "$TMP/patch.out" 2>&1 \
  || fail "models set: $(tail -3 "$TMP/patch.out")"
[ "$FAILED" = 0 ] || exit 1
sleep 5

agent_turn() {
  docker compose exec -T openclaw sh -c '
    export OPENCLAW_GATEWAY_TOKEN="$(cat /run/secrets/openclaw_gateway_token)"
    exec openclaw agent --agent main --session-id "$1" --json \
      -m "Use one available tool, then answer."' sh "$1" > "$TMP/$1.json" 2> "$TMP/$1.err"
}

# --- Approved CA: complete tool round trip ----------------------------------
log "approved CA: agent turn with a tool round trip"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! agent_turn approved; then
  fail "approved-CA turn failed: $(tail -3 "$TMP/approved.err")"
elif ! grep -q '"finalAssistantVisibleText": "INTERNAL-AI-FIXTURE-TOOL-RESULT-RECEIVED"' "$TMP/approved.json"; then
  fail "approved-CA turn did not return the post-tool answer"
fi
docker compose logs --no-log-prefix --since "$since" mock-ai > "$TMP/approved.mock" 2>&1
grep -q '"outcome":"tool_call"' "$TMP/approved.mock" || fail "endpoint never sent a tool call"
grep -q '"outcome":"final_after_tool_result"' "$TMP/approved.mock" || fail "endpoint never received the tool result"
grep '"outcome":"final_after_tool_result"' "$TMP/approved.mock" | grep -q '"toolResultError":false' \
  || fail "the tool result reported an error, so the tool did not run correctly"

# --- Untrusted CA: the same configuration must refuse -----------------------
log "untrusted CA: the same configuration must reject the endpoint"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INTERNAL_AI_TEST_CERT_SET=untrusted docker compose up -d --force-recreate mock-ai >/dev/null 2>&1
for _ in $(seq 1 60); do
  docker compose logs --no-log-prefix --since "$since" mock-ai 2>/dev/null \
    | grep -q '"outcome":"listening","certSet":"untrusted"' && break
  sleep 2
done
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if agent_turn untrusted; then
  fail "agent turn succeeded against a certificate from an untrusted CA"
fi
docker compose logs --no-log-prefix --since "$since" mock-ai > "$TMP/untrusted.mock" 2>&1
docker compose logs --no-log-prefix --since "$since" openclaw > "$TMP/untrusted.gateway" 2>&1
grep -q '"path":' "$TMP/untrusted.mock" && fail "an HTTP request crossed an untrusted TLS connection"
grep -q 'UNABLE_TO_VERIFY_LEAF_SIGNATURE' "$TMP/untrusted.gateway" \
  || fail "gateway did not report the certificate verification failure"

for file in "$TMP"/*.json "$TMP"/*.err "$TMP"/*.out "$TMP"/*.mock "$TMP"/*.gateway; do
  if grep -q 'canary-internal-ai-api-key-test-only' "$file"; then
    fail "credential value appeared in $(basename "$file")"
  fi
done

[ "$FAILED" = 0 ] || exit 1
log "approved-CA request shape seen by the mock endpoint (no content):"
grep -E '"outcome":"(tool_call|final_after_tool_result)"' "$TMP/approved.mock" | sed 's/^/  /'
log "PASS — approved CA tool round trip; untrusted CA rejected; overlay selection intact"
