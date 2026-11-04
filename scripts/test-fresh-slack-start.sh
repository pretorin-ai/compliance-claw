#!/usr/bin/env bash
#
# test-fresh-slack-start.sh — a FRESH deployment with Slack credentials must
# start the native Slack provider, and channels.slack must survive the startup
# Doctor run. Both seed branches: legacy (SLACK_CHANNEL_ID) and efforts-owned.
#
#   scripts/test-fresh-slack-start.sh compliance-claw:local
#
# THE FAULT IT GUARDS. OpenClaw 2026.10.10 records the first config it reads as
# its last-known-good size. The legacy branch seeded the commented JSON5
# template (about 9 KB). Every config that OpenClaw wrote later was under 50% of
# that, so the startup Doctor treated the Slack-patched config as suspicious and
# restored openclaw.json.bak, which has no channels.slack. The gateway then
# logged "suppressed ambient channel auto-configuration" and Slack never
# started. Seeding plain JSON keeps the first baseline at the real config size.
#
# NOT LIVE SLACK PROOF. Canary tokens; Slack and Pretorin hosts resolve to
# 127.0.0.1, so the provider starts and then fails to connect, as intended.
# The npm registry stays reachable for the pinned official Slack install.
#
# ISOLATED. Its own Compose projects, volumes, secret directory, project
# directory and ports, and `down -v` on every exit path. No real credential.
set -uo pipefail

[ "$#" = 1 ] || { printf 'usage: %s LOCAL_CANDIDATE_IMAGE\n' "$0" >&2; exit 2; }
IMAGE="$1"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "fresh-slack-start: image not found: ${IMAGE}" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-fresh-slack-start.XXXXXX")"
CANARY_BOT="xoxb-0000-CANARY-FRESH-START-bot"
CANARY_APP="xapp-1-A0CANARYFS-1-CANARY-FRESH-START-app"
CANARY_CHANNEL="C0FRESHSTART1"
GATEWAY_TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
PROJECTS=()
SEED_VOLUMES=()

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

# fdc PROJECT ARGS... — Compose for one test project, with its full environment.
fdc() {
  local p="$1" d="$TMP/$1" files port chan
  shift
  { read -r files; read -r port; read -r chan; } < "$d/project.env" || return 1
  COMPOSE_FILE="$files" COMPOSE_PATH_SEPARATOR=: COMPOSE_PROJECT_NAME="$p" CC_TEST_PORT="$port" \
  COMPLIANCE_CLAW_SECRET_DIR="$d/secrets" SLACK_CHANNEL_ID="$chan" \
    docker compose --project-directory "$d" "$@"
}

