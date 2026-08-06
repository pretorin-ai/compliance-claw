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
SLACK_PATCH="${TEMPLATES}/slack-channel.patch.json5"
# The one string that proves the Slack patch was applied to a config. It appears
# nowhere else in any config, so a fixed-string grep is exact — and it costs no
# node startup, which matters because this script runs for every `cli`
# invocation too, of which scripts/smoke.sh makes dozens.
SLACK_MARKER="/opt/compliance-claw/plugins/slack"

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

# --- Slack: is this deployment configured for it? -------------------------
#
# All three or none. Two of three is the failure mode worth being loud about: a
# bot that connects but is in no channel, or a channel allowlist with no tokens,
# both look like the software is broken rather than like configuration is missing.
#
# Tokens are NOT read here beyond emptiness — they are never echoed, never
# written to a file, and never placed in the config. OpenClaw picks them up from
# the environment on its own.
SLACK_CHANNEL_ID="$(printf '%s' "${SLACK_CHANNEL_ID:-}" | tr -d '[:space:]')"
SLACK_PRESENT=0
SLACK_MISSING=""
for v in SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_CHANNEL_ID; do
  eval "val=\${${v}:-}"
  if [ -n "$val" ]; then
    SLACK_PRESENT=$((SLACK_PRESENT + 1))
  else
    SLACK_MISSING="${SLACK_MISSING} ${v}"
  fi
done
unset val
# 3 = configured, 1-2 = partially configured (warn), 0 = Slack not in use (silent).
SLACK_SET=0
[ "$SLACK_PRESENT" = 3 ] && SLACK_SET=1

