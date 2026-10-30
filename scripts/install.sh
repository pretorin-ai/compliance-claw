#!/usr/bin/env bash
#
# install.sh — guided first installation on a connected Linux amd64 VM.
#
# A thin guide over the existing host scripts. It provisions nothing itself:
# clawctl migrates, validates, plans and applies; init-file-secrets.sh creates
# the secret files; bootstrap.sh clones the targets and pulls the image.
#
#   scripts/install.sh --check [OPTIONS]   # preflight and inspection; no writes
#   scripts/install.sh [OPTIONS]           # install, then report readiness
#
# The release set, required on the first run:
#   --release X.Y.Z --release-dir DIR   (DIR holds compliance-claw-release.json and
#                                        compose.release.yaml for that release)
# scripts/release-assets.py checks the record, the overlay checksum and that this
# checkout is the recorded tag commit before any write and before any other
# script from this checkout runs. This script and the helper come from the same
# checkout, so the manual git/sha256sum check in README.md comes first. The
# record is unsigned: the checks bind the files together; they do not prove
# who made them.
#
# Declaration, only for a new efforts.yaml. A rerun with the same values reuses it:
#   --effort NAME --system-id UUID --framework-id ID
#   --target NAME=https://HOST/REPO.git[#BRANCH]   (repeat; --private-target too)
#   --slack-channel-id C...                        (optional; omit for browser only)
#
# Credentials come from protected files, never from arguments. Each file fills
# an EMPTY secret file only; a different existing value is a conflict:
#   --pretorin-key-file PATH   --openai-key-file PATH | --anthropic-key-file PATH
#   --slack-app-token-file PATH  --slack-bot-token-file PATH  --github-pat-file PATH
# A terminal session is asked for a missing Pretorin or OpenAI key with hidden input.
#
#   --yes   apply the plan without the interactive question
#
# Safe to run again after an interruption. It keeps efforts.yaml, the saved
# Compose selection and its overlay order, .env, clones, and every secret file,
# empty or not. Nothing here runs `down`, deletes a volume or edits OpenClaw
# configuration. Provider/model, external MCP and agent edits stay in the
# native Control UI; see docs/administration.md.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

EFFORTS_FILE="${CC_EFFORTS_FILE:-efforts.yaml}"
PARSE_EFFORTS="scripts/parse-efforts.py"
RELEASE_HELPER="scripts/release-assets.py"
RELEASE_FILES="compliance-claw-release.json compose.release.yaml"
HEALTH_TIMEOUT="${CC_INSTALL_HEALTH_TIMEOUT:-720}"
ENTRYPOINT="/usr/local/bin/compliance-claw-entrypoint"
GUIDE_ADMIN="docs/administration.md"
GUIDE_RECOVERY="docs/upgrade.md"

log()   { printf 'install: %s\n' "$*"; }
warn()  { printf 'install: WARNING — %s\n' "$*" >&2; }
die()   { printf 'install: ERROR — %s\n' "$*" >&2; exit 1; }
stage() { printf '\ninstall: == %s ==\n' "$*"; }

usage() { sed -n '2,39p' "$0"; }

CHECK_ONLY=0 ASSUME_YES=0 RELEASE="" RELEASE_DIR=""
EFFORT="" SYSTEM_ID="" FRAMEWORK_ID="" CHANNEL=""
TARGETS=()
PRETORIN_KEY_FILE="" OPENAI_KEY_FILE="" ANTHROPIC_KEY_FILE=""
SLACK_APP_FILE="" SLACK_BOT_FILE="" GITHUB_PAT_FILE=""