cleanup() {
  local rc=$? p v
  set +e
  for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do fdc "$p" --profile '*' down -v >/dev/null 2>&1; done
  for v in ${SEED_VOLUMES[@]+"${SEED_VOLUMES[@]}"}; do docker volume rm -f "$v" >/dev/null 2>&1; done
  if [ -n "${KEEP_TMP:-}" ]; then
    printf 'fresh-slack-start: KEEP_TMP set; logs left in %s\n' "$TMP" >&2
  else
    rm -rf "$TMP"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# The seed check runs inside the image with its own Node and json5, against the
# in-image template (MODEL is substituted at build time).
cat > "$TMP/seed-check.cjs" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const JSON5 = require('/app/node_modules/json5');
const efforts = process.argv[2] === 'efforts';
const path = '/home/node/.openclaw/openclaw.json';
const raw = fs.readFileSync(path, 'utf8');
const report = (name, pass, detail) => console.log(`${pass ? 'SEED_OK' : 'SEED_BAD'} ${name}${detail ? ' :: ' + detail : ''}`);
let seeded;
try { seeded = JSON.parse(raw); report('the seeded config is strict JSON (no comments)', true); }
catch (e) { report('the seeded config is strict JSON (no comments)', false, e.message); }
report('the seeded config has mode 0600', (fs.statSync(path).mode & 0o777) === 0o600,
  (fs.statSync(path).mode & 0o777).toString(8));
const expected = JSON5.parse(fs.readFileSync('/opt/compliance-claw/openclaw-config.template.json', 'utf8'));
if (efforts) {
  const out = spawnSync('python3', ['/opt/compliance-claw/parse-efforts.py', 'agents', '/etc/compliance-claw/efforts.yaml'], { encoding: 'utf8' });
  const ids = out.stdout.trim().split('\n').filter(Boolean).map((line) => line.split('\t')[1]);
  expected.agents = { ...expected.agents, ownership: 'explicit', entries: Object.fromEntries(ids.map((id) => [id, {}])) };
}
if (seeded) {
  let detail = '';
  try { assert.deepStrictEqual(seeded, expected); } catch (e) { detail = e.message.split('\n').slice(0, 6).join(' | '); }
  report('the seeded values deep-equal the parsed template' + (efforts ? ' plus the agent roster' : ''), !detail, detail);
}
for (const ref of ['${OPENCLAW_GATEWAY_TOKEN}', '${PRETORIN_API_KEY}', '${OPENAI_REQUEST_ADAPTER}']) {
  report(`the secret ref ${ref} is literal text on disk`, raw.includes(ref));
}
JS

# Inspects the config after startup. Reads OpenClaw's own output, which is JSON.
cat > "$TMP/config-check.py" <<'PY'
import json, sys
mode, channel, canaries = sys.argv[1], sys.argv[2], sys.argv[3:]
raw = sys.stdin.read()
def report(name, ok, detail=""):
    print(("CFG_OK " if ok else "CFG_BAD ") + name + (" :: " + detail if detail and not ok else ""))
try:
    cfg = json.loads(raw)
except ValueError as e:
    report("openclaw.json is readable after startup", False, str(e)); sys.exit(0)
slack = (cfg.get("channels") or {}).get("slack")
report("channels.slack persists after startup and Doctor", isinstance(slack, dict),
       "channels keys: %s" % sorted((cfg.get("channels") or {}).keys()))
slack = slack or {}
for key, want in (("enabled", True), ("mode", "socket"), ("dmPolicy", "disabled"),
                  ("groupPolicy", "allowlist"), ("configWrites", False)):
    report("  channels.slack.%s is %s" % (key, json.dumps(want)), slack.get(key) == want, repr(slack.get(key)))
report("  channels.slack.slashCommand is compliance-claw",
       slack.get("slashCommand") == {"enabled": True, "name": "compliance-claw"}, repr(slack.get("slashCommand")))
chans = slack.get("channels")
if mode == "legacy":
    report("  the declared channel requires a mention",
           chans == {channel: {"requireMention": True, "users": ["*"]}}, repr(chans))
else:
    report("  the channel map is empty until clawctl apply", chans == {}, repr(chans))
plugins = cfg.get("plugins") or {}
report("  plugins.entries.slack is enabled", (plugins.get("entries") or {}).get("slack", {}).get("enabled") is True)
report("  plugins.allow keeps slack, pretorin-update and target-sync",
       {"slack", "pretorin-update", "target-sync"} <= set(plugins.get("allow") or []), repr(plugins.get("allow")))
report("the gateway token is still the literal ${OPENCLAW_GATEWAY_TOKEN}",
       ((cfg.get("gateway") or {}).get("auth") or {}).get("token") == "${OPENCLAW_GATEWAY_TOKEN}")
report("no canary token value is in openclaw.json", not any(c in raw for c in canaries))
PY

cat > "$TMP/status-check.py" <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    st = json.loads(raw[raw.index("{"):])
except ValueError as e:
    print("ST_BAD openclaw channels status --json is readable :: " + str(e)); sys.exit(0)
slack = (st.get("channels") or {}).get("slack")
ok = isinstance(slack, dict) and slack.get("lastStartAt") and slack.get("mode") == "socket"
print(("ST_OK " if ok else "ST_BAD ") + "native channel status lists a started Slack socket channel"
      + ("" if ok else " :: channels=%s" % sorted((st.get("channels") or {}).keys())))
PY

# Evidence for the "no config was restored" check. DIAGNOSTIC ONLY: it prints,
# never adds a PASS or FAIL, and does not change the exit code or cleanup.
#
# A HYPOTHESIS, NOT A PROVEN CAUSE: any OpenClaw config load that observes (for
# example the image healthcheck, every 15 s while setup still writes the config)
# can restore openclaw.json.bak and save openclaw.json.clobbered.*. So this reads
# the files and the state database READ-ONLY and runs no OpenClaw command, because
# an observing config load could itself restore a config.
#
# ALLOWLIST ONLY: hashes (first 16 hex), sizes, times, booleans, gateway mode and
# top-level key names; config-health fingerprints; selected config-audit fields;
# an allowlisted command word, never argv. No config values, meta or raw rows.
cat > "$TMP/config-diag.cjs" <<'JS'
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const dir = process.argv[2];
const say = (line) => console.log(line);
const fail = (what, e) => say(`diagnostic: ${what} failed: ${e && e.code ? e.code + ' ' : ''}${e && e.name ? e.name : 'Error'}`
  + (e && e.parse ? '' : `: ${String(e && e.message || e).split('\n')[0].replace(/[^A-Za-z0-9 ./:_-]/g, '?').slice(0, 120)}`));
const word = (v, max = 80) => (typeof v === 'string' && new RegExp(`^[A-Za-z0-9._-]{1,${max}}$`).test(v) ? v : v == null ? '-' : '?');
const time = (v) => (typeof v === 'string' && /^[0-9T:.Z+-]{10,40}$/.test(v) ? v : Number.isFinite(v) ? new Date(v).toISOString() : '-');
const num = (v) => (Number.isFinite(v) ? String(v) : '-');
const hash = (v) => (typeof v === 'string' && /^[0-9a-f]{16,128}$/.test(v) ? v.slice(0, 16) : '-');
const bool = (v) => (v === true ? 'yes' : v === false ? 'no' : '-');
const reasons = (v) => (Array.isArray(v) ? v : v == null ? [] : [v])
  .map((r) => (typeof r === 'string' && /^[a-z0-9:,>.-]{1,80}$/.test(r) ? r : '?')).join(',') || '-';
const record = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);
const parse = (text) => {
  try { return JSON.parse(text); } catch (first) {
    try { return require('/app/node_modules/json5').parse(text); } catch { first.parse = true; throw first; }
  }
};
// Only these command words are printed; any other argv text is never shown.
const SCRIPTS = new Set(['openclaw.mjs', 'openclaw', 'docker-healthcheck.js', 'docker-entrypoint.mjs', 'index.js']);
const WORDS = new Set(['gateway', 'doctor', 'config', 'plugins', 'channels', 'health', 'status', 'mcp', 'agents', 'models']);
const SUBS = new Set(['patch', 'set', 'unset', 'get', 'validate', 'install', 'inspect', 'update', 'enable', 'disable', 'list', 'status', 'probe', 'run']);
const command = (argv) => {
  if (!Array.isArray(argv)) return '-';
  const script = typeof argv[1] === 'string' && SCRIPTS.has(path.basename(argv[1])) ? path.basename(argv[1]) : 'other';
  const rest = argv.slice(2).filter((a) => typeof a === 'string' && !a.startsWith('-'));
  const at = rest.findIndex((a) => WORDS.has(a));
  const sub = at >= 0 && SUBS.has(rest[at + 1]) ? rest[at + 1] : '';
  return [script, at >= 0 ? rest[at] : '', sub].filter(Boolean).join(' ');
};
const fingerprint = (label, text) => {
  if (text == null) return `${label}=-`;
  let f;
  try { f = record(parse(text)); } catch (e) { fail(`${label} parse`, e); return `${label}=?`; }
  if (!f) return `${label}=?`;
  return `${label}=${hash(f.hash)}/${num(f.bytes)}B/meta:${bool(f.hasMeta)}/mode:${word(f.gatewayMode, 20)}/observed:${time(f.observedAt)}`;
};

