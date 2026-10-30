#!/usr/bin/env bash
#
# Prepare the local file layout consumed by compose.secrets.yaml.
#
#   scripts/init-file-secrets.sh             # empty optional files + new gateway token
#   scripts/init-file-secrets.sh --from-env  # copy existing secret values from .env
#
# Existing destination files are never overwritten. Values are never printed.
# Modes are set only on the directory and files this script creates: an existing
# file keeps its bytes, owner and mode (for example 0400 owned by 1000:1000).
# An existing file that the container user (uid/gid 1000) cannot read stops the
# script with the owner/mode fix; the script never changes that file itself.
#
# RUN IT AGAIN AFTER AN UPGRADE THAT ADDS A SECRET. compose.secrets.yaml resolves
# every secret source at `up` time, so a file this script has not created yet
# fails the whole command. Creating the file empty is what makes a deployment
# that does not use a given credential keep working — an empty file means "not
# configured", not "configured as the empty string". scripts/update.sh checks
# this before it stops anything, and scripts/bootstrap.sh just runs this script.
# This is a LOCAL migration helper; Azure will populate the same filenames under
# /run/compliance-claw-secrets using the VM's managed identity.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FROM_ENV=0

case "${1:-}" in
  '') ;;
  --from-env) FROM_ENV=1 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) printf 'file-secrets: ERROR — unknown option %s\n' "$1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'file-secrets: ERROR — too many arguments\n' >&2; exit 2; }

log() { printf 'file-secrets: %s\n' "$*"; }
die() { printf 'file-secrets: ERROR — %s\n' "$*" >&2; exit 1; }

. "${REPO_ROOT}/scripts/compose-selection.sh"
compose_resolve_selection
SECRET_DIR="${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}"

if [ ! -e "$SECRET_DIR" ] && [ ! -L "$SECRET_DIR" ]; then
  mkdir -p "$SECRET_DIR"
  chmod 700 "$SECRET_DIR"
fi
[ -d "$SECRET_DIR" ] || die "${SECRET_DIR} is not a directory"

# Read a literal NAME=value line without sourcing operator-controlled .env.
env_value() {
  local name="$1" raw=""
  [ -r .env ] || return 0
  raw="$(grep -E "^${name}=" .env | head -1 | cut -d= -f2- | tr -d '\r' || true)"
  # compose's env_file parser strips ONE matching pair of surrounding quotes, so
  # a quoted .env value reaches the container unquoted. Copying it verbatim would
  # migrate a value the .env deployment never used, and the only symptom would be
  # an authentication failure at the provider — with the file looking correct.
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  printf '%s' "$raw"
}

# Return 1 when the file already exists (or is a link), so the caller leaves it
# unchanged. noclobber refuses a file that appears between the test and the write.
write_new() {
  local path="$1" value="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    log "keeping ${path}"
    return 1
  fi
  # `set -e` does not apply inside a function called as an `if` condition.
  ( set -C && umask 077 && printf '%s' "$value" > "$path" ) \
    || die "could not create ${path}"
  log "created ${path}"
}

# Keep sensitive material in a directory the current user can traverse while
# allowing the non-root container user (uid 1000) to read the bind-mounted files.
# Docker Compose file secrets are bind mounts and cannot remap uid/gid/mode.
container_readable_mode() {
  local path="$1"
  chmod 600 "$path"
  if [ "$(id -u)" != 1000 ]; then
    chmod 604 "$path"
  fi
}

EXISTING=()
while IFS='|' read -r name filename; do
  [ -n "$name" ] || continue
  value=""
  if [ "$FROM_ENV" = 1 ]; then
    value="$(env_value "$name")"
  fi
  if [ "$name" = OPENCLAW_GATEWAY_TOKEN ] && [ ! -e "${SECRET_DIR}/${filename}" ] \
     && [ ! -L "${SECRET_DIR}/${filename}" ] && [ -z "$value" ]; then
    command -v openssl >/dev/null 2>&1 || die "openssl is required to generate the gateway token"
    value="$(openssl rand -hex 32)"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || die "could not generate the gateway token"
  fi
  if write_new "${SECRET_DIR}/${filename}" "$value"; then
    container_readable_mode "${SECRET_DIR}/${filename}"
  else
    EXISTING+=("${SECRET_DIR}/${filename}")
  fi
  unset value
done <<'EOF'
PRETORIN_API_KEY|pretorin-api-key
OPENCLAW_GATEWAY_TOKEN|openclaw-gateway-token
OPENCLAW_GATEWAY_PASSWORD|openclaw-gateway-password
SLACK_APP_TOKEN|slack-app-token
SLACK_BOT_TOKEN|slack-bot-token
OPENAI_API_KEY|openai-api-key
ANTHROPIC_API_KEY|anthropic-api-key
GITHUB_READONLY_PAT|github-readonly-pat
EOF

# Compose file secrets are bind mounts: the container's uid-1000 user reads the
# host file with the host owner and mode. Report a file it cannot read, with the
# documented fixes, instead of a later authentication error that blames the key.
if [ "${#EXISTING[@]}" -gt 0 ]; then
  UNREADABLE="$(python3 -c '
import os, stat, sys
for path in sys.argv[1:]:
    st = os.stat(path)
    if not ((st.st_uid == 1000 and st.st_mode & stat.S_IRUSR)
            or (st.st_gid == 1000 and st.st_mode & stat.S_IRGRP)
            or st.st_mode & stat.S_IROTH):
        print(path)
' "${EXISTING[@]}")" || die "could not check the existing secret files"
  if [ -n "$UNREADABLE" ]; then
    printf 'file-secrets: ERROR — the container user (uid 1000) cannot read:\n' >&2
    printf '%s\n' "$UNREADABLE" | sed 's/^/  /' >&2
    printf '%s\n' "  Existing files were not changed. Fix each file with ONE of the documented modes:" \
      "    sudo chown 1000:1000 FILE && sudo chmod 0400 FILE   # VM: docs/file-secrets.md" \
      "    chmod 0604 FILE                                      # local helper mode" >&2
    exit 1
  fi
fi

log "ready. Keep the saved Compose selection (README: Save deployment settings)."
log "  Next: scripts/clawctl plan, then scripts/clawctl apply"
