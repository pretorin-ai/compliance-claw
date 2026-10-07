#!/usr/bin/env bash
# Test the upstream gateway lease with a synthetic 12-second shutdown drain.
# Usage: scripts/test-gateway-stop.sh LOCAL_CANDIDATE_IMAGE
# Uses new volumes, no credentials, and no network. It does not test busy agents.
set -euo pipefail
[ "$#" = 1 ] || { printf 'usage: %s LOCAL_CANDIDATE_IMAGE\n' "$0" >&2; exit 2; }
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-gateway-stop.XXXXXX")"
TEST_PROJECT="cc-gateway-stop-$$"
export CC_STOP_TEST_IMAGE="$1"
cleanup() {
  docker compose -p "$TEST_PROJECT" -f "$TEST_DIR/compose.yaml" down -v >/dev/null 2>&1 || true
  # Remove only the directory made by this test.
  python3 - "$TEST_DIR" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
docker image inspect "$CC_STOP_TEST_IMAGE" >/dev/null
FIXED_GRACE="$(docker compose -f "$REPO_ROOT/compose.yaml" config --format json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["openclaw"].get("stop_grace_period") or "10s")')"
cat > "$TEST_DIR/fixture.mjs" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
async function load(prefix, name) {
  for (const file of fs.readdirSync('/app/dist').filter(n => n.startsWith(prefix) && n.endsWith('.mjs'))) {
    const source = fs.readFileSync(path.join('/app/dist', file), 'utf8');
    const alias = source.match(new RegExp(name + ' as ([a-zA-Z_$][\\w$]*)'))?.[1];
    if (alias) return (await import(pathToFileURL(path.join('/app/dist', file))))[alias];
  }
  throw new Error('Export not found: ' + name);
}
const init = await load('openclaw-state-db-', 'initializeNativeOpenClawStateDatabase');
const acquire = await load('gateway-owner-lease-', 'acquireGatewayOwnerLease');
init({ env: process.env });
const lease = acquire({ env: process.env, port:18789, mode:'foreground', supervisor:null });
await lease.ready;
console.log('LEASE_READY');
setInterval(() => {}, 1000);
let stopping = false;
process.on('SIGTERM', async () => {
  if (stopping) return;
  stopping = true;
  console.log('DRAIN_START');
  await new Promise(resolve => setTimeout(resolve, 12000));
  await lease.release();
  console.log('LEASE_RELEASED');
  process.exit(0);
});
JS
cat > "$TEST_DIR/inspect.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/state/state/openclaw.sqlite', { readOnly:true });
const row = db.prepare('SELECT count(*) AS count FROM state_leases WHERE scope=? AND expires_at>?')
  .get('gateway-owner', Date.now());
console.log(row.count);
db.close();
JS
cat > "$TEST_DIR/compose.yaml" <<'YAML'
services:
  fixture:
    image: ${CC_STOP_TEST_IMAGE}
    pull_policy: never
    platform: linux/amd64
    network_mode: none
    user: "0:0"
    stop_grace_period: ${CC_STOP_TEST_GRACE}
    environment:
      OPENCLAW_STATE_DIR: /state
    entrypoint: [node, /fixture.mjs]
    volumes:
      - state:/state
      - ./fixture.mjs:/fixture.mjs:ro
  inspect:
    image: ${CC_STOP_TEST_IMAGE}
    pull_policy: never
    platform: linux/amd64
    network_mode: none
    user: "0:0"
    profiles: [inspect]
    entrypoint: [node, /inspect.mjs]
    volumes:
      - state:/state:ro
      - ./inspect.mjs:/inspect.mjs:ro
volumes:
  state:
YAML
dc() { docker compose -p "$TEST_PROJECT" -f "$TEST_DIR/compose.yaml" "$@"; }
for test_case in short configured; do
  if [ "$test_case" = short ]; then
    export CC_STOP_TEST_GRACE=10s
    expected_exit=137
    expected_rows=1
  else
    export CC_STOP_TEST_GRACE="$FIXED_GRACE"
    expected_exit=0
    expected_rows=0
  fi
  dc up -d fixture >/dev/null
  ready=0
  for ((attempt=0; attempt<60; attempt++)); do
    if dc logs --no-color fixture 2>/dev/null | grep -q LEASE_READY; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" = 1 ] || { dc logs --no-color fixture; exit 1; }
  dc stop fixture >/dev/null
  container="$(dc ps -aq fixture)"
  exit_code="$(docker inspect "$container" --format '{{.State.ExitCode}}')"
  rows="$(dc run --rm -T inspect)"
  printf '%s: grace=%s exit=%s active_lease_rows=%s\n' "$test_case" "$CC_STOP_TEST_GRACE" "$exit_code" "$rows"
  [ "$exit_code" = "$expected_exit" ] && [ "$rows" = "$expected_rows" ] || exit 1
  dc down -v >/dev/null
done
printf 'PASS: the configured stop limit permits upstream lease release after the synthetic drain.\n'