need_value() { [ -n "${2:-}" ] || die "$1 needs a value."; }
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --release) need_value "$@"; RELEASE="$2"; shift 2 ;;
    --release-dir) need_value "$@"; RELEASE_DIR="$2"; shift 2 ;;
    --effort) need_value "$@"; EFFORT="$2"; shift 2 ;;
    --system-id) need_value "$@"; SYSTEM_ID="$2"; shift 2 ;;
    --framework-id) need_value "$@"; FRAMEWORK_ID="$2"; shift 2 ;;
    --slack-channel-id) need_value "$@"; CHANNEL="$2"; shift 2 ;;
    --target) need_value "$@"; TARGETS+=("false=$2"); shift 2 ;;
    --private-target) need_value "$@"; TARGETS+=("true=$2"); shift 2 ;;
    --pretorin-key-file) need_value "$@"; PRETORIN_KEY_FILE="$2"; shift 2 ;;
    --openai-key-file) need_value "$@"; OPENAI_KEY_FILE="$2"; shift 2 ;;
    --anthropic-key-file) need_value "$@"; ANTHROPIC_KEY_FILE="$2"; shift 2 ;;
    --slack-app-token-file) need_value "$@"; SLACK_APP_FILE="$2"; shift 2 ;;
    --slack-bot-token-file) need_value "$@"; SLACK_BOT_FILE="$2"; shift 2 ;;
    --github-pat-file) need_value "$@"; GITHUB_PAT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    # Name only an option, never a value: a mistaken argument can be a secret.
    --*) die "unknown option '${1%%=*}'. Secret values are never arguments; use the --*-file options." ;;
    *) die "unexpected argument (not shown). Secret values are never arguments; use the --*-file options." ;;
  esac
done

[ -z "$RELEASE_DIR" ] || [ -n "$RELEASE" ] \
  || die "--release-dir needs --release X.Y.Z, the version you chose."
[ -z "$OPENAI_KEY_FILE" ] || [ -z "$ANTHROPIC_KEY_FILE" ] \
  || die "give one model key file, not both. The other provider stays unconfigured."

DECLARE=0
if [ -n "${EFFORT}${SYSTEM_ID}${FRAMEWORK_ID}${CHANNEL}" ] || [ "${#TARGETS[@]}" -gt 0 ]; then
  DECLARE=1
  [ -n "$EFFORT" ] && [ -n "$SYSTEM_ID" ] && [ -n "$FRAMEWORK_ID" ] && [ "${#TARGETS[@]}" -gt 0 ] \
    || die "a new effort needs --effort, --system-id, --framework-id and at least one --target."
fi

INTERACTIVE=0
if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=1; fi

WORK_DIR="" TTY_STATE=""
cleanup() {
  [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
  [ -z "$TTY_STATE" ] || stty "$TTY_STATE" 2>/dev/null || true
  return 0
}
# An interrupt stops the run; the EXIT trap then cleans up.
trap cleanup EXIT
trap 'exit 130' INT TERM
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-install.XXXXXX")"

# ---------------------------------------------------------------------------
stage "1/10 preflight: host, tools and Docker"
# ---------------------------------------------------------------------------
# The reference route is a connected Linux amd64 VM. Other hosts use the manual
# Quickstart, where bootstrap.sh checks amd64 emulation. No VM size is checked:
# no minimum has been measured.
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
[ "$HOST_OS" = Linux ] || die "this host is ${HOST_OS}. The guided installation supports Linux amd64 VMs.
  Nothing was changed. Use the manual path: README.md#quickstart"
case "$HOST_ARCH" in
  x86_64|amd64) ;;
  *) die "this host is ${HOST_ARCH}. The guided installation supports Linux amd64 VMs.
  Nothing was changed. Use the manual path: README.md#quickstart" ;;
esac

MISSING=""
for tool in git python3 openssl docker; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="${MISSING} ${tool}"
done
[ -z "$MISSING" ] || die "required host tools are missing:${MISSING}
  Install them with the VM's package manager, then re-run. Nothing was changed."

docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable for this user.
  Start Docker, check this user's access to it, then re-run. Nothing was changed."
DAEMON_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
case "$DAEMON_ARCH" in
  x86_64|amd64) ;;
  *) die "the Docker daemon reports '${DAEMON_ARCH:-unknown}', not x86_64. Nothing was changed." ;;
esac

COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || true)"
python3 - "$COMPOSE_VERSION" <<'PY' || die "Docker Compose '${COMPOSE_VERSION:-missing}' is too old or absent.
  Install Compose v2.27.2 or newer: the host commands need 'config --environment'.
  Nothing was changed."
import re, sys
m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if m and tuple(map(int, m.groups())) >= (2, 27, 2) else 1)
PY
log "Linux ${HOST_ARCH}, Docker Compose ${COMPOSE_VERSION}"