# Seeds Slack into a freshly written config. Never called on an existing one.
seed_slack() {
  # The channel id becomes a JSON KEY, which is why it cannot be a ${VAR}
  # substitution and has to be interpolated by hand. Validate before
  # interpolating: this is the only operator-supplied value in this script that
  # reaches a config file as text, so a quote or a brace here would be JSON
  # injection into the patch.
  case "$SLACK_CHANNEL_ID" in
    C[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]*)
      case "$SLACK_CHANNEL_ID" in
        *[!A-Z0-9]*)
          echo "compliance-claw: ERROR — SLACK_CHANNEL_ID contains characters that are not A-Z or 0-9." >&2
          echo "  Slack channel IDs look like C0123ABCDEF. Right-click the channel ->" >&2
          echo "  Copy link; the C... value at the end of the URL is the id." >&2
          echo "  Slack was NOT configured. Nothing else was changed." >&2
          return 1 ;;
      esac
      ;;
    *)
      echo "compliance-claw: ERROR — SLACK_CHANNEL_ID is not a Slack channel id." >&2
      echo "  Got: '${SLACK_CHANNEL_ID}'" >&2
      echo "  Expected a stable channel ID such as C0123ABCDEF, NOT a channel name." >&2
      echo "  A name-based key silently never routes under groupPolicy 'allowlist'," >&2
      echo "  which is indistinguishable from the bot being broken — so this fails now." >&2
      echo "  Slack was NOT configured. Nothing else was changed." >&2
      return 1 ;;
  esac

  # Explicit template rather than `mktemp -t NAME`: GNU coreutils rejects a
  # template with fewer than three X's and exits 1, leaving the variable empty.
  # Every return path below removes it explicitly.
  RENDERED="$(mktemp "${TMPDIR:-/tmp}/slack-patch.XXXXXX")"
  sed "s|@SLACK_CHANNEL_ID@|${SLACK_CHANNEL_ID}|" "$SLACK_PATCH" > "$RENDERED"
  if grep -q '@SLACK_CHANNEL_ID@' "$RENDERED"; then
    echo "compliance-claw: ERROR — the Slack patch still holds a placeholder after substitution." >&2
    rm -f "$RENDERED"
    return 1
  fi

  # Gate two. --dry-run validates the merged result against OpenClaw's own config
  # schema and exits non-zero on anything it does not accept, so a value that
  # survived the character check but still produces an invalid config is refused
  # before the real apply touches the file.
  #
  # stdout is redirected to stderr throughout: `openclaw config patch` prints
  # boxed status output, and this script also runs for the `cli` service, where
  # anything on stdout corrupts `openclaw ... --json` for the caller.
  if ! openclaw config patch --file "$RENDERED" --dry-run >&2 2>&1; then
    echo "compliance-claw: ERROR — the Slack config patch failed validation." >&2
    echo "  ${CONFIG} was seeded WITHOUT Slack and was not modified further." >&2
    rm -f "$RENDERED"
    return 1
  fi
  if ! openclaw config patch --file "$RENDERED" >&2 2>&1; then
    echo "compliance-claw: ERROR — applying the Slack config patch failed." >&2
    rm -f "$RENDERED"
    return 1
  fi
  rm -f "$RENDERED"

  # Assert rather than assume. A patch that reports success but leaves no trace
  # would reproduce exactly the silent no-Slack failure this phase exists to
  # remove, one layer down.
  if ! grep -q "$SLACK_MARKER" "$CONFIG"; then
    echo "compliance-claw: ERROR — the Slack patch applied but ${CONFIG} does not" >&2
    echo "  reference ${SLACK_MARKER}. Refusing to report success." >&2
    return 1
  fi
  echo "compliance-claw: Slack configured (socket mode, channel ${SLACK_CHANNEL_ID}, mention-only, DMs disabled)" >&2
  return 0
}

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

  # Slack drift, which the template-version warning above does NOT cover.
  #
  # Never-clobber means an existing config is never re-seeded, so an operator who
  # adds Slack credentials to .env on a deployment that already has a config gets
  # a bot that never connects and no explanation — the message above talks about
  # template versions and says nothing about Slack. That silence is the single
  # worst failure mode in this phase, so it gets its own warning naming both fixes.
  if [ "$SLACK_SET" = 1 ] && ! grep -q "$SLACK_MARKER" "$CONFIG"; then
    echo "compliance-claw: WARNING — Slack is configured in .env but NOT in this volume's config." >&2
    echo "  All three Slack variables are set, yet ${CONFIG} has no channels.slack" >&2
    echo "  and does not load the Slack plugin, so the agent will never appear in Slack." >&2
    echo "  Nothing was overwritten. Two ways forward:" >&2
    echo "    1. Reset (destroys BOTH volumes, keeps workspace/targets):" >&2
    echo "         docker compose down -v && scripts/bootstrap.sh && scripts/onboard-targets.sh" >&2
    echo "    2. Apply the Slack patch to the existing config by hand:" >&2
    echo "         docker compose run --rm cli bash -c \\" >&2
    echo "           'sed \"s|@SLACK_CHANNEL_ID@|\$SLACK_CHANNEL_ID|\" ${SLACK_PATCH} > /tmp/p.json5 \\" >&2
    echo "            && openclaw config patch --file /tmp/p.json5'" >&2
    echo "       then restart the gateway: docker compose restart openclaw" >&2
  fi
else
  echo "compliance-claw: seeding ${CONFIG}" >&2
  install -D -m 0600 "${TEMPLATES}/openclaw-config.template.json" "$CONFIG"

  # Slack, applied on top of the freshly seeded base — the only moment it is ever
  # applied, because the branch above never rewrites an existing config. A
  # deployment with no Slack variables skips this entirely and ends up with a
  # config byte-identical to Phase 4's.
  #
  # A failure here is deliberately NOT fatal: the gateway is still perfectly
  # usable over its loopback port and through `docker compose run --rm cli`, and
  # killing the container would take a working deployment down over an optional
  # channel. seed_slack has already said what went wrong on stderr.
  if [ "$SLACK_SET" = 1 ]; then
    seed_slack || echo "compliance-claw: continuing WITHOUT Slack." >&2
  elif [ "$SLACK_PRESENT" -gt 0 ]; then
    # Partially configured: some Slack variables present, some absent. Silence
    # here would leave the operator debugging a bot that never speaks.
    echo "compliance-claw: WARNING — Slack is only partially configured; it was NOT enabled." >&2
    echo "  Missing:${SLACK_MISSING}" >&2
    echo "  All three of SLACK_BOT_TOKEN, SLACK_APP_TOKEN and SLACK_CHANNEL_ID are" >&2
    echo "  required together. See .env.example and README.md ('Slack')." >&2
    echo "  Fix .env, then reset the config: docker compose down -v && scripts/bootstrap.sh" >&2
  fi

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