let names = null;
try {
  names = fs.readdirSync(dir).filter((n) => /^openclaw\.json(\.|$)/.test(n)).sort();
} catch (e) { fail('config directory read', e); }
for (const name of names || []) {
  try {
    const file = path.join(dir, name);
    const st = fs.statSync(file);
    if (!st.isFile()) { say(`file ${word(name)} not-a-file`); continue; }
    const raw = fs.readFileSync(file);
    const sha = crypto.createHash('sha256').update(raw).digest('hex').slice(0, 16);
    let shape;
    try {
      const c = record(parse(raw.toString('utf8')));
      const slack = record(record(c && c.channels) && c.channels.slack);
      shape = c ? `meta=${bool(record(c.meta) !== null)} mode=${word(record(c.gateway) && c.gateway.mode, 20)} slack=${bool(slack !== null)}`
        + ` keys=${Object.keys(c).sort().map((k) => word(k, 40)).join(',')}` : 'root=not-an-object';
    } catch (e) { fail(`${word(name)} parse`, e); shape = 'parse=failed'; }
    say(`file ${word(name)} sha256=${sha} bytes=${st.size} mtime=${st.mtime.toISOString()} ${shape}`);
  } catch (e) { fail(`${word(name)} read`, e); }
}
if (names) say(`volume-file=${names.some((n) => n.startsWith('openclaw.json.clobbered.')) ? 'yes' : 'no'}`);

