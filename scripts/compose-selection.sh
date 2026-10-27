#!/usr/bin/env bash
# Host selection only. Compose owns dotenv parsing and environment precedence.
# Call from the repository root before deployment-dependent reads or writes.
compose_resolve_selection() {
  local selection name value
  if ! selection="$(set -o pipefail
    docker compose config --environment 2>/dev/null |
      LC_ALL=C awk '/^(COMPOSE_FILE|COMPOSE_PATH_SEPARATOR|COMPOSE_PROJECT_NAME|COMPOSE_PROFILES|COMPLIANCE_CLAW_SECRET_DIR)=/'
  )"; then
    printf '%s\n' 'compose-selection: ERROR — cannot resolve deployment settings. Check Docker Compose (v2.27.2 or newer, for `config --environment`), .env and the selected files. Nothing was started.' >&2
    return 1
  fi
  while IFS='=' read -r name value; do
    case "$name" in
      COMPOSE_FILE|COMPOSE_PATH_SEPARATOR|COMPOSE_PROJECT_NAME|COMPOSE_PROFILES|COMPLIANCE_CLAW_SECRET_DIR)
        export "$name=$value" ;;
    esac
  done <<< "$selection"
}

# Match the repository file itself, not a customer file with the same basename.
# Preserve native order, paths (including spaces), and the configured separator.
compose_has_file() {
  local remaining="${COMPOSE_FILE:-compose.yaml}" sep="${COMPOSE_PATH_SEPARATOR:-:}" path
  while :; do
    path="${remaining%%"$sep"*}"
    [ "$path" -ef "${REPO_ROOT}/$1" ] && return 0
    case "$remaining" in
      *"$sep"*) remaining="${remaining#*"$sep"}" ;;
      *) return 1 ;;
    esac
  done
}