# Persistent and writable: the checkout holds efforts.yaml, .env, the secret
# files and the clones. A memory-backed file system loses them on reboot.
[ -w "$REPO_ROOT" ] || die "${REPO_ROOT} is not writable by this user. Nothing was changed."
for path in workspace secrets .env "$EFFORTS_FILE"; do
  [ ! -e "$path" ] || [ -w "$path" ] || die "${path} exists but is not writable by this user. Nothing was changed."
done
FS_TYPE="$(findmnt -n -o FSTYPE --target "$REPO_ROOT" 2>/dev/null || true)"
[ "$FS_TYPE" != tmpfs ] || die "${REPO_ROOT} is on tmpfs, which does not persist. Install from a
  persistent disk path. Nothing was changed."
log "checkout ${REPO_ROOT} is writable (${FS_TYPE:-file system type unknown})"

# ---------------------------------------------------------------------------
stage "2/10 inspection: existing files and the deployment selection"
# ---------------------------------------------------------------------------
# Each conflict is reported before the first write. Existing customer files are
# reused or refused, never replaced.
CONFLICTS=()
conflict() { CONFLICTS+=("$1"); }

# The release set first: nothing else from this checkout runs before the
# helper agrees that the checkout is the recorded source commit.
release_check() {  # DIR [ARGS] -> the helper's exit code; its messages in CHECK_OUT
  local rc=0
  CHECK_OUT="$(python3 "$RELEASE_HELPER" check --dir "$1" --stage final \
    ${RELEASE:+--version "$RELEASE"} "${@:2}" 2>&1)" || rc=$?
  return "$rc"
}
if [ -n "$RELEASE_DIR" ]; then
  [ -d "$RELEASE_DIR" ] || die "${RELEASE_DIR} is not a directory. Nothing was changed."
  RELEASE_SRC="$(cd -- "$RELEASE_DIR" && pwd)"
else
  RELEASE_SRC=""
  for f in $RELEASE_FILES; do [ ! -e "$f" ] || RELEASE_SRC="$REPO_ROOT"; done
  [ -n "$RELEASE_SRC" ] || die "no release set was given. Download the release you chose and give:
    --release X.Y.Z --release-dir DIR
  See README.md#guided-installation-on-a-linux-amd64-vm. Nothing was changed."
fi
rc=0; release_check "$RELEASE_SRC" --source . || rc=$?
case "$rc" in
  0) log "release set in ${RELEASE_SRC}: final record, overlay checksum and source commit match (unsigned)" ;;
  3) die "this checkout is not the source of the release:
$(printf '%s\n' "$CHECK_OUT" | sed 's/^/    /')
  Check out the release tag, repeat the trust check, then re-run. Nothing was changed." ;;
  *) die "the release set in ${RELEASE_SRC} failed its check (exit ${rc}):
$(printf '%s\n' "$CHECK_OUT" | sed 's/^/    /')
  Do not edit release files. Download the set again, or use the files that were
  placed by an earlier run with --release-dir. Nothing was changed." ;;
esac
RELEASE_TO_PLACE=""
if [ "$RELEASE_SRC" != "$REPO_ROOT" ]; then
  for f in $RELEASE_FILES; do
    if [ ! -e "$f" ]; then
      RELEASE_TO_PLACE="${RELEASE_TO_PLACE} ${f}"
    elif cmp -s "${RELEASE_SRC}/${f}" "$f"; then
      log "keeping ${f} (same release)"
    else
      conflict "${f} in this checkout is from another release or was changed. It is
    not replaced. To move a deployment to another release, use docs/upgrade.md."
    fi
  done
fi

