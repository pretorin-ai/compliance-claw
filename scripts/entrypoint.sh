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
# Sidecar marker for the shipped template set (config + AGENTS.md), living in
# the state volume next to the config it describes. A sidecar rather than a key
# inside openclaw.json: it needs no JSON parsing, it is not an OpenClaw config
# property (so it can never be rejected as unknown), and one marker covers both
# templates. Warn-only by design — see the drift check below.
STAMP="/home/node/.openclaw/.compliance-claw-templates"
SHIPPED_VERSION_FILE="${TEMPLATES}/config-template.version"

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

# The shipped template revision, baked at build time from versions.env.
SHIPPED=0
if [ -r "$SHIPPED_VERSION_FILE" ]; then
  SHIPPED="$(cat "$SHIPPED_VERSION_FILE")"
fi

if [ -e "$CONFIG" ]; then
  echo "compliance-claw: ${CONFIG} exists, keeping it (template not applied)" >&2

  # Drift check. Never-clobber means a newer image ships newer templates while
  # an existing volume keeps the old ones, so the operator has to be told rather
  # than silently running a config that predates the image. Warn only: this
  # never edits or replaces anything.
  #
  # The compare is numeric, so a garbled marker must not reach `-lt` — under
  # `set -e` that would abort every container start, including
  # `docker compose run --rm cli pretorin version`. Unreadable or non-numeric is
  # treated as 0, which warns.
  HAVE=0
  if [ -r "$STAMP" ]; then
    HAVE="$(cat "$STAMP")"
  fi
  case "$HAVE" in
    '' | *[!0-9]*) HAVE=0 ;;
  esac
  case "$SHIPPED" in
    '' | *[!0-9]*) SHIPPED=0 ;;
  esac

  if [ "$HAVE" -lt "$SHIPPED" ]; then
    echo "compliance-claw: WARNING — this volume's config predates the image." >&2
    echo "  volume template version ${HAVE}, image ships ${SHIPPED}." >&2
    echo "  Nothing was overwritten. The config in the volume stays authoritative," >&2
    echo "  so template fixes in this image are NOT active — including" >&2
    echo "  mcp.servers.pretorin.cwd, without which the Pretorin MCP server runs" >&2
    echo "  with its working directory at /app and can register /app as the" >&2
    echo "  repository under review." >&2
    echo "  Diff ${CONFIG} against ${TEMPLATES}/openclaw-config.template.json, or reset with:" >&2
    echo "    docker compose down -v   # DELETES BOTH named volumes: OpenClaw config," >&2
    echo "                             # sessions, agent workspace and custom AGENTS.md," >&2
    echo "                             # AND all Pretorin onboarding state (active" >&2
    echo "                             # context, preflight resolvers, active recipes)." >&2
    echo "                             # Bind-mounted target repos are NOT touched." >&2
    echo "    scripts/bootstrap.sh && scripts/onboard-targets.sh   # both idempotent" >&2
    echo "  After merging the template by hand: echo ${SHIPPED} > ${STAMP}" >&2
  fi
else
  echo "compliance-claw: seeding ${CONFIG}" >&2
  install -D -m 0600 "${TEMPLATES}/openclaw-config.template.json" "$CONFIG"
  # Written only on a fresh seed. An existing config with no marker keeps
  # warning on purpose: writing the marker there would silence a drift that is
  # real, and the operator has not merged anything yet.
  printf '%s\n' "$SHIPPED" > "$STAMP"
  chmod 0600 "$STAMP"
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
