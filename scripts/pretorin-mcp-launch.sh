#!/usr/bin/env bash
#
# pretorin-mcp-launch.sh — start `pretorin mcp-serve` pinned to ONE effort.
#
#   pretorin-mcp-launch <effort-name>
#
# Installed in the image as /opt/compliance-claw/pretorin-mcp-launch. A later
# release points each per-effort mcp.servers.<name>.command at it; this release
# ships and tests the mechanism.
#
# WHY THIS EXISTS AT ALL.
#
# The gateway process has ONE environment. The config template resolves
# `env: { PRETORIN_API_KEY: "${PRETORIN_API_KEY}" }` from it at config-load time,
# so every MCP child gets the same key — which is exactly what multiple efforts
# cannot use. Writing per-effort key VALUES into openclaw.json would put secrets
# into the state volume, which the whole file-backed secret design exists to
# prevent. So the config names a launcher and an effort, and the launcher reads
# the credential from its mounted file at spawn time.
#
# WHAT MAKES IT TRUSTED.
#
#   - It takes an EFFORT NAME, never a path and never an id. The name is looked
#     up in the read-only mounted efforts.yaml; anything not declared there is
#     refused.
#   - PRETORIN_SYSTEM_ID / PRETORIN_FRAMEWORK_ID are derived FROM THAT FILE, not
#     from argv and not from the MCP config's own `env:` block. The scope pin
#     therefore comes from the read-only mount and cannot drift with a
#     hand-edited openclaw.json.
#   - The credential path comes from scripts/parse-efforts.py, which owns the one
#     and only copy of the ladder. This script does not know the mapping.
#   - It OVERRIDES any inherited PRETORIN_API_KEY. PID 1 exports the legacy
#     credential for the whole container, so a child that failed to resolve its
#     own would otherwise silently run on someone else's key. That is the single
#     worst outcome here, so it is impossible by construction: either this script
#     sets the value it resolved, or it exits non-zero.
#   - FAIL CLOSED, ALWAYS. Missing python3, missing parser, missing efforts.yaml,
#     unknown effort, missing or empty credential file — every one exits non-zero
#     with a named cause. An MCP child that cannot resolve its own credential
#     must not start.
#   - The value is never echoed, never written to disk, and never placed in argv
#     (where `ps` would show it). `exec` replaces this shell so nothing is left
#     holding it in a variable.
#
# The scope pin is what the platform's write guard reads. Measured against CLI
# 0.28.7: with stored context on one framework and this environment on another,
# a cross-scope write is refused naming the ENVIRONMENT's scope, and a
# caller-supplied `allow_scope_override` is ignored. See
# docs/plans/effort-config.md, evidence row #1.
set -euo pipefail

EFFORTS_FILE="${CC_EFFORTS_FILE:-/etc/compliance-claw/efforts.yaml}"
PARSE="${CC_PARSE_EFFORTS:-/opt/compliance-claw/parse-efforts.py}"
# Resolved through PATH, not hardcoded: the image puts the ACTIVE CLI
# (/home/node/.pretorin/bin/pretorin, in the pretorin-state volume) first, so a
# bare name reaches the same binary the gateway configures and an operator gets
# in a shell.
PRETORIN_BIN="${CC_PRETORIN_BIN:-pretorin}"
# The same sentinel the gateway configures as mcp.servers.pretorin.cwd. Without
# it the child inherits /app and Pretorin's CWD-based discovery can register the
# OpenClaw install tree as the repository under review.
CWD="${CC_MCP_CWD:-/opt/compliance-claw/no-repo}"

