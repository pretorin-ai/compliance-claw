#!/usr/bin/env bash
#
# entrypoint.sh — seed OpenClaw config and AGENTS.md on first start, then hand
# off to the base image's original entrypoint.
#
# Config is GENERATED here rather than baked into the image because ~/.openclaw
# is a named volume: anything baked would be shadowed by the volume on first
# start, and the volume has to stay authoritative so operator edits survive.
#
# Both seeds are write-if-absent and never clobber. The consequence is
# deliberate and worth knowing: a newer image ships a newer template, but an
# existing volume keeps the old config. `docker compose down -v` is the reset.
#
# This runs for the `cli` service too, which is wanted — one-off CLI commands
# then read the same config the gateway does. That is also why every message
# below goes to stderr: stdout belongs to the wrapped command, and seeding
# chatter on it corrupts `openclaw ... --json` output for any consumer.
set -euo pipefail

CONFIG="${OPENCLAW_CONFIG_PATH:-/home/node/.openclaw/openclaw.json}"
# Must match agents.defaults.workspace in the template, which states the path
# explicitly for exactly this reason.
WORKSPACE="/home/node/.openclaw/workspace"
TEMPLATES="/opt/compliance-claw"

# The gateway needs the token; `docker compose run --rm cli pretorin version`
# does not, and must keep working on a fresh clone with no .env (compose marks
# .env required:false). So the check is scoped to gateway invocations instead of
# being global. OpenClaw would fail closed on its own anyway; this only replaces
# a SecretRefResolutionError pointing at `openclaw gateway status --deep` with a
# message naming the file the operator actually has to edit.
case " $* " in
  *" gateway "*)
    if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
      echo "compliance-claw: OPENCLAW_GATEWAY_TOKEN is unset or empty." >&2
      echo "  The gateway will not start without it." >&2
      echo "  Copy .env.example to .env and set a token (Phase 4's bootstrap generates one)." >&2
      exit 1
    fi
    ;;
esac

if [ -e "$CONFIG" ]; then
  echo "compliance-claw: ${CONFIG} exists, keeping it (template not applied)" >&2
else
  echo "compliance-claw: seeding ${CONFIG}" >&2
  install -D -m 0600 "${TEMPLATES}/openclaw-config.template.json" "$CONFIG"
fi

# 0700 matches the mode OpenClaw itself uses for the workspace, so a seeded
# workspace is indistinguishable from a bootstrapped one.
install -d -m 0700 "$WORKSPACE"
if [ -e "${WORKSPACE}/AGENTS.md" ]; then
  echo "compliance-claw: ${WORKSPACE}/AGENTS.md exists, keeping it" >&2
else
  echo "compliance-claw: seeding ${WORKSPACE}/AGENTS.md" >&2
  install -m 0600 "${TEMPLATES}/agents-md.template" "${WORKSPACE}/AGENTS.md"
fi

# The base image's entrypoint, restated. `exec` matters: without it tini would
# be a child of this shell instead of PID 1, and signal handling and reaping
# would break. The Dockerfile asserts this path exists at build time so a base
# image that moves tini fails the build rather than the deployment.
exec /usr/bin/tini -s -- "$@"