const dbPath = path.join(dir, 'state', 'openclaw.sqlite');
let db = null;
try {
  if (!fs.existsSync(dbPath)) throw Object.assign(new Error('no state/openclaw.sqlite'), { code: 'ENOENT' });
  const { DatabaseSync } = require('node:sqlite');
  db = new DatabaseSync(dbPath, { readOnly: true });
  try { db.exec('PRAGMA busy_timeout = 3000'); } catch {}
} catch (e) { fail('sqlite read', e); db = null; }
if (db) {
  try {
    const rows = db.prepare('SELECT config_path, last_known_good_json, last_promoted_good_json, '
      + 'last_observed_suspicious_signature, updated_at_ms FROM config_health_entries ORDER BY config_path').all();
    if (rows.length === 0) say('health: no config_health_entries row');
    for (const row of rows) {
      const sig = typeof row.last_observed_suspicious_signature === 'string' ? row.last_observed_suspicious_signature : null;
      const cut = sig ? sig.indexOf(':') : -1;
      say(`health ${word(path.basename(String(row.config_path)))} updated=${time(Number(row.updated_at_ms))} `
        + `${fingerprint('lastKnownGood', row.last_known_good_json)} ${fingerprint('lastPromotedGood', row.last_promoted_good_json)} `
        + `suspiciousSignature=${sig ? `${hash(cut > 0 ? sig.slice(0, cut) : sig)}:${reasons(cut > 0 ? sig.slice(cut + 1) : '')}` : '-'}`);
    }
  } catch (e) { fail('sqlite config_health_entries read', e); }
  try {
    const rows = db.prepare("SELECT payload_json, created_at FROM diagnostic_events WHERE scope = 'config-audit' "
      + 'ORDER BY created_at, sequence').all();
    say(`audit rows=${rows.length}${rows.length > 60 ? ' (last 60 shown)' : ''}`);
    for (const row of rows.slice(-60)) {
      let a;
      try { a = record(parse(String(row.payload_json))); } catch (e) { fail('audit row parse', e); continue; }
      if (a && !('event' in a) && record(a.value)) a = a.value;
      if (!a) { say('audit ?'); continue; }
      const out = [`audit ${time(a.ts)} ${word(a.event, 40)}`, `result=${word(a.result, 40)}`, `pid=${num(a.pid)}`,
        `ppid=${num(a.ppid)}`, `cmd="${command(a.argv)}"`];
      const put = (key, value) => { if (value !== '-') out.push(`${key}=${value}`); };
      put('valid', bool(a.valid));
      put('hash', hash(a.hash)); put('bytes', num(a.bytes));
      put('hasMeta', bool(a.hasMeta)); put('gatewayMode', word(a.gatewayMode, 20));
      put('previousHash', hash(a.previousHash)); put('previousBytes', num(a.previousBytes));
      put('nextHash', hash(a.nextHash)); put('nextBytes', num(a.nextBytes));
      put('hasMetaBefore', bool(a.hasMetaBefore)); put('hasMetaAfter', bool(a.hasMetaAfter));
      put('gatewayModeBefore', word(a.gatewayModeBefore, 20)); put('gatewayModeAfter', word(a.gatewayModeAfter, 20));
      put('suspicious', reasons(a.suspicious));
      put('lastKnownGoodHash', hash(a.lastKnownGoodHash)); put('lastKnownGoodBytes', num(a.lastKnownGoodBytes));
      put('backupHash', hash(a.backupHash)); put('backupBytes', num(a.backupBytes));
      put('clobberedPath', typeof a.clobberedPath === 'string' ? word(path.basename(a.clobberedPath)) : '-');
      put('restoredFromBackup', bool(a.restoredFromBackup)); put('restoreErrorCode', word(a.restoreErrorCode, 40));
      say(out.join(' '));
    }
  } catch (e) { fail('sqlite config-audit read', e); }
  try { db.close(); } catch {}
}
JS

# check_lines PREFIX FILE — one PASS/FAIL row per line the checker printed.
check_lines() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "$1"_OK\ *)  ok "${line#*_OK }" ;;
      "$1"_BAD\ *) bad "${line#*_BAD }" ;;
    esac
  done < "$2"
  grep -qE "^$1_(OK|BAD) " "$2" || bad "the $1 checker ran" "$(tail -3 "$2")"
}