# The shell value wins over .env, as in native Compose. A value present in both
# places with different text is ambiguous for later shells, so it is refused.
SELECTION_KEYS="COMPOSE_FILE COMPOSE_PATH_SEPARATOR COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPLIANCE_CLAW_SECRET_DIR"
saved_line() {
  [ -f .env ] && grep -qE "^$1=" .env || return 1
  grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
TO_SAVE=()
for key in $SELECTION_KEYS; do
  if [ -n "${!key+x}" ]; then
    if saved="$(saved_line "$key")"; then
      [ "$saved" = "${!key}" ] || conflict ".env saves ${key}=${saved}, but this shell exports ${key}=${!key}.
    Keep one value: edit .env, or unset ${key} in this shell."
    else
      TO_SAVE+=("${key}=${!key}")
    fi
  fi
done

. "${REPO_ROOT}/scripts/compose-selection.sh"
compose_resolve_selection || die "the deployment selection did not resolve. A selection that names
  compose.release.yaml before it is placed cannot resolve: unset COMPOSE_FILE in this
  shell and let the installer select it. Nothing was changed."
SEP="${COMPOSE_PATH_SEPARATOR:-:}"
case "$RELEASE_SRC" in
  *"$SEP"*) die "${RELEASE_SRC} contains '${SEP}', the Compose path separator. Move the release
  files to another directory. Nothing was changed." ;;
esac
if [ -z "${COMPOSE_FILE:-}" ]; then
  COMPOSE_FILE="compose.yaml${SEP}compose.release.yaml${SEP}compose.secrets.yaml${SEP}compose.efforts.yaml"
  TO_SAVE+=("COMPOSE_FILE=${COMPOSE_FILE}")
fi
export COMPOSE_FILE
SECRET_DIR="${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}"

FIRST_FILE="${COMPOSE_FILE%%"$SEP"*}"
[ "$FIRST_FILE" -ef compose.yaml ] || conflict "COMPOSE_FILE=${COMPOSE_FILE} does not start with compose.yaml.
    The base file comes first; keep custom overlays after it, in their order."
# By name: the overlay can be selected before it is placed.
AFTER_FIRST="${COMPOSE_FILE#*"$SEP"}"
SECOND_FILE="${AFTER_FIRST%%"$SEP"*}"
case "$SECOND_FILE" in
  compose.release.yaml|./compose.release.yaml|"${REPO_ROOT}/compose.release.yaml") ;;
  *) [ "$AFTER_FIRST" != "$COMPOSE_FILE" ] && [ "$SECOND_FILE" -ef compose.release.yaml ] \
       || conflict "COMPOSE_FILE=${COMPOSE_FILE} does not select compose.release.yaml directly
    after compose.yaml. Put it second; keep the other overlays in their order." ;;
esac
# The same selection with the checked overlay, for a render before placement.
CHECKED_FILE="${FIRST_FILE}${SEP}${RELEASE_SRC}/compose.release.yaml${AFTER_FIRST#"$SECOND_FILE"}"
compose_has_file compose.secrets.yaml || conflict "COMPOSE_FILE=${COMPOSE_FILE} does not select compose.secrets.yaml.
    The guided installation uses file-backed credentials. Add it after compose.yaml."
compose_has_file compose.efforts.yaml || conflict "COMPOSE_FILE=${COMPOSE_FILE} does not select compose.efforts.yaml.
    Add it after compose.secrets.yaml."
! compose_has_file compose.build.yaml || conflict "COMPOSE_FILE=${COMPOSE_FILE} selects the local build overlay.
    The guided installation installs a released image. For a source build, use CONTRIBUTING.md."
log "selection: COMPOSE_FILE=${COMPOSE_FILE}"
log "secret directory: ${SECRET_DIR}"

[ ! -f .env ] || log "keeping .env (contents not shown)"

