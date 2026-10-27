#!/usr/bin/env bash
# Native authentication and local maintenance proof. No proxy, real credentials,
# published ports, model calls, Slack, or Pretorin service calls.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-compliance-claw:local}"
PROJECT="cc-proxy-auth-$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-proxy-auth.XXXXXX")"
export COMPOSE_FILE="$TMP/compose.yaml" COMPOSE_PROJECT_NAME="$PROJECT"
cleanup() {
  if [ "$?" != 0 ]; then
    echo 'proxy-auth-test: failed; inspect native readiness and authentication' >&2
    docker compose logs --tail 12 2>&1 | sed 's/canary-local-maintenance-only/<redacted>/g' >&2 || true
  fi
  docker compose down -v >"$TMP/cleanup.log" 2>&1 || true
  docker volume rm "$PROJECT-state" "$PROJECT-pretorin" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
docker image inspect "$IMAGE" >/dev/null
printf '%s' 'canary-local-maintenance-only' > "$TMP/password"
: > "$TMP/token"
chmod 604 "$TMP/password" "$TMP/token"
cat > "$TMP/config.json" <<'JSON'
{
  "gateway": {
    "mode": "local", "bind": "loopback", "port": 18789,
    "trustedProxies": ["192.0.2.1"],
    "auth": {"mode": "trusted-proxy", "password": "${OPENCLAW_GATEWAY_PASSWORD}",
      "trustedProxy": {"userHeader": "x-forwarded-user", "allowUsers": ["admin@fixture.invalid"]}}
  },
  "plugins": {"allow": []}, "discovery": {"mdns": {"mode": "off"}}
}
JSON
cat > "$TMP/compose.yaml" <<YAML
services:
  openclaw:
    image: "$IMAGE"
    platform: linux/amd64
    network_mode: none
    command: ["openclaw", "gateway"]
    environment:
      OPENCLAW_GATEWAY_PASSWORD_FILE: /run/secrets/openclaw_gateway_password
      OPENCLAW_GATEWAY_TOKEN_FILE: /run/secrets/openclaw_gateway_token
    volumes:
      - "$TMP/password:/run/secrets/openclaw_gateway_password:ro"
      - "$TMP/token:/run/secrets/openclaw_gateway_token:ro"
      - state:/home/node/.openclaw
      - pretorin:/home/node/.pretorin
volumes:
  state:
    name: "$PROJECT-state"
  pretorin:
    name: "$PROJECT-pretorin"
YAML
docker volume create "$PROJECT-state" >/dev/null
seed_config() {
docker run --rm --platform linux/amd64 --network none --user 0 --entrypoint sh \
  --mount "type=volume,src=$PROJECT-state,dst=/state" \
  --mount "type=bind,src=$1,dst=/fixture.json,readonly" "$IMAGE" \
  -c 'cp /fixture.json /state/openclaw.json; chown -R 1000:1000 /state'
}

# Load the actual clawctl request helper, without executing its command dispatch.
source <(sed -n '/^OC_EXEC_PRELUDE=/,/^oc_token_failure()/p' "$REPO_ROOT/scripts/clawctl" | sed '$d')
ready() {
  local attempt
  for attempt in $(seq 1 120); do
    if [ -z "$(docker compose ps --status running -q openclaw)" ]; then return 1; fi
    if docker compose exec -T openclaw node -e 'fetch("http://127.0.0.1:18789/startupz", {signal: AbortSignal.timeout(2000)}).then(r => {process.exitCode = r.ok ? 0 : 1}).catch(() => {process.exitCode = 1})' >"$TMP/health.log" 2>&1; then return 0; fi
    sleep 1
  done
  echo 'proxy-auth-test: native gateway did not accept local maintenance' >&2
  return 1
}
python3 - "$TMP/config.json" > "$TMP/token-config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg['gateway']['auth'] = {'mode': 'token', 'token': '${OPENCLAW_GATEWAY_TOKEN}'}
print(json.dumps(cfg))
PY
# Fresh token mode and retained token configuration still use native auth.
printf '%s' 'canary-gateway-token-only' > "$TMP/token"
seed_config "$TMP/token-config.json"
docker compose up -d >"$TMP/start.log" 2>&1
ready
oc_exec openclaw gateway call health --json > "$TMP/token-health.json"
docker compose restart openclaw >"$TMP/restart.log" 2>&1
ready
oc_exec openclaw gateway call health --json > "$TMP/retained-token-health.json"
echo 'proxy-auth-test: fresh and retained token startup passed'
python3 - "$TMP/config.json" > "$TMP/auth.json" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1]))['gateway']['auth']))
PY
# Change retained configuration through native storage, including token removal.
oc_exec "openclaw config set gateway.auth '$(cat "$TMP/auth.json")' --strict-json" > "$TMP/auth-applied.log"
docker compose stop --timeout 30 openclaw >"$TMP/stop.log" 2>&1
: > "$TMP/token"
docker compose up -d >"$TMP/start.log" 2>&1
ready
oc_exec openclaw gateway call config.get --json > "$TMP/before.json"
python3 - "$TMP/before.json" > "$TMP/patch.json" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
assert reply['config']['gateway']['auth']['mode'] == 'trusted-proxy'
assert 'token' not in reply['config']['gateway']['auth']
print(json.dumps({'baseHash': reply['hash'], 'raw': json.dumps({'messages': {'ackReaction': 'check'}})}))
PY
# Only non-secret fixture configuration crosses this helper argument boundary.
oc_exec "openclaw gateway call config.patch --json --params '$(cat "$TMP/patch.json")'" > "$TMP/applied.json"
ready
oc_exec openclaw gateway call config.get --json > "$TMP/after.json"
python3 - "$TMP/after.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))['config']
assert cfg['messages']['ackReaction'] == 'check'
assert cfg['gateway']['auth']['mode'] == 'trusted-proxy'
assert 'token' not in cfg['gateway']['auth']
assert cfg['gateway']['trustedProxies'] == ['192.0.2.1']
PY
echo 'proxy-auth-test: native proxy migration and local request/apply/verify passed'