# config_diagnostics PROJECT GATEWAY_LOG — prints the evidence above, with the
# test tokens redacted. Lines without a known prefix (for example an exec or
# Node error) are withheld and counted. Always returns 0; a read error is
# printed as a "diagnostic: ... failed" line.
config_diagnostics() {
  local p="$1" log="$2" in_log=no in_volume=unknown raw out rc other
  grep -q 'openclaw.json.clobbered' "$log" 2>/dev/null && in_log=yes
  raw="$(fdc "$p" exec -T openclaw node --no-warnings - /home/node/.openclaw < "$TMP/config-diag.cjs" 2>&1)"
  rc=$?
  out="$(printf '%s\n' "$raw" | grep -E '^(file|health|audit) |^volume-file=|^diagnostic: ')"
  other="$(printf '%s\n' "$raw" | grep -cvE '^(file|health|audit) |^volume-file=|^diagnostic: |^$')"
  [ "$other" = 0 ] || out="${out}"$'\n'"diagnostic: ${other} other output line(s) withheld"
  [ "$rc" = 0 ] || out="${out}"$'\n'"diagnostic: container read failed: exit ${rc}"
  case "$out" in *volume-file=yes*) in_volume=yes ;; *volume-file=no*) in_volume=no ;; esac
  out="${out}"$'\n'"OR check halves: gateway-log=${in_log} volume-file=${in_volume} (volume read after the check)"
  printf '%s\n' "$out" | grep -v '^$' \
    | sed -e "s/${CANARY_BOT}/<redacted>/g" -e "s/${CANARY_APP}/<redacted>/g" -e "s/${GATEWAY_TOKEN}/<redacted>/g" \
          -e 's/^/        diag: /'
  return 0
}

# --- seed check: the file the entrypoint writes, before OpenClaw touches it ---
seed_check() {  # $1 legacy|efforts
  local branch="$1" vol="cc-fss-seed-$1-$$" args=() log="$TMP/seed-$1"
  SEED_VOLUMES+=("$vol")
  docker volume create "$vol" >/dev/null
  args=(--rm --platform linux/amd64 --network none
        --mount "type=volume,src=$vol,dst=/home/node/.openclaw"
        --mount "type=bind,src=$TMP/seed-check.cjs,dst=/check/seed-check.cjs,readonly")
  [ "$branch" = efforts ] && args+=(--mount "type=bind,src=$TMP/efforts.yaml,dst=/etc/compliance-claw/efforts.yaml,readonly")
  docker run "${args[@]}" "$IMAGE" node /check/seed-check.cjs "$branch" >"$log.1" 2>&1
  check_lines SEED "$log.1"
  docker run "${args[@]}" "$IMAGE" sh -c 'sha256sum /home/node/.openclaw/openclaw.json' >"$log.2" 2>&1
  docker run "${args[@]}" "$IMAGE" sh -c 'sha256sum /home/node/.openclaw/openclaw.json' >"$log.3" 2>&1
  if grep -q 'exists, keeping it' "$log.3" && [ "$(grep openclaw.json "$log.2")" = "$(grep openclaw.json "$log.3")" ]; then
    ok "a second start keeps the seeded config unchanged"
  else
    bad "a second start keeps the seeded config unchanged" "$(tail -2 "$log.3")"
  fi
}