# The declaration. A new one goes through the real `clawctl migrate` into a
# scratch file, so --check validates it and nothing reaches efforts.yaml yet.
SAFE_RE='^[A-Za-z0-9._~:/?@%+=-]+$'
NEW_EFFORTS=""
if [ "$DECLARE" = 1 ]; then
  for value in "$EFFORT" "$SYSTEM_ID" "$FRAMEWORK_ID" "$CHANNEL"; do
    [ -z "$value" ] || [[ "$value" =~ $SAFE_RE ]] \
      || die "'${value}' contains a character that a declaration cannot hold. Nothing was changed."
  done
  {
    printf 'system_id: %s\nframework_id: %s\ntargets:\n' "$SYSTEM_ID" "$FRAMEWORK_ID"
    for spec in "${TARGETS[@]}"; do
      private="${spec%%=*}"; rest="${spec#*=}"
      name="${rest%%=*}"; url="${rest#*=}"; ref=""
      [ "$name" != "$rest" ] && [ -n "$name" ] && [ -n "$url" ] \
        || die "a target must be NAME=URL[#BRANCH]; got '${rest}'. Nothing was changed."
      case "$url" in *'#'*) ref="${url#*#}"; url="${url%%#*}" ;; esac
      for value in "$name" "$url" "$ref"; do
        [ -z "$value" ] || [[ "$value" =~ $SAFE_RE ]] \
          || die "target '${name}' contains a character that a declaration cannot hold. Nothing was changed."
      done
      printf '  - name: %s\n    url: %s\n' "$name" "$url"
      [ -z "$ref" ] || printf '    ref: %s\n' "$ref"
      [ "$private" = false ] || printf '    private: true\n'
    done
  } > "${WORK_DIR}/targets.yaml"
  NEW_EFFORTS="${WORK_DIR}/efforts.yaml"
  migrate_args=(--name "$EFFORT")
  [ -z "$CHANNEL" ] || migrate_args+=(--slack-channel-id "$CHANNEL")
  if ! out="$(TARGETS_FILE="${WORK_DIR}/targets.yaml" CC_EFFORTS_FILE="$NEW_EFFORTS" \
      bash scripts/clawctl migrate "${migrate_args[@]}" 2>&1)"; then
    printf '%s\n' "$out" | sed "s|${WORK_DIR}/||g" >&2
    die "the effort declaration is not valid; see the message above. Nothing was changed."
  fi
fi

effort_row() {  # FILE EFFORT -> scope, channel and sorted targets, for comparison
  python3 "$PARSE_EFFORTS" scope "$2" "$1" || return 1
  python3 "$PARSE_EFFORTS" agents "$1" | awk -F'\t' -v e="$2" '$1 == e { print "channel=" $6 }'
  python3 "$PARSE_EFFORTS" list "$2" "$1" | LC_ALL=C sort
}
if [ -f "$EFFORTS_FILE" ]; then
  python3 "$PARSE_EFFORTS" validate "$EFFORTS_FILE" \
    || die "${EFFORTS_FILE} is not valid; see the message above. Fix it, then re-run. Nothing was changed."
  log "keeping ${EFFORTS_FILE} ($(python3 "$PARSE_EFFORTS" efforts "$EFFORTS_FILE" | wc -l | tr -d ' ') effort(s))"
  if [ -n "$NEW_EFFORTS" ]; then
    if ! existing="$(effort_row "$EFFORTS_FILE" "$EFFORT" 2>/dev/null)"; then
      conflict "${EFFORTS_FILE} exists and does not declare effort '${EFFORT}'.
    The guided installation does not edit an existing declaration. Add the effort
    with docs/efforts.md, or run again without the declaration options."
    elif [ "$existing" != "$(effort_row "$NEW_EFFORTS" "$EFFORT")" ]; then
      conflict "${EFFORTS_FILE} declares effort '${EFFORT}' with other values (scope,
    credential, channel or targets). It was not changed. Compare:
      python3 ${PARSE_EFFORTS} scope ${EFFORT} ${EFFORTS_FILE}
      python3 ${PARSE_EFFORTS} list ${EFFORT} ${EFFORTS_FILE}"
    else
      log "  effort '${EFFORT}' already matches the given declaration"
    fi
    NEW_EFFORTS=""
  fi
elif [ -z "$NEW_EFFORTS" ]; then
  conflict "${EFFORTS_FILE} does not exist and no declaration was given.
    Give --effort, --system-id, --framework-id and --target, or write ${EFFORTS_FILE}
    from efforts.example.yaml (docs/efforts.md)."
fi

# Credential sources. Readable, nonempty, not readable by other users; and an
# existing nonempty destination must already hold the same value.
SECRET_INPUTS=(
  "pretorin-api-key|${PRETORIN_KEY_FILE}"
  "openai-api-key|${OPENAI_KEY_FILE}"
  "anthropic-api-key|${ANTHROPIC_KEY_FILE}"
  "slack-app-token|${SLACK_APP_FILE}"
  "slack-bot-token|${SLACK_BOT_FILE}"
  "github-readonly-pat|${GITHUB_PAT_FILE}"
)
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo ''; }
for entry in "${SECRET_INPUTS[@]}"; do
  dest="${SECRET_DIR}/${entry%%|*}"; src="${entry#*|}"
  [ -n "$src" ] || continue
  if [ ! -f "$src" ] || [ ! -r "$src" ] || [ ! -s "$src" ]; then
    conflict "${src} (for ${dest}) is not a readable, nonempty file."
    continue
  fi
  case "$(file_mode "$src")" in
    *[4567]) conflict "${src} can be read by other users. Protect it first: chmod 600 ${src}" ; continue ;;
  esac
  if [ -s "$dest" ] && ! cmp -s "$src" "$dest"; then
    conflict "${dest} already holds a different value. It is never overwritten.
    To rotate a credential, follow docs/file-secrets.md#rotation."
  fi