die() { printf 'pretorin-mcp-launch: ERROR — %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: pretorin-mcp-launch <effort-name> (got $# argument(s)).
  It takes an effort NAME declared in ${EFFORTS_FILE} — never a path, never an id."
EFFORT="$1"

# Fail closed on the toolchain before anything else, and name the missing piece.
# python3 is inherited from the OpenClaw base image rather than installed by our
# Dockerfile, so it is asserted at build time; this is the runtime half of that
# guard. Without it, a base image that dropped python3 would produce MCP children
# that start with the WRONG key rather than not at all.
command -v python3 >/dev/null 2>&1 \
  || die "python3 is not available in this image, so the credential for effort
  '${EFFORT}' cannot be resolved. Refusing to start rather than inheriting the
  container's default Pretorin credential. Rebuild from a base image with python3."
[ -r "$PARSE" ] \
  || die "${PARSE} is missing or unreadable, so the credential for effort
  '${EFFORT}' cannot be resolved. Refusing to start rather than inheriting the
  container's default Pretorin credential."
[ -r "$EFFORTS_FILE" ] \
  || die "${EFFORTS_FILE} is missing or unreadable.
  It is mounted read-only by compose.efforts.yaml; check that the overlay is in
  COMPOSE_FILE:
    export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml"

# One call, three answers, from the one file that owns the schema and the ladder.
if ! SCOPE_LINE="$(python3 "$PARSE" scope "$EFFORT" "$EFFORTS_FILE" 2>&1)"; then
  die "effort '${EFFORT}' could not be resolved from ${EFFORTS_FILE}:
  ${SCOPE_LINE}"
fi
IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID CREDENTIAL_REF <<< "$SCOPE_LINE"
[ -n "${SYSTEM_ID:-}" ] && [ -n "${FRAMEWORK_ID:-}" ] && [ -n "${CREDENTIAL_REF:-}" ] \
  || die "effort '${EFFORT}' resolved to an incomplete scope: '${SCOPE_LINE}'"

if ! CREDENTIAL_PATH="$(python3 "$PARSE" credential-path "$EFFORT" "$EFFORTS_FILE" --container 2>&1)"; then
  die "credential path for effort '${EFFORT}' could not be resolved:
  ${CREDENTIAL_PATH}"
fi

# Presence AND non-emptiness. An empty file means "not configured" everywhere
# else in this deployment, and it must mean the same here rather than becoming
# an empty key that authenticates as nobody.
[ -f "$CREDENTIAL_PATH" ] || die "effort '${EFFORT}' uses credential '${CREDENTIAL_REF}',
  but ${CREDENTIAL_PATH} does not exist in this container.
  On the host that file is:
    default        -> secrets/runtime/pretorin-api-key
    <name>         -> secrets/runtime/pretorin/<name>
  Create it with:  scripts/clawctl credential add ${CREDENTIAL_REF}
  and check compose.efforts.yaml is in COMPOSE_FILE so it is mounted."
[ -r "$CREDENTIAL_PATH" ] || die "effort '${EFFORT}' credential '${CREDENTIAL_REF}' at
  ${CREDENTIAL_PATH} exists but is not readable by this container's user (uid $(id -u)).
  Compose file secrets are bind mounts and cannot remap uid, so the file needs
  mode 0604 when the host user is not uid 1000. Fix it on the host with:
    scripts/clawctl credential add ${CREDENTIAL_REF}"
[ -s "$CREDENTIAL_PATH" ] || die "effort '${EFFORT}' credential '${CREDENTIAL_REF}' at
  ${CREDENTIAL_PATH} is EMPTY. An empty file means 'not configured', not 'the
  empty key'. Paste the Pretorin API key into it on the host."

# THE OVERRIDE. Command substitution strips the conventional trailing newline a
# secret manager writes. Never echoed, never logged, never in argv.
PRETORIN_API_KEY="$(cat -- "$CREDENTIAL_PATH")"
export PRETORIN_API_KEY
# Belt and braces: if anything downstream still consults the _FILE form, point it
# at the same file rather than at the container-wide default.
PRETORIN_API_KEY_FILE="$CREDENTIAL_PATH"
export PRETORIN_API_KEY_FILE

# THE SCOPE PIN. This is what the platform's write guard reads.
export PRETORIN_SYSTEM_ID="$SYSTEM_ID"
export PRETORIN_FRAMEWORK_ID="$FRAMEWORK_ID"

# Diagnostics on stderr only, and only names — never the value. stdout belongs to
# the MCP protocol; anything printed there corrupts the stream.
printf 'pretorin-mcp-launch: effort=%s system=%s framework=%s credential=%s\n' \
  "$EFFORT" "$SYSTEM_ID" "$FRAMEWORK_ID" "$CREDENTIAL_REF" >&2

cd "$CWD" 2>/dev/null || true
exec "$PRETORIN_BIN" mcp-serve
