#!/usr/bin/env bash
#
# test-retained-slack-add.sh — Slack added to a RETAINED legacy deployment must
# survive the next start and its Doctor run.
#
#   scripts/test-retained-slack-add.sh compliance-claw:local
#
# THE FAULT IT GUARDS. Release 0.5.2 seeded the legacy (no efforts.yaml) config
# from the commented template, so OpenClaw stored a 9 KB last-known-good size
# that no later config reaches. On OpenClaw 2026.10.10, a Slack patch written
# with the gateway stopped is then restored away by the managed-Slack Doctor at
# the next start. The supported route is the running gateway, which commits the
# change as the config owner. This test follows the docs/upgrade.md commands
# exactly, and requires the image's own warning to name that route.
#
# RETAINED STATE comes from the pinned release image below (local copy, or a
# pull by digest with no credentials). Canary tokens; Slack and Pretorin hosts
# resolve to 127.0.0.1; npm registry access for the pinned Slack install.
# Its own Compose project, project directory and volumes; `down -v` on exit.
set -uo pipefail

[ "$#" = 1 ] || { printf 'usage: %s LOCAL_CANDIDATE_IMAGE\n' "$0" >&2; exit 2; }
IMAGE="$1"
RELEASE="${CC_RETAINED_RELEASE_IMAGE:-ghcr.io/pretorin-ai/compliance-claw:0.5.2@sha256:b2380d21dfe2265d0de209819875ad1ad25bc7a64f85c6f226b1e09f05b01b09}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "retained-slack-add: image not found: ${IMAGE}" >&2; exit 1; }
docker image inspect "$RELEASE" >/dev/null 2>&1 || docker pull --platform linux/amd64 "$RELEASE" >/dev/null \
  || { echo "retained-slack-add: release image not available: ${RELEASE}" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-retained-slack.XXXXXX")"
D="$TMP/project"
P="cc-rsa-$$"
CANARY_BOT="xoxb-0000-CANARY-RETAINED-ADD-bot"
CANARY_APP="xapp-1-A0CANARYRA-1-CANARY-RETAINED-ADD-app"
CHANNEL="C0RETAINADD1"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

mkdir -p "$D/secrets" "$D/workspace/targets"
cp "$REPO_ROOT/targets.yaml" "$D/targets.yaml"
chmod 700 "$D/secrets"
printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$D/secrets/openclaw-gateway-token"
for e in openclaw-gateway-password pretorin-api-key openai-api-key anthropic-api-key github-readonly-pat \
         slack-bot-token slack-app-token; do
  : > "$D/secrets/$e"
done
chmod 604 "$D/secrets"/*
{
  printf 'services:\n'
  for svc in openclaw cli; do
    printf '  %s:\n    image: "${CC_RSA_IMAGE}"\n    pull_policy: never\n    extra_hosts:\n' "$svc"
    for h in slack.com api.slack.com wss-primary.slack.com wss-backup.slack.com files.slack.com \
             edgeapi.slack.com api.pretorin.com platform.pretorin.com app.pretorin.com; do
      printf '      - "%s:127.0.0.1"\n' "$h"
    done
  done
} > "$D/rsa-image.yaml"

export COMPOSE_FILE="$REPO_ROOT/compose.yaml:$REPO_ROOT/compose.secrets.yaml:$REPO_ROOT/compose.test.yaml:$D/rsa-image.yaml"
export COMPOSE_PATH_SEPARATOR=: COMPOSE_PROJECT_NAME="$P" CC_TEST_PORT="$(( 19700 + ($$ % 200) ))"
export COMPLIANCE_CLAW_SECRET_DIR="$D/secrets" SLACK_CHANNEL_ID=""
dc() { docker compose --project-directory "$D" "$@"; }

cleanup() {
  local rc=$?
  set +e
  CC_RSA_IMAGE="$IMAGE" dc --profile '*' down -v >/dev/null 2>&1
  if [ -n "${KEEP_TMP:-}" ]; then
    printf 'retained-slack-add: KEEP_TMP set; logs left in %s\n' "$TMP" >&2
  else
    rm -rf "$TMP"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

up() {  # $1 label
  if dc up -d --wait --wait-timeout 720 openclaw >"$TMP/up-$1.log" 2>&1; then ok "$2"; else bad "$2" "$(tail -3 "$TMP/up-$1.log")"; fi
}

printf '\n\033[1mretained legacy state from %s, then %s\033[0m\n' "$RELEASE" "$IMAGE"

# --- 1. the retained deployment: release seed, a known setting, no Slack -------
export CC_RSA_IMAGE="$RELEASE"
up release-1 "the release gateway seeds a legacy config and becomes healthy"
dc stop openclaw >/dev/null 2>&1
printf '{"messages":{"ackReaction":"retained-canary"}}' \
  | dc run --rm -T cli openclaw config patch --stdin >"$TMP/custom.log" 2>&1 \
  || bad "the release CLI applies a known setting" "$(tail -3 "$TMP/custom.log")"
up release-2 "the release gateway restarts with the known setting"
dc stop openclaw >/dev/null 2>&1

# --- 2. the upgrade, still without Slack ---------------------------------------
export CC_RSA_IMAGE="$IMAGE"
up candidate-1 "the candidate starts on the retained volumes"

# --- 3. the documented Slack addition (docs/upgrade.md), word for word ---------
printf '%s' "$CANARY_BOT" > "$D/secrets/slack-bot-token"
printf '%s' "$CANARY_APP" > "$D/secrets/slack-app-token"
export SLACK_CHANNEL_ID="$CHANNEL"
up candidate-2 "the candidate restarts with the Slack tokens"
dc logs --no-color openclaw >"$TMP/log-tokens.txt" 2>&1
if grep -q 'Slack credentials are supplied but NOT' "$TMP/log-tokens.txt" \
   && grep -q 'With the gateway RUNNING, run both steps in it' "$TMP/log-tokens.txt"; then
  ok "the Slack warning names the running-gateway route"
else
  bad "the Slack warning names the running-gateway route" "the warning does not say where to run the steps"
fi
dc exec -T openclaw /usr/local/bin/compliance-claw-entrypoint \
  node /opt/compliance-claw/managed-slack.mjs prepare --required >"$TMP/prepare.log" 2>&1 \
  || bad "the pinned Slack package installs through the running gateway" "$(tail -3 "$TMP/prepare.log")"
dc exec -T openclaw /usr/local/bin/compliance-claw-entrypoint sh -c '
  sed "s/@SLACK_CHANNEL_ID@/$SLACK_CHANNEL_ID/" \
    /opt/compliance-claw/slack-channel.patch.json5 > /tmp/slack.patch.json5
  openclaw config patch --file /tmp/slack.patch.json5 --dry-run &&
    openclaw config patch --file /tmp/slack.patch.json5' >"$TMP/patch.log" 2>&1 \
  && ok "the Slack patch applies through the running gateway" \
  || bad "the Slack patch applies through the running gateway" "$(tail -3 "$TMP/patch.log")"
if dc up -d --force-recreate --wait --wait-timeout 720 openclaw >"$TMP/up-recreate.log" 2>&1; then
  ok "the recreated gateway becomes healthy"
else
  bad "the recreated gateway becomes healthy" "$(tail -3 "$TMP/up-recreate.log")"
fi

# --- 4. after the next start and its Doctor run ---------------------------------
for _ in $(seq 1 60); do
  dc logs --no-color openclaw >"$TMP/log-final.txt" 2>&1
  grep -qE '\[slack\] \[default\] starting provider|suppressed ambient channel' "$TMP/log-final.txt" && break
  sleep 3
done
sleep 5
dc logs --no-color openclaw >"$TMP/log-final.txt" 2>&1
dc exec -T openclaw cat /home/node/.openclaw/openclaw.json >"$TMP/openclaw.json" 2>/dev/null
python3 -I - "$TMP/openclaw.json" "$CHANNEL" "$CANARY_BOT" "$CANARY_APP" >"$TMP/config-check.txt" 2>&1 <<'PY'
import json, sys
path, channel, *canaries = sys.argv[1:]
raw = open(path).read()
cfg = json.loads(raw)
slack = (cfg.get("channels") or {}).get("slack") or {}
checks = [
    ("channels.slack persists after the next start and Doctor", bool(slack)),
    ("  socket mode, DMs disabled, channel allowlist, no config writes",
     slack.get("mode") == "socket" and slack.get("dmPolicy") == "disabled"
     and slack.get("groupPolicy") == "allowlist" and slack.get("configWrites") is False),
    ("  the channel requires a mention",
     (slack.get("channels") or {}).get(channel) == {"requireMention": True, "users": ["*"]}),
    ("  the slash command is compliance-claw",
     slack.get("slashCommand") == {"enabled": True, "name": "compliance-claw"}),
    ("the known setting survives the upgrade and the Slack addition",
     (cfg.get("messages") or {}).get("ackReaction") == "retained-canary"),
    ("the secret refs stay literal",
     ((cfg.get("gateway") or {}).get("auth") or {}).get("token") == "${OPENCLAW_GATEWAY_TOKEN}"
     and "${PRETORIN_API_KEY}" in raw),
    ("no canary token value is in openclaw.json", not any(c in raw for c in canaries)),
]
for name, passed in checks:
    print(("CFG_OK " if passed else "CFG_BAD ") + name)
PY
while IFS= read -r line; do
  case "$line" in CFG_OK\ *) ok "${line#CFG_OK }" ;; CFG_BAD\ *) bad "${line#CFG_BAD }" ;; esac
done < "$TMP/config-check.txt"
grep -qE '^CFG_(OK|BAD) ' "$TMP/config-check.txt" || bad "the config checker ran" "$(tail -3 "$TMP/config-check.txt")"
dc exec -T openclaw /usr/local/bin/compliance-claw-entrypoint openclaw channels status --json \
  >"$TMP/channels-status.json" 2>/dev/null
if python3 -I -c '
import json, sys
raw = open(sys.argv[1]).read()
s = (json.loads(raw[raw.index("{"):]).get("channels") or {}).get("slack") or {}
sys.exit(0 if s.get("lastStartAt") and s.get("mode") == "socket" else 1)' "$TMP/channels-status.json" 2>/dev/null; then
  ok "native channel status lists a started Slack socket channel"
else
  bad "native channel status lists a started Slack socket channel"
fi
grep -q '\[slack\] \[default\] starting provider' "$TMP/log-final.txt" \
  && ok "the gateway log shows the native Slack provider starting" \
  || bad "the gateway log shows the native Slack provider starting"
grep -q 'suppressed ambient channel' "$TMP/log-final.txt" \
  && bad "the gateway does not suppress the Slack channel" \
  || ok "the gateway does not suppress the Slack channel"
if dc exec -T openclaw sh -c 'ls /home/node/.openclaw/openclaw.json.clobbered.* >/dev/null 2>&1'; then
  bad "no config was restored over the Slack change" "an openclaw.json.clobbered.* file exists"
else
  ok "no config was restored over the Slack change"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'retained-slack-add: PASS — Slack added to retained legacy state survives Doctor (%d checks)\n' "$PASS"
  exit 0
fi
printf 'retained-slack-add: FAIL — %d of %d checks\n' "$FAIL" "$((PASS + FAIL))"
exit 1