done
for name in pretorin-api-key openai-api-key anthropic-api-key slack-app-token slack-bot-token github-readonly-pat; do
  if [ -s "${SECRET_DIR}/${name}" ]; then state=set
  elif [ -e "${SECRET_DIR}/${name}" ]; then state=empty
  else state=absent; fi
  log "  ${SECRET_DIR}/${name}: ${state}"
done

if [ "${#CONFLICTS[@]}" -gt 0 ]; then
  printf '\n' >&2
  for c in "${CONFLICTS[@]}"; do printf 'install: CONFLICT — %s\n' "$c" >&2; done
  die "${#CONFLICTS[@]} conflict(s) above. Nothing was changed."
fi

# ---------------------------------------------------------------------------
stage "3/10 image access"
# ---------------------------------------------------------------------------
# Before any write. Compose must select the release image for both services
# (a later overlay that sets image is refused), and that image must be present
# or reachable. The merged model is never printed: it can contain credentials.
rc=0
release_check "$RELEASE_SRC" --rendered /dev/stdin \
  < <(COMPOSE_FILE="$CHECKED_FILE" docker compose --profile cli config --format json 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || die "Compose would not run the release image with this selection (exit ${rc}):
$(printf '%s\n' "$CHECK_OUT" | sed 's/^/    /')
  Remove a later overlay that sets image, or fix the selection. Nothing was changed."
IMAGE="$(COMPOSE_FILE="$CHECKED_FILE" docker compose config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    image = json.load(sys.stdin)["services"]["openclaw"]["image"]
    assert isinstance(image, str) and image and not any(c.isspace() for c in image)
except Exception:
    sys.exit(1)
print(image)
')" || die "could not read the gateway image from the selected Compose files.
  Check them:  docker compose config --quiet. Nothing was changed."
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "${IMAGE} is present on this host"
elif docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
  log "${IMAGE} is reachable in its registry"
else
  die "cannot reach ${IMAGE}.
  The package is not public. Log in, then re-run:
    docker login ghcr.io        (a classic token needs read:packages)
  Also check this VM's network route to the registry. Nothing was changed."
fi

if [ "$CHECK_ONLY" = 1 ]; then
  printf '\n'
  log "check complete. No file, container or volume was changed."
  log "Run the same command without --check to install."
  exit 0
fi

# ---------------------------------------------------------------------------
stage "4/10 release set"
# ---------------------------------------------------------------------------
for f in $RELEASE_TO_PLACE; do
  [ ! -e "$f" ] || die "${f} appeared during this run. Nothing more was changed. Re-run."
  cp -- "${RELEASE_SRC}/${f}" "$f"
  chmod 644 "$f"
  log "placed ${f}"
done
rc=0; release_check . --source . --compose || rc=$?
[ "$rc" = 0 ] || die "the placed release set failed its check (exit ${rc}):
$(printf '%s\n' "$CHECK_OUT" | sed 's/^/    /')
  Nothing was started. Keep the files for diagnosis."
log "release ${RELEASE:-set} is placed and selected for openclaw and cli"

# ---------------------------------------------------------------------------
stage "5/10 declaration"
# ---------------------------------------------------------------------------
if [ -n "$NEW_EFFORTS" ]; then
  [ ! -e "$EFFORTS_FILE" ] || die "${EFFORTS_FILE} appeared during this run. Nothing more was changed. Re-run."
  # The migrate header names the scratch input; replace only that path.
  sed "s|${WORK_DIR}/targets.yaml|the scripts/install.sh options|" "$NEW_EFFORTS" > "${WORK_DIR}/placed.yaml"
  python3 "$PARSE_EFFORTS" validate "${WORK_DIR}/placed.yaml" >/dev/null
  cp "${WORK_DIR}/placed.yaml" "$EFFORTS_FILE"
  chmod 644 "$EFFORTS_FILE"
  log "wrote ${EFFORTS_FILE} with effort '${EFFORT}' (clawctl migrate)"
else
  log "using ${EFFORTS_FILE} as it is"
fi

# ---------------------------------------------------------------------------
stage "6/10 secret files"
# ---------------------------------------------------------------------------
save_selection() {
  [ -f .env ] || return 0
  local line
  for line in "${TO_SAVE[@]+"${TO_SAVE[@]}"}"; do
    grep -qE "^${line%%=*}=" .env && continue
    [ -z "$(tail -c1 .env)" ] || printf '\n' >> .env
    printf '%s\n' "$line" >> .env
    log "saved ${line} in .env"
  done
}
save_selection

# Its closing "Use:" hint names a build overlay and `up`; this guide does neither.
bash scripts/init-file-secrets.sh 2>&1 | sed -e '/ready\. Use:/,$d' -e 's/^/  /' \
  || die "init-file-secrets.sh failed; see the output above. Existing files were kept."

fill_secret() {  # NAME SOURCE — write into an empty file only, never print the value
  local dest="${SECRET_DIR}/$1" src="$2"
  [ -n "$src" ] || return 0
  if [ -s "$dest" ]; then
    cmp -s "$src" "$dest" || die "${dest} changed during this run. It was not overwritten."
    log "keeping ${dest} (it already holds this value)"
    return 0
  fi
  cat -- "$src" > "$dest"
  log "wrote ${dest} from ${src} (value not shown)"
}
for entry in "${SECRET_INPUTS[@]}"; do fill_secret "${entry%%|*}" "${entry#*|}"; done

ask_hidden() {  # NAME PROMPT — hidden input into an empty file; Enter skips
  local dest="${SECRET_DIR}/$1" value=""
  [ "$INTERACTIVE" = 1 ] && [ ! -s "$dest" ] || return 0
  # Echo goes off BEFORE the prompt, so keys typed early are not shown either.
  TTY_STATE="$(stty -g)"
  stty -echo
  printf 'install: %s (hidden; press Enter to skip): ' "$2"
  IFS= read -r value || value=""
  stty "$TTY_STATE"
  TTY_STATE=""
  printf '\n'
  if [ -n "$value" ]; then
    printf '%s' "$value" > "$dest"
    log "wrote ${dest} (value not shown)"
  fi
  value=""
}
if python3 "$PARSE_EFFORTS" credentials "$EFFORTS_FILE" | awk -F'\t' '$2 == "default"' | grep -q .; then
  ask_hidden pretorin-api-key "Pretorin API key"
fi
if [ ! -s "${SECRET_DIR}/openai-api-key" ] && [ ! -s "${SECRET_DIR}/anthropic-api-key" ]; then
  ask_hidden openai-api-key "OpenAI API key for the default model"
fi

# Slack follows the declaration. The Slack half of the config is seeded once, on
# the first gateway start, so a declared channel without both tokens stops here.
SLACK_EFFORTS="$(python3 "$PARSE_EFFORTS" agents "$EFFORTS_FILE" | awk -F'\t' '$6 != "" { printf " %s(%s)", $1, $6 }')"
if [ -n "$SLACK_EFFORTS" ]; then
  if [ ! -s "${SECRET_DIR}/slack-app-token" ] || [ ! -s "${SECRET_DIR}/slack-bot-token" ]; then
    die "${EFFORTS_FILE} routes Slack channels:${SLACK_EFFORTS}
  but ${SECRET_DIR}/slack-app-token and slack-bot-token are not both set. Slack
  configuration is seeded on the first start, so nothing was started. Supply both
  (--slack-app-token-file, --slack-bot-token-file), or remove slack_channel_id for
  browser-only use. Then re-run. Files written so far are kept."
  fi
  log "Slack: both tokens set for${SLACK_EFFORTS}"
else
  log "Slack: no channel declared; browser-only access through the Control UI"
fi

# ---------------------------------------------------------------------------
stage "7/10 bootstrap: targets and image"
# ---------------------------------------------------------------------------
bash scripts/bootstrap.sh || die "bootstrap.sh stopped; see its message above.
  Fix the cause, then re-run this command. Existing files and clones were kept."
save_selection
log "Ignore the bootstrap 'Next:' list; this command does those steps now."

# ---------------------------------------------------------------------------
stage "8/10 validate: credentials and Pretorin scope"
# ---------------------------------------------------------------------------
bash scripts/clawctl validate || die "validation failed; see the rows above. Nothing was applied.
  Fix each row, then re-run this command."

# ---------------------------------------------------------------------------
stage "9/10 plan and apply"
# ---------------------------------------------------------------------------
bash scripts/clawctl plan || die "plan failed; see the message above. Nothing was applied."
if [ "$ASSUME_YES" != 1 ]; then
  [ "$INTERACTIVE" = 1 ] || die "the plan above was not applied. Review it, then re-run with --yes."
  printf 'install: apply this plan and start the gateway? [y/N] '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "not applied. Re-run when ready; the files written so far are kept." ;;
  esac
fi
bash scripts/clawctl apply || die "apply failed; see its recovery message above. Keep the state volumes.
  Recovery: ${GUIDE_RECOVERY}"

# ---------------------------------------------------------------------------
stage "10/10 readiness"
# ---------------------------------------------------------------------------
# Distinct results. A local check that passes is not a provider, platform or
# customer task result, and this report does not say otherwise.
READY_FAIL=0
GATEWAY="FAIL" MODEL="NOT READY" deadline=$((SECONDS + HEALTH_TIMEOUT))
while :; do
  cid="$(docker compose ps --quiet openclaw 2>/dev/null || true)"
  if [[ "$cid" =~ ^[a-f0-9]+$ ]]; then
    health="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
    [ "$health" != "running healthy" ] || { GATEWAY="ok"; break; }
    case "$health" in *unhealthy|exited*|dead*) break ;; esac
  fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 5