# --- full fresh start --------------------------------------------------------
fresh_start() {  # $1 legacy|efforts, $2 port
  local branch="$1" port="$2" p="cc-fss-$1-$$" d files log
  d="$TMP/$p"; log="$d/gateway.log"
  PROJECTS+=("$p")
  mkdir -p "$d/secrets/pretorin" "$d/workspace/targets"
  chmod 700 "$d/secrets"
  printf '%s' "$CANARY_BOT" > "$d/secrets/slack-bot-token"
  printf '%s' "$CANARY_APP" > "$d/secrets/slack-app-token"
  printf '%s' "$GATEWAY_TOKEN" > "$d/secrets/openclaw-gateway-token"
  for empty in openclaw-gateway-password pretorin-api-key openai-api-key anthropic-api-key github-readonly-pat; do
    : > "$d/secrets/$empty"
  done
  chmod 604 "$d/secrets"/*
  cp "$REPO_ROOT/targets.yaml" "$d/targets.yaml"
  cp "$TMP/efforts.yaml" "$d/efforts.yaml"
  # The image under test, and Slack and Pretorin hosts on loopback.
  {
    printf 'services:\n'
    for svc in openclaw cli; do
      printf '  %s:\n    image: "%s"\n    pull_policy: never\n    extra_hosts:\n' "$svc" "$IMAGE"
      for h in slack.com api.slack.com wss-primary.slack.com wss-backup.slack.com files.slack.com \
               edgeapi.slack.com api.pretorin.com platform.pretorin.com app.pretorin.com; do
        printf '      - "%s:127.0.0.1"\n' "$h"
      done
    done
  } > "$d/fss-image.yaml"
  files="$REPO_ROOT/compose.yaml:$REPO_ROOT/compose.secrets.yaml"
  [ "$branch" = efforts ] && files="$files:$REPO_ROOT/compose.efforts.yaml"
  files="$files:$REPO_ROOT/compose.test.yaml:$d/fss-image.yaml"
  local chan=""
  [ "$branch" = legacy ] && chan="$CANARY_CHANNEL"
  printf '%s\n' "$files" "$port" "$chan" > "$d/project.env"
  if fdc "$p" up -d --wait --wait-timeout 720 openclaw >"$d/up.log" 2>&1; then
    ok "the fresh gateway becomes healthy"
  else
    bad "the fresh gateway becomes healthy" "$(tail -3 "$d/up.log")"
  fi
  # The provider starts after readiness; allow it time to log either outcome.
  local i
  for i in $(seq 1 60); do
    fdc "$p" logs --no-color openclaw >"$log" 2>&1
    grep -qE '\[slack\] \[default\] starting provider|suppressed ambient channel' "$log" && break
    sleep 3
  done
  sleep 5
  fdc "$p" logs --no-color openclaw >"$log" 2>&1
  fdc "$p" exec -T openclaw cat /home/node/.openclaw/openclaw.json \
    > "$d/openclaw.json" 2>"$d/openclaw.json.err"
  python3 -I "$TMP/config-check.py" "$branch" "$CANARY_CHANNEL" "$CANARY_BOT" "$CANARY_APP" \
    < "$d/openclaw.json" > "$d/config-check.txt" 2>&1
  check_lines CFG "$d/config-check.txt"
  # Native activation, asked of the running gateway in its own PID namespace.
  fdc "$p" exec -T openclaw /usr/local/bin/compliance-claw-entrypoint \
    openclaw channels status --json > "$d/channels-status.json" 2>"$d/channels-status.err"
  python3 -I "$TMP/status-check.py" < "$d/channels-status.json" > "$d/status-check.txt" 2>&1
  check_lines ST "$d/status-check.txt"
  if grep -q '\[slack\] \[default\] starting provider' "$log"; then
    ok "the gateway log shows the native Slack provider starting"
  else
    bad "the gateway log shows the native Slack provider starting"
  fi
  if grep -q 'suppressed ambient channel' "$log"; then
    bad "the gateway does not suppress the Slack channel" "$(grep -m1 'suppressed ambient channel' "$log" | cut -c1-160)"
  else
    ok "the gateway does not suppress the Slack channel"
  fi
  if grep -q 'openclaw.json.clobbered' "$log" || \
     fdc "$p" exec -T openclaw sh -c 'ls /home/node/.openclaw/openclaw.json.clobbered.* >/dev/null 2>&1'; then
    bad "no config was restored over the Slack patch" "an openclaw.json.clobbered.* file exists"
  else
    ok "no config was restored over the Slack patch"
  fi
  config_diagnostics "$p" "$log"
  fdc "$p" down -v >/dev/null 2>&1
}

cat > "$TMP/efforts.yaml" <<YAML
efforts:
  - name: fresh-slack-start
    system_id: 00000000-0000-0000-0000-000000000001
    framework_id: soc2
    credential_ref: default
    slack_channel_id: ${CANARY_CHANNEL}
    targets:
      - name: simple-crm
        url: https://github.com/pretorin-ai/simple-crm.git
        private: false
YAML

BASE_PORT="$(( 19500 + ($$ % 200) * 2 ))"
for branch in legacy efforts; do
  printf '\n\033[1m%s seed branch\033[0m (image %s)\n' "$branch" "$IMAGE"
  seed_check "$branch"
  fresh_start "$branch" "$BASE_PORT"
  BASE_PORT=$((BASE_PORT + 1))
done

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'fresh-slack-start: PASS — both seed branches start Slack natively (%d checks)\n' "$PASS"
  exit 0
fi
printf 'fresh-slack-start: FAIL — %d of %d checks\n' "$FAIL" "$((PASS + FAIL))"
exit 1