# A direct exec has neither PID 1's password export nor proxy identity headers.
if docker compose exec -T openclaw openclaw gateway call health --json >"$TMP/unauth.log" 2>&1; then
  echo 'proxy-auth-test: unauthenticated maintenance was accepted' >&2; exit 1
fi
for failure in missing conflict; do
  args=(-e OPENCLAW_GATEWAY_PASSWORD_FILE=/missing-password)
  if [ "$failure" = conflict ]; then args=(-e OPENCLAW_GATEWAY_PASSWORD=direct-canary); fi
  if docker compose exec -T "${args[@]}" openclaw sh -c "$OC_EXEC_PRELUDE openclaw gateway call health --json" >"$TMP/$failure.log" 2>&1; then
    echo "proxy-auth-test: helper accepted $failure credential sources" >&2; exit 1
  fi
  case "$failure" in
    conflict) grep -q 'both set' "$TMP/$failure.log" ;;
    missing) grep -q 'readable regular file' "$TMP/$failure.log" ;;
  esac
done
# Native token mode can generate a runtime token. Password mode instead requires
# a password; validate that native rejection without an integration mode parser.
if docker run --rm --platform linux/amd64 --network none \
  -e OPENCLAW_CONFIG_PATH=/tmp/missing-password.json --entrypoint sh "$IMAGE" -c \
  'printf "%s" '\''{"gateway":{"mode":"local","bind":"loopback","auth":{"mode":"password"}},"plugins":{"allow":[]}}'\'' > /tmp/missing-password.json; exec /usr/local/bin/compliance-claw-entrypoint timeout 30 openclaw gateway' >"$TMP/missing-password.log" 2>&1; then
  echo 'proxy-auth-test: missing required native password was accepted' >&2; exit 1
else
  [ "$?" != 124 ] || { echo 'proxy-auth-test: missing-password check timed out' >&2; exit 1; }
fi
grep -q 'no password is configured' "$TMP/missing-password.log"
docker inspect --format '{{json .Config.Env}}' "$(docker compose ps -q openclaw)" > "$TMP/container-env.json"
docker compose logs > "$TMP/gateway.log"
if grep -q 'canary-local-maintenance-only' "$TMP/container-env.json" "$TMP/gateway.log"; then
  echo 'proxy-auth-test: maintenance password appeared in Docker configuration or logs' >&2; exit 1
fi
echo 'proxy-auth-test: PASS — native proxy startup, local request/apply/verify, and denial checks'