done
[ "$GATEWAY" = ok ] || READY_FAIL=1

if [ "$GATEWAY" = ok ]; then
  # Local auth/runtime state only (`--check`, not `--probe`): no provider call.
  if docker compose exec -T openclaw "$ENTRYPOINT" openclaw models status --check </dev/null >/dev/null 2>&1; then
    MODEL="ok"
  else
    rc=$?
    [ "$rc" = 2 ] && MODEL="EXPIRING"
  fi
fi
[ "$MODEL" = ok ] || [ "$MODEL" = EXPIRING ] || READY_FAIL=1

AGENTS="$(python3 "$PARSE_EFFORTS" agents "$EFFORTS_FILE" | awk -F'\t' '{ printf " %s", $2 }')"
printf '\n'
log "gateway health          ${GATEWAY}  (container running and healthy)"
log "model configuration     ${MODEL}  (local check; the provider was not contacted)"
log "Pretorin scope/transport ok  (scoped read probe passed in validate; writes not tested)"
log "release record          unsigned (checksums and source commit match; not signed)"
log "first useful task       NOT VERIFIED — still required"
printf '\n'
[ "$GATEWAY" = ok ] || log "  gateway: docker compose ps -a; docker compose logs openclaw. Keep the volumes; ${GUIDE_RECOVERY}"
[ "$MODEL" != "NOT READY" ] || log "  model: supply ${SECRET_DIR}/openai-api-key or anthropic-api-key and re-run, or
           set the provider in the Control UI (${GUIDE_ADMIN}#providers-and-models)."
cat <<EOF
install: Next, the Claw administrator (no SSH needed):
install:   1. Open the Control UI through the approved private route. The gateway
install:      listens on 127.0.0.1:18789 on this VM only.
install:   2. In /settings/model-providers, run Test connection for the model.
install:   3. Select an effort agent:${AGENTS}
install:      and run one approved read-only task against its repositories.
install:   Duties and handoff: ${GUIDE_ADMIN}#duties-and-handoff
install:   Recovery: ${GUIDE_RECOVERY}
EOF
if [ "$READY_FAIL" = 1 ]; then
  die "installation applied, but a local readiness check failed (see above)."
fi
log "done. Local checks passed; the first useful task is still required."
