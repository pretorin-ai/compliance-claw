#!/usr/bin/env bash
#
# update.sh — move an EXISTING deployment to a newer Compliance Claw.
#
#   scripts/update.sh                              # branch route (below)
#   scripts/update.sh --release vX.Y.Z --preview   # show a release; change nothing
#   scripts/update.sh --release vX.Y.Z             # apply that release
#   scripts/update.sh --release vX.Y.Z --effort-records-ready
#                       # apply after the effort-record transfer is complete
#   scripts/update.sh --release vX.Y.Z --save-selection
#                       # also save the release overlay in .env COMPOSE_FILE
#
# BRANCH ROUTE (no options): fast-forward the checkout's upstream branch and
# pull the image that branch pins. This is the explicit custom route. It is not
# a verified release, and it refuses when the release overlay is selected.
#
# RELEASE ROUTE (--release): one resolver serves preview and apply. It fetches
# the tag and the release assets, verifies them, and renders the effective
# Compose model of that release with your saved overlays. Preview prints the
# changes, blockers, required steps and recovery set, and exits 2 when apply
# would refuse. Apply runs the same checks again, pulls the image, checks out
# the tag, installs the release overlay, and checks the model again. Only then
# does it continue with the steps that both routes share:
#
#   1. create any missing built-in secret file, BEFORE anything stops
#   2. pull the selected image        (docker compose pull)
#   3. start and wait for the gateway (Compose wait limit: 720 seconds)
#   4. verify its image, health, and diagnostic result, then report
#
# Idempotent: a second run pulls nothing, recreates nothing, and says so.
#
# WHAT THIS IS NOT. It never runs `down -v`, never edits a config in the state
# volume, and never touches .env or workspace/targets. An update replaces the
# IMAGE; the volumes stay attached. OpenClaw startup can migrate their config
# and databases. Before an OpenClaw upgrade, save and verify both state volumes
# with the gateway stopped. Restore that state with the old image if rollback
# is necessary. An old image alone cannot reverse a database migration.
# See docs/upgrade.md. That is also why a template fix in a new image
# does NOT reach a volume that already has a config: see the drift report below.
#
# AND IT NO LONGER MOVES THE PRETORIN CLI. The image ships a SEED; the CLI a
# deployment actually runs lives in the pretorin-state volume, which this script
# deliberately does not touch. So pulling a newer image gives you a newer seed
# and the same CLI. To move the CLI:
#
#     scripts/pretorin-update.sh latest
#
# The two are separate on purpose: the CLI is an upstream dependency and should
# not need a Compliance Claw release to move.
#
# It refuses rather than guesses. A dirty tree, a diverged branch, a checkout
# with no upstream, a downgrade or a changed state-volume selection are all
# states where "update" means something the script cannot decide for you, so it
# names the problem and the exact command. It never stashes, merges over, or
# overwrites your changes, and it never attempts automatic recovery.
set -euo pipefail

# Bash reads a script while it runs it. The release route checks out a tag that
# can replace this file, so read the complete body before any of it runs.
{
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# WHICH COMMAND REBUILDS THIS DEPLOYMENT. Once efforts.yaml exists it is what the
# deployment reads, and onboard-targets.sh would rebuild the legacy single-effort
# path instead of the fleet.
EFFORTS_FILE="${CC_EFFORTS_FILE:-${REPO_ROOT}/efforts.yaml}"
if [ -f "$EFFORTS_FILE" ]; then
  REBUILD_CMD="scripts/clawctl apply"
  DECLARATION_FILE="efforts.yaml"
else
  REBUILD_CMD="scripts/onboard-targets.sh"
  DECLARATION_FILE="targets.yaml"
fi

log()  { printf 'update: %s\n' "$*"; }
warn() { printf 'update: WARNING — %s\n' "$*" >&2; }
die()  { printf 'update: ERROR — %s\n' "$*" >&2; exit 1; }

# A shell value overrides .env in Compose; remember it before the selection
# helper exports the saved values.
SHELL_COMPOSE_FILE="${COMPOSE_FILE+set}"
RELEASE_TAG=""
PREVIEW=0
RECORDS_READY=0
SAVE_SELECTION=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    --release|--release=*)
      if [ "$1" = --release ]; then
        RELEASE_TAG="${2:-}"; shift "$(( $# >= 2 ? 2 : 1 ))"
      else
        RELEASE_TAG="${1#*=}"; shift
      fi
      [ -n "$RELEASE_TAG" ] || die "--release needs a release tag, for example: --release v0.6.0" ;;
    --preview) PREVIEW=1; shift ;;
    --effort-records-ready) RECORDS_READY=1; shift ;;
    --save-selection) SAVE_SELECTION=1; shift ;;
    *) die "unknown argument '$1'. See: scripts/update.sh --help" ;;
  esac
done
if [ -z "$RELEASE_TAG" ] && { [ "$PREVIEW" = 1 ] || [ "$RECORDS_READY" = 1 ] || [ "$SAVE_SELECTION" = 1 ]; }; then
  die "--preview, --effort-records-ready and --save-selection apply only to a release. Add --release vX.Y.Z."
fi

# THE RELEASE SET. scripts/release-assets.py is the one verifier: it downloads
# the record and overlay, checks them, and checks the effective image selection.
# This script reads only the helper's result, never the record. Both files live
# in the repository root; the overlay sets only the openclaw and cli images.
RELEASE_REMOTE=origin
RELEASE_OVERLAY="compose.release.yaml"
RELEASE_RECORD="compliance-claw-release.json"
RELEASE_HELPER="${REPO_ROOT}/scripts/release-assets.py"
# Per-effort Plan/preflight roots. A release that adds this commit to a
# deployment without it needs the effort-record transfer before it starts.
EFFORT_RECORD_TRANSITION=770969c5348a17d7c120c70c23927b0f978be5a0

# On a failure after the release route changed a file, name what restores the
# previous files. Only the saved COMPOSE_FILE line is put back automatically,
# and only before the gateway is replaced; nothing else is restored.
RECOVERY_NOTE=""
RELEASE_CACHE=""
ENV_OLD_LINE=""
DOWNTIME=0
on_exit() {
  local rc=$?
  if [ "$rc" != 0 ] && [ -n "$ENV_OLD_LINE" ] && [ "$DOWNTIME" = 0 ]; then
    if env_selection restore "$ENV_OLD_LINE" >/dev/null; then
      printf 'update: restored the previous COMPOSE_FILE line in .env\n' >&2
    else
      printf 'update: could NOT restore .env; set this line again by hand:\n  %s\n' \
        "${ENV_OLD_LINE#line:}" >&2
    fi
  fi
  if [ "$rc" != 0 ] && [ -n "$RECOVERY_NOTE" ]; then
    printf '%s\n' "$RECOVERY_NOTE" >&2
  fi
  [ -z "$RELEASE_CACHE" ] || rm -rf "$RELEASE_CACHE"
  return "$rc"
}

# The saved COMPOSE_FILE line in .env: check that it can be changed, replace or
# add it, or put the old line back. Changes no other byte, keeps the mode and
# owner, and replaces the file atomically. `write` prints the old line as
# "line:<text>" or "absent". The selection holds no credential, but the rest of
# .env can: nothing else from the file is printed.
ENV_SELECTION_PY="$(cat <<'PY'
import os, re, sys, tempfile
mode, path, value = sys.argv[1], sys.argv[2], sys.argv[3]
def fail(message):
    sys.exit("update: .env: " + message)
if os.path.islink(path) or not os.path.isfile(path):
    fail("is not a regular file in the repository root")
st = os.stat(path)
if os.geteuid() not in (0, st.st_uid):
    fail("is owned by another user; this user cannot keep its owner")
with open(path, "rb") as f:
    data = f.read()
lines = data.split(b"\n")
named = [i for i, l in enumerate(lines) if re.match(rb"\s*(export\s+)?COMPOSE_FILE\s*=", l)]
if len(named) > 1 or any(not lines[i].startswith(b"COMPOSE_FILE=") for i in named):
    fail("has more than one COMPOSE_FILE line, or one in another form")
old = "line:" + lines[named[0]].rstrip(b"\r").decode("utf-8", "surrogateescape") if named else "absent"
if mode == "check":
    sys.exit(0)
if mode == "write":
    if any(c in value for c in "'\n\r"):
        fail("the new value cannot be written safely")
    quote = re.search(r"[^A-Za-z0-9_./:;,@+=-]", value) or (named and lines[named[0]][13:14] == b"'")
    new = ("COMPOSE_FILE=" + ("'%s'" % value if quote else value)).encode()
else:
    new = None if value == "absent" else value[len("line:"):].encode("utf-8", "surrogateescape")
if named:
    cr = b"\r" if lines[named[0]].endswith(b"\r") else b""
    if new is None:
        del lines[named[0]]
    else:
        lines[named[0]] = new + cr
elif new is not None:
    if lines and lines[-1] == b"":
        lines.insert(len(lines) - 1, new)
    else:
        lines.append(new)
fd, tmp = tempfile.mkstemp(prefix=".env.update.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "wb") as f:
        f.write(b"\n".join(lines))
    os.chmod(tmp, st.st_mode & 0o7777)
    if os.geteuid() == 0:
        os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
if mode == "write":
    print(old)
PY
)"
env_selection() { python3 -c "$ENV_SELECTION_PY" "$1" "${REPO_ROOT}/.env" "${2:-}"; }
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Refusals, before anything is changed.
# ---------------------------------------------------------------------------

# The build overlay and this script want opposite things: it deploys an image
# built from local source, and `docker compose pull` on `compliance-claw:local`
# can only fail. An operator in the dev loop wants a rebuild, not an update.
. "${REPO_ROOT}/scripts/compose-selection.sh"
compose_resolve_selection
if compose_has_file compose.build.yaml; then
    die "COMPOSE_FILE selects the local build overlay, so there is nothing to pull.

  This script updates a deployment that runs the PUBLISHED image. To rebuild
  from local source instead:

    docker compose build && docker compose up -d

  Remove compose.build.yaml from the saved .env selection, or set an explicit
  COMPOSE_FILE selection that uses the published image and your required overlays."
fi

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "not a git checkout, so there is nothing to fast-forward.

  Update the image by hand instead:  docker compose pull && docker compose up -d"

# Read only the project, images, state-volume mounts and secret sources from
# Compose's merged model. Never print the model: it can contain credentials.
MODEL_SUMMARY_PY="$(cat <<'PY'
import json, os, sys
try:
    config = json.load(sys.stdin)
    volumes = config.get("volumes") or {}
    summary = {"project": config["name"], "images": {}, "mounts": {}}
    for service in ("openclaw", "cli"):
        spec = config["services"].get(service)
        if spec is None:
            continue
        summary["images"][service] = spec["image"]
        summary["mounts"][service] = {
            m["target"]: [volumes.get(m.get("source"), {}).get("name", m.get("source", "")),
                          bool(volumes.get(m.get("source"), {}).get("external", False))]
            for m in spec.get("volumes", []) if m.get("type") == "volume"}
    # Only the fields the release helper checks: never pass on the whole model.
    summary["selection"] = {"services": {
        name: {k: config["services"][name][k] for k in ("image", "platform")
               if k in config["services"][name]}
        for name in summary["images"]}}
    summary["secrets"] = sorted({v["file"] for v in (config.get("secrets") or {}).values()
                                 if isinstance(v, dict) and v.get("file")})
    if not isinstance(summary["project"], str) or "openclaw" not in summary["images"]:
        raise ValueError()
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit("update: cannot read the Compose project, images and state volumes")
print(json.dumps(summary, sort_keys=True))
PY
)"

# $1 = COMPOSE_FILE to render ('' = the saved selection).
model_summary() {
  if [ -n "${1:-}" ]; then
    COMPOSE_FILE="$1" docker compose --project-directory "$REPO_ROOT" --profile '*' \
      config --format json | python3 -c "$MODEL_SUMMARY_PY"
  else
    docker compose --profile '*' config --format json | python3 -c "$MODEL_SUMMARY_PY"
  fi
}

# Print one field of a summary or helper result: $1 = JSON, $2... = keys.
json_field() {
  python3 -c '
import json, sys
value = json.loads(sys.argv[1])
for key in sys.argv[2:]:
    value = value.get(key) if isinstance(value, dict) else None
print("" if value is None else (json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value))
' "$@"
}

# Helper exit codes: 1 release data, 3 source checkout, 4 image selection,
# 5 a tool (download, git, Compose) could not run, 6 the release set is unsigned
# or its signature is not verified. Only reads pass --allow-unsigned; the apply
# gate never does, and there is no option or variable that bypasses it.
release_helper() { python3 "$RELEASE_HELPER" "$@"; }

# The version of the release set installed in the repository root, if valid.
installed_release_version() {
  local summary
  [ -f "$RELEASE_HELPER" ] || return 1
  summary="$(release_helper check --dir "$REPO_ROOT" --stage any --allow-unsigned --json 2>/dev/null)" || return 1
  json_field "$summary" version
}

# A verified release set selected at the stable path, as opposed to the neutral
# placeholder overlay that only reserves its place in COMPOSE_FILE.
release_overlay_active() {
  compose_has_file "$RELEASE_OVERLAY" && installed_release_version >/dev/null
}

# ---------------------------------------------------------------------------
# Release route: one resolver for preview and apply.
# ---------------------------------------------------------------------------
BLOCKERS=()
REQUIRED=()
blocker()  { BLOCKERS+=("$*"); }
required() { REQUIRED+=("$*"); }

# Sets R_* from the tag, the verified assets and both Compose models. Adds a
# blocker for every condition that must stop apply before downtime. Changes no
# tracked file, selection, secret, container or volume.
resolve_release() {
  local tag="$1" local_tag r_json mapping cur_version cur_line rc selection_err \
        openclaw_cur openclaw_new slack_cur slack_new missing f secret_abs builtin

  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'${tag}' is not a release tag. Use the form vX.Y.Z, for example v0.6.0."
  R_TAG="$tag"
  R_VERSION="${tag#v}"
  [ -f "$RELEASE_HELPER" ] || die "this checkout has no release verifier (scripts/release-assets.py).
  It predates verified release selection. Use the branch route once:  scripts/update.sh"
  [ "$(git rev-parse --is-shallow-repository)" = false ] \
    || die "this is a shallow Git checkout, so source history cannot be checked.
  Fetch the full history first:  git fetch --unshallow ${RELEASE_REMOTE}"

  RELEASE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/cc-release.XXXXXX")"
  mkdir "${RELEASE_CACHE}/src"

  # Objects and FETCH_HEAD only: no branch, tag or checkout changes.
  log "fetching ${tag} from ${RELEASE_REMOTE}"
  git fetch --quiet --no-tags --refmap= "$RELEASE_REMOTE" "refs/tags/${tag}" \
    || die "could not fetch tag ${tag} from ${RELEASE_REMOTE}. Check the tag name and network access."
  R_COMMIT="$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}')" \
    || die "tag ${tag} does not name a commit."
  local_tag="$(git rev-parse --verify --quiet "refs/tags/${tag}^{commit}" || true)"
  R_LOCAL_TAG="$local_tag"
  if [ -n "$local_tag" ] && [ "$local_tag" != "$R_COMMIT" ]; then
    blocker "the local tag ${tag} names ${local_tag}, but ${RELEASE_REMOTE} names ${R_COMMIT}. Inspect both; do not delete either without review."
  fi

  # The helper downloads a FINAL release set only and checks every asset. Fetch
  # checks integrity only; the signature gate below decides whether apply may
  # use the set.
  log "downloading and verifying the release set"
  rc=0
  r_json="$(release_helper fetch --version "$R_VERSION" --dir "${RELEASE_CACHE}/assets" --json)" || rc=$?
  case "$rc" in
    0) ;;
    5) die "could not download the release set for ${tag} (see the reason above). Check network access. Nothing was changed." ;;
    *) die "${tag} has no valid final release set (see the reason above). A release before release sets has none; use the branch route.
  A candidate on a draft release is qualified by maintainers with:
    scripts/release-assets.py check --dir DIR --stage candidate --version ${R_VERSION}
  Nothing was changed." ;;
  esac
  [ "$(json_field "$r_json" commit)" = "$R_COMMIT" ] && [ "$(json_field "$r_json" tag)" = "$tag" ] \
    || die "the release record names another source than tag ${tag} on ${RELEASE_REMOTE} (${R_COMMIT}). Nothing was changed."
  R_IMAGE="$(json_field "$r_json" image_reference)"
  R_SIGNATURE="$(json_field "$r_json" signature_status)"
  [ -n "$R_IMAGE" ] || die "the release verifier returned no image reference."
  R_OVERLAY="${RELEASE_CACHE}/assets/${RELEASE_OVERLAY}"
  R_RECORD="${RELEASE_CACHE}/assets/${RELEASE_RECORD}"

  # AUTHENTICITY. Apply needs a verified publisher signature. Until signing and
  # its verifier exist, every release set is unsigned and apply refuses it.
  rc=0
  release_helper check --dir "${RELEASE_CACHE}/assets" --version "$R_VERSION" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 6 ] || [ "$R_SIGNATURE" = unsigned ]; then
    blocker "UNVERIFIED: publisher authenticity not checked (signature ${R_SIGNATURE}); apply will refuse this release until signing/verification exists."
  elif [ "$rc" != 0 ]; then
    die "the release set for ${tag} did not pass the apply check (exit ${rc}). Nothing was changed."
  fi

  git archive --format=tar "$R_COMMIT" | tar -x -C "${RELEASE_CACHE}/src" \
    || die "could not read the source of ${tag}."

  # SOURCE. No local commit is dropped, no tracked change is overwritten, and
  # no untracked or ignored file is replaced by a file the tag adds.
  R_HEAD="$(git rev-parse HEAD)"
  R_BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
  if ! git merge-base --is-ancestor "$R_HEAD" "$R_COMMIT"; then
    blocker "the checkout (${R_HEAD}) has commits that ${tag} does not. That is a downgrade or a custom source. Use a newer release, or the branch route for custom source."
  fi
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    blocker "tracked files have local changes. Review them with 'git status' and commit or remove them yourself."
  fi
  # Git replaces ignored files without a warning, also a file at a parent path.
  local parent
  while IFS= read -r -d '' f; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      blocker "${tag} adds ${f}, and a local file already exists at that path. Move it, then try again."
    fi
    parent="$(dirname -- "$f")"
    while [ "$parent" != . ]; do
      if { [ -e "$parent" ] || [ -L "$parent" ]; } && { [ ! -d "$parent" ] || [ -L "$parent" ]; }; then
        blocker "${tag} adds ${f}, and a local file exists at its parent path ${parent}. Move it, then try again."
      fi
      parent="$(dirname -- "$parent")"
    done
  done < <(git diff --no-renames --name-only --diff-filter=A -z "$R_HEAD" "$R_COMMIT")

  # SELECTION. Repository files map to the tag's copies, the release overlay
  # goes directly after compose.yaml, and customer files keep their order.
  mapping="$(git ls-files -z | REPO_ROOT="$REPO_ROOT" SRC="${RELEASE_CACHE}/src" \
    OVERLAY="$R_OVERLAY" STABLE="${REPO_ROOT}/${RELEASE_OVERLAY}" \
    CF="${COMPOSE_FILE:-compose.yaml}" SEP="${COMPOSE_PATH_SEPARATOR:-:}" python3 -c '
import os, sys
env = os.environ
root, sep = os.path.realpath(env["REPO_ROOT"]), env["SEP"]
tracked = set(p for p in sys.stdin.read().split("\0") if p)
stable = env["STABLE"]
candidate, final, selected, problems = [], [], "0", []
stable_entry = os.path.basename(stable)
for index, entry in enumerate(env["CF"].split(sep)):
    path = entry if os.path.isabs(entry) else os.path.join(env["REPO_ROOT"], entry)
    if os.path.lexists(stable) and os.path.exists(path) and os.path.samefile(path, stable):
        selected = "1" if index == 1 else "misplaced"
        stable_entry = entry
        continue
    relative = os.path.relpath(os.path.realpath(path), root)
    if relative in tracked:
        source = os.path.join(env["SRC"], relative)
        if not os.path.isfile(source):
            problems.append("the selected file " + relative + " does not exist in the release")
        candidate.append(source)
    else:
        candidate.append(path)
    final.append(entry)
    if index == 0:
        if relative != "compose.yaml":
            problems.append("COMPOSE_FILE must start with compose.yaml for a release")
        candidate.append(env["OVERLAY"])
        final.append(None)
if any(sep in p for p in candidate):
    problems.append("a temporary path contains the Compose path separator")
print(sep.join(candidate))
print(sep.join(stable_entry if f is None else f for f in final))
print(selected)
for problem in problems:
    print(problem)
')" || die "could not map the saved Compose selection to ${tag}."
  {
    IFS= read -r R_CANDIDATE_FILES
    IFS= read -r R_FINAL_FILES
    IFS= read -r R_OVERLAY_SELECTED
    while IFS= read -r f; do blocker "$f"; done
  } <<< "$mapping"
  # FIRST ADOPTION. The saved selection must name the release overlay directly
  # after compose.yaml. The COMPOSE_FILE line in .env is customer-written, so
  # apply changes it only with --save-selection, and only that one line.
  R_SAVE_SELECTION=0
  case "$R_OVERLAY_SELECTED" in
    1) ;;
    misplaced) blocker "${RELEASE_OVERLAY} must come directly after compose.yaml in COMPOSE_FILE." ;;
    *)
      if [ "$SHELL_COMPOSE_FILE" = set ]; then
        blocker "this shell exports COMPOSE_FILE, which overrides .env. Unset it (unset COMPOSE_FILE) to use the saved selection, or export: COMPOSE_FILE=${R_FINAL_FILES}"
      elif [ -n "${COMPOSE_ENV_FILES:-}" ]; then
        blocker "COMPOSE_ENV_FILES selects other environment files. Save this line in the file that sets COMPOSE_FILE: COMPOSE_FILE=${R_FINAL_FILES}"
      elif ! selection_err="$(env_selection check 2>&1)"; then
        blocker "${selection_err#update: } Save this line by hand: COMPOSE_FILE=${R_FINAL_FILES}"
      elif [ "$SAVE_SELECTION" = 1 ]; then
        R_SAVE_SELECTION=1
        required "apply saves the release overlay in .env (only the COMPOSE_FILE line; the old line is printed and restored if a step fails before the gateway is replaced)."
      else
        blocker "the saved COMPOSE_FILE does not select ${RELEASE_OVERLAY}. Confirm the change of this .env line with --save-selection, or save it by hand: COMPOSE_FILE=${R_FINAL_FILES}"
      fi ;;
  esac

  R_CURRENT="$(model_summary)" || die "could not read the current Compose selection."
  R_CANDIDATE="$(model_summary "$R_CANDIDATE_FILES")" \
    || die "could not render ${tag} with the saved overlays. Check that they still apply to it."
  [ "$(json_field "$R_CANDIDATE" project)" = "$(json_field "$R_CURRENT" project)" ] \
    || blocker "the Compose project name would change. Keep the project that owns the state volumes."
  python3 -c '
import json, sys
current, candidate = (json.loads(a)["mounts"] for a in sys.argv[1:])
sys.exit(any(candidate.get(s, {}).get(t) != v
             for s, mounts in current.items() for t, v in mounts.items()))
' "$R_CURRENT" "$R_CANDIDATE" \
    || blocker "the state-volume selection would change. A restored or recovered volume selection must stay; review the overlays and ${tag} before you continue."
  rc=0
  selection_err="$(json_field "$R_CANDIDATE" selection \
    | release_helper check --dir "${RELEASE_CACHE}/assets" --version "$R_VERSION" --allow-unsigned --rendered - 2>&1 >/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    4) blocker "the effective openclaw or cli image is not the release image: a later overlay sets image (for example a restore overlay). That is a custom selection, which the release route does not apply. Take a new backup, then remove only the two image lines from that overlay and keep its volume lines." ;;
    *) printf '%s\n' "$selection_err" >&2; die "could not check the release image selection. Nothing was changed." ;;
  esac

  # VERSION. Never downgrade over state that a newer release can have migrated.
  R_INSTALLED="$(installed_release_version || true)"
  cur_version="$R_INSTALLED"
  if [ -z "$cur_version" ]; then
    cur_version="$(git show "${R_HEAD}:versions.env" 2>/dev/null | sed -n 's/^IMAGE_VERSION=//p' || true)"
  fi
  R_CURRENT_VERSION="${cur_version:-unknown}"
  if [ -n "$cur_version" ]; then
    cur_line="$(printf '%s\n%s\n' "$cur_version" "$R_VERSION" | sort -V | head -1)"
    [ "$cur_line" = "$cur_version" ] \
      || blocker "${tag} is older than the current release ${cur_version}. A downgrade over migrated state is not supported; restore the matching backup instead."
  fi

  # REQUIRED STEPS AND DOWNLOADS.
  openclaw_cur="$(git show "${R_HEAD}:versions.env" 2>/dev/null | sed -n 's/^OPENCLAW_VERSION=//p' || true)"
  openclaw_new="$(sed -n 's/^OPENCLAW_VERSION=//p' "${RELEASE_CACHE}/src/versions.env" 2>/dev/null || true)"
  if [ "$openclaw_cur" != "$openclaw_new" ]; then
    required "OpenClaw changes ${openclaw_cur:-unknown} -> ${openclaw_new:-unknown}. Startup can migrate state. Stop the gateway and verify a backup of both state volumes first: docs/upgrade.md#openclaw-image-upgrade-and-state-backup"
  fi
  slack_cur="$(git show "${R_HEAD}:versions.env" 2>/dev/null | sed -n 's/^SLACK_PLUGIN_VERSION=//p' || true)"
  slack_new="$(sed -n 's/^SLACK_PLUGIN_VERSION=//p' "${RELEASE_CACHE}/src/versions.env" 2>/dev/null || true)"
  if [ "$slack_cur" != "$slack_new" ]; then
    required "the managed Slack package changes ${slack_cur:-unknown} -> ${slack_new:-unknown}. Gateway startup with Slack configured needs npm registry access."
  fi
  if git merge-base --is-ancestor "$EFFORT_RECORD_TRANSITION" "$R_COMMIT" 2>/dev/null \
     && ! git merge-base --is-ancestor "$EFFORT_RECORD_TRANSITION" "$R_HEAD" 2>/dev/null; then
    if [ "$RECORDS_READY" = 1 ]; then
      required "effort-record transfer: confirmed complete with --effort-records-ready."
    else
      blocker "${tag} separates local Plan and preflight records by effort. Complete docs/upgrade.md#transfer-existing-effort-records with the gateway stopped, then apply with --effort-records-ready."
    fi
  fi

  # SECRET SOURCES. Apply creates missing built-in files empty; it never
  # creates a file that a customer overlay names.
  R_NEW_SECRETS=""
  # The release's init-file-secrets.sh holds the one built-in inventory.
  builtin="$(sed -n 's/^[A-Z_][A-Z0-9_]*|\([a-z0-9-][a-z0-9-]*\)$/\1/p' \
    "${RELEASE_CACHE}/src/scripts/init-file-secrets.sh" 2>/dev/null || true)"
  secret_abs="$(cd -- "${COMPLIANCE_CLAW_SECRET_DIR:-secrets/runtime}" 2>/dev/null && pwd -P || true)"
  missing="$(json_field "$R_CANDIDATE" secrets | python3 -c '
import json, os, sys
for path in json.load(sys.stdin) or []:
    if not os.path.exists(path):
        print(path)
')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if compose_has_file compose.secrets.yaml && [ -n "$secret_abs" ] \
       && [ "$(cd -- "$(dirname -- "$f")" 2>/dev/null && pwd -P)" = "$secret_abs" ] \
       && printf '%s\n' "$builtin" | grep -qxF -- "$(basename -- "$f")"; then
      R_NEW_SECRETS="${R_NEW_SECRETS} $(basename -- "$f")"
    else
      blocker "the secret source ${f} does not exist. Create it with the documented mode; this script does not create custom secret files."
    fi
  done <<< "$missing"

  R_RUNNING="unknown (the gateway container could not be inspected)"
  local cid
  cid="$(docker compose ps --quiet openclaw 2>/dev/null || true)"
  if [[ "$cid" =~ ^[a-f0-9]+$ ]]; then
    R_RUNNING="$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || echo unknown)"
  elif [ -z "$cid" ]; then
    R_RUNNING="no gateway container"
  fi
}

print_recovery_set() {
  printf '  recovery set (keep these until the new release is verified):\n'
  printf '    checkout:      %s%s\n' "$R_HEAD" "${R_BRANCH:+ (branch ${R_BRANCH})}"
  printf '    images:        openclaw %s; cli %s\n' \
    "$(json_field "$R_CURRENT" images openclaw)" "$(json_field "$R_CURRENT" images cli)"
  printf '    running image: %s\n' "$R_RUNNING"
  printf '    COMPOSE_FILE:  %s\n' "${COMPOSE_FILE:-compose.yaml}"
  printf '    project:       %s\n' "$(json_field "$R_CURRENT" project)"
  printf '    state volumes: %s\n' "$(json_field "$R_CURRENT" mounts openclaw)"
  printf '    backup:        a verified stopped-state backup of both volumes,\n'
  printf '                   docs/upgrade.md#openclaw-image-upgrade-and-state-backup\n'
}

print_release_report() {
  printf '\n'
  log "release ${R_TAG}"
  printf '  source:        %s -> %s (%s commit(s))\n' "$R_HEAD" "$R_COMMIT" \
    "$(git rev-list --count "${R_HEAD}..${R_COMMIT}" 2>/dev/null || echo '?')"
  printf '  version:       %s -> %s\n' "$R_CURRENT_VERSION" "$R_VERSION"
  printf '  image:         %s -> %s\n' "$(json_field "$R_CURRENT" images openclaw)" "$R_IMAGE"
  printf '  checked:       tag commit, asset checksums, image digest, effective image\n'
  printf '  signature:     %s\n' "$R_SIGNATURE"
  if [ "$R_SIGNATURE" = unsigned ]; then
    printf '                 UNVERIFIED: not signed; publisher authenticity not checked\n'
  fi
  if [ -n "$R_BRANCH" ]; then
    printf '  checkout:      branch %s -> detached tag %s (release mode; the branch route then refuses)\n' \
      "$R_BRANCH" "$R_TAG"
  fi
  printf '  COMPOSE_FILE:  %s\n' "${COMPOSE_FILE:-compose.yaml}"
  if [ "${COMPOSE_FILE:-compose.yaml}" != "$R_FINAL_FILES" ]; then
    printf '            ->   %s\n' "$R_FINAL_FILES"
  fi
  printf '  project:       %s\n' "$(json_field "$R_CANDIDATE" project)"
  printf '  state volumes: %s\n' "$(json_field "$R_CANDIDATE" mounts openclaw)"
  printf '  downloads:     image %s\n' "$R_IMAGE"
  if [ -n "$R_NEW_SECRETS" ]; then
    printf '  new secrets:   apply creates these empty:%s\n' "$R_NEW_SECRETS"
  fi
  printf '  Pretorin CLI:  not changed (the active CLI is separate from the image seed)\n'
  local item
  if [ "${#REQUIRED[@]}" -gt 0 ]; then
    printf '  required:\n'
    for item in "${REQUIRED[@]}"; do printf '    - %s\n' "$item"; done
  fi
  print_recovery_set
  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    printf '  BLOCKERS (apply stops before it changes anything):\n'
    for item in "${BLOCKERS[@]}"; do printf '    - %s\n' "$item"; done
  fi
  printf '\n'
}

if [ -n "$RELEASE_TAG" ]; then
  resolve_release "$RELEASE_TAG"
  print_release_report

  if [ "$PREVIEW" = 1 ]; then
    if [ "${#BLOCKERS[@]}" -gt 0 ]; then
      log "preview: apply would stop on ${#BLOCKERS[@]} blocker(s). Nothing was changed."
      exit 2
    fi
    log "preview: no blockers. Nothing was changed. To apply:"
    log "  scripts/update.sh --release ${R_TAG}$([ "$RECORDS_READY" = 1 ] && printf ' --effort-records-ready')$([ "$SAVE_SELECTION" = 1 ] && printf ' --save-selection')"
    exit 0
  fi

  if [ "${#BLOCKERS[@]}" -gt 0 ]; then
    die "${#BLOCKERS[@]} blocker(s) above. Nothing was changed and the gateway was not stopped."
  fi

  # Before downtime: the selected image must be local.
  IMAGE_REF="$R_IMAGE"
  log "pulling ${R_IMAGE} before anything changes"
  COMPOSE_FILE="$R_CANDIDATE_FILES" docker compose --project-directory "$REPO_ROOT" pull --quiet 2>/dev/null \
    || COMPOSE_FILE="$R_CANDIDATE_FILES" docker compose --project-directory "$REPO_ROOT" pull \
    || die "could not pull ${R_IMAGE}. Nothing was changed.

  The package is not public, so the pull needs a login:  docker login ghcr.io
  A classic token needs the read:packages scope."
  docker image inspect --format '{{.Id}}' "$R_IMAGE" >/dev/null \
    || die "${R_IMAGE} is not available locally after the pull. Nothing was changed."

  # The helper checks the source through the tag, so record the fetched tag.
  # An existing local tag already names this commit (otherwise a blocker).
  if [ -z "$R_LOCAL_TAG" ]; then
    git fetch --quiet --no-tags --refmap= "$RELEASE_REMOTE" "refs/tags/${R_TAG}:refs/tags/${R_TAG}" \
      || die "could not record tag ${R_TAG} locally. Nothing was changed."
  fi

  # The previous record and overlay are one recovery input: keep them together.
  if [ -f "${REPO_ROOT}/${RELEASE_RECORD}" ] && [ -f "${REPO_ROOT}/${RELEASE_OVERLAY}" ]; then
    PREVIOUS_SET="restore the previous release set: move ${RELEASE_RECORD}.previous and
    ${RELEASE_OVERLAY}.previous back to ${RELEASE_RECORD} and ${RELEASE_OVERLAY}"
  else
    PREVIOUS_SET="remove ${RELEASE_RECORD} and ${RELEASE_OVERLAY} (no release set was installed before)"
  fi
  if [ -n "$R_BRANCH" ]; then
    R_RETURN="git checkout ${R_BRANCH}     # the branch at ${R_HEAD}"
  else
    R_RETURN="git checkout --detach ${R_HEAD}"
  fi
  RECOVERY_NOTE="update: RECOVERY — no automatic recovery was attempted except the COMPOSE_FILE line
  before the gateway was replaced. To return the files:
    ${R_RETURN}
    ${PREVIOUS_SET}
    previous saved selection: COMPOSE_FILE=${COMPOSE_FILE:-compose.yaml}
  If the gateway was replaced, select the previous images and restore the verified
  backup of both state volumes: docs/upgrade.md#openclaw-image-upgrade-and-state-backup"

  if [ "$R_HEAD" != "$R_COMMIT" ]; then
    log "checking out ${R_TAG} (${R_COMMIT})"
    git checkout --quiet --detach "$R_COMMIT" \
      || die "could not check out ${R_TAG}. The gateway was not stopped."
  else
    log "the checkout is already at ${R_TAG}"
  fi
  if cmp -s "$R_OVERLAY" "${REPO_ROOT}/${RELEASE_OVERLAY}" && cmp -s "$R_RECORD" "${REPO_ROOT}/${RELEASE_RECORD}"; then
    log "the ${R_TAG} release set is already installed"
  else
    if [ -f "${REPO_ROOT}/${RELEASE_RECORD}" ] && [ -f "${REPO_ROOT}/${RELEASE_OVERLAY}" ]; then
      for f in "$RELEASE_RECORD" "$RELEASE_OVERLAY"; do
        cp -p "${REPO_ROOT}/${f}" "${REPO_ROOT}/${f}.previous"
      done
    fi
    # The record first, then the overlay that Compose reads; each replaced atomically.
    for f in "$RELEASE_RECORD" "$RELEASE_OVERLAY"; do
      cp "${RELEASE_CACHE}/assets/${f}" "${REPO_ROOT}/${f}.new"
      chmod 644 "${REPO_ROOT}/${f}.new"
      mv -f "${REPO_ROOT}/${f}.new" "${REPO_ROOT}/${f}"
    done
    log "installed the ${R_TAG} release set"
  fi

  if [ "$R_SAVE_SELECTION" = 1 ]; then
    ENV_OLD_LINE="$(env_selection write "$R_FINAL_FILES")" \
      || die "could not save COMPOSE_FILE in .env. The gateway was not stopped."
    log "saved in .env: COMPOSE_FILE=${R_FINAL_FILES}"
    log "  previous line: ${ENV_OLD_LINE#line:}"
    # The value exported from .env would hide the new line.
    unset COMPOSE_FILE
  fi

  # Apply rechecks: the installed set, the tag and HEAD, and the saved selection.
  compose_resolve_selection
  [ "${COMPOSE_FILE:-compose.yaml}" = "$R_FINAL_FILES" ] \
    || die "the saved COMPOSE_FILE is not the verified selection after the change. The gateway was not stopped."
  release_helper check --dir "$REPO_ROOT" --version "$R_VERSION" --source "$REPO_ROOT" --compose \
    || die "the installed release set, source or selection did not verify after checkout. The gateway was not stopped."
  APPLIED="$(model_summary)" || die "could not read the Compose selection after checkout. The gateway was not stopped."
  for key in project mounts images; do
    [ "$(json_field "$APPLIED" "$key")" = "$(json_field "$R_CANDIDATE" "$key")" ] \
      || die "the saved selection does not render the verified ${key} after checkout. The gateway was not stopped."
  done
  log "the saved selection renders the verified release model"
else
  # ---------------------------------------------------------------------------
  # Branch route: fast-forward the upstream branch.
  # ---------------------------------------------------------------------------
  if release_overlay_active; then
    die "the saved COMPOSE_FILE selects the ${RELEASE_OVERLAY} release overlay, so this
  deployment follows a release. A branch fast-forward would mix branch source with
  the release image. Preview the next release instead:

    scripts/update.sh --release vX.Y.Z --preview"
  fi

  if [ -n "$(git status --porcelain)" ]; then
    die "the working tree has uncommitted changes, and a fast-forward would fail.

  Review them:  git status
  Then either commit them, or:  git stash"
  fi

  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [ "$BRANCH" != "HEAD" ] \
    || die "the checkout is in detached HEAD state, so there is no branch to pull.

  For a release checkout, select a release:  scripts/update.sh --release vX.Y.Z --preview
  Or pick the branch to follow:              git checkout master"

  UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  [ -n "$UPSTREAM" ] \
    || die "branch '${BRANCH}' has no upstream, so there is nothing to pull from.

  Set one:  git branch --set-upstream-to=origin/${BRANCH} ${BRANCH}"

  log "fetching ${UPSTREAM}"
  git fetch --quiet "${UPSTREAM%%/*}" || die "could not fetch from ${UPSTREAM%%/*}."

  # Diverged means local commits the remote does not have. --ff-only would fail
  # with git's own message; this one names the branch and the choice.
  BEHIND_AHEAD="$(git rev-list --left-right --count "${UPSTREAM}...HEAD")"
  AHEAD="$(printf '%s' "$BEHIND_AHEAD" | awk '{print $2}')"
  BEHIND="$(printf '%s' "$BEHIND_AHEAD" | awk '{print $1}')"

  if [ "$AHEAD" -gt 0 ]; then
    die "branch '${BRANCH}' has ${AHEAD} commit(s) that ${UPSTREAM} does not, so it
  cannot be fast-forwarded.

  Inspect them:  git log --oneline ${UPSTREAM}..HEAD
  Then rebase:   git pull --rebase
  Or update from a clean branch:  git checkout master && scripts/update.sh"
  fi

  if [ "$BEHIND" -gt 0 ]; then
    log "fast-forwarding ${BRANCH} by ${BEHIND} commit(s)"

    # A release that improves the updater should be the one that performs the
    # rest of this update. The whole body was read before it ran, so replacing
    # the file is safe; hand over to the new copy once. After the merge the
    # branch is up to date, so the new copy takes the `already up to date` path.
    BEFORE="$(git rev-parse "HEAD:scripts/update.sh" 2>/dev/null || true)"
    git merge --ff-only --quiet "$UPSTREAM"
    AFTER="$(git rev-parse "HEAD:scripts/update.sh" 2>/dev/null || true)"

    if [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ] && [ -z "${UPDATE_SH_REEXEC:-}" ]; then
      log "this update changed update.sh itself; continuing with the new copy"
      UPDATE_SH_REEXEC=1 exec bash "${REPO_ROOT}/scripts/update.sh"
    fi
  else
    log "${BRANCH} is already up to date with ${UPSTREAM}"
  fi

  # Read from the one place versions are declared, so the message cannot name a
  # version the deployment does not use.
  IMAGE_REF="$(awk -F= '/^IMAGE_REPO=/{r=$2} /^IMAGE_VERSION=/{v=$2} END{print r":"v}' versions.env)"
  log "this checkout pins ${IMAGE_REF}"
fi

# ---------------------------------------------------------------------------
# SECRET-FILE PREFLIGHT — after the source changed, BEFORE anything stops.
# ---------------------------------------------------------------------------
# A release that adds a file-backed secret adds a `secrets:` entry to
# compose.secrets.yaml, and Compose resolves every secret source at `up` time: a
# file that does not exist yet fails the whole command. On an existing deployment
# that is an outage caused by a credential it may not even use.
#
# init-file-secrets.sh owns the one built-in inventory and its fresh defaults.
# It is write-if-absent and changes no existing file, so it is safe to run on
# every update of the file-secret path. The legacy .env path does not run it.
# If it fails, this stops here, with the deployment still running.
if compose_has_file compose.secrets.yaml; then
  log "preparing built-in secret files (write-if-absent; existing files are not changed)"
  PREPARED="$(bash "${REPO_ROOT}/scripts/init-file-secrets.sh")" \
    || die "could not prepare the secret files (see the reason above). NOTHING WAS STOPPED
  and the running deployment is untouched. Correct it, then re-run this script."
  printf '%s\n' "$PREPARED" | grep '^file-secrets: created ' | sed 's/^/  /' || true
fi

log "For an OpenClaw upgrade, verify a backup of both state volumes first. See docs/upgrade.md."
# Check support before replacing a running gateway. Compose owns the wait;
# this script only verifies its result. Customer deployments need Compose 2.27.2+ (see scripts/compose-selection.sh).
UP_HELP="$(docker compose up --help)" || die "could not check Compose wait support."
case "$UP_HELP" in
  *--wait-timeout*) ;;
  *) die "Docker Compose must support --wait and --wait-timeout. Install Compose 2.27.2 or newer." ;;
esac

# Read only the selected project and gateway image from Compose's merged model.
# Do not print the model: it can contain credentials. Python 3 is already a host
# prerequisite. The base-file pin alone cannot account for customer overlays.
# Every secret source must exist, including one that a customer overlay names:
# Compose would fail `up` on it after the old gateway stopped.
SELECTION="$(docker compose config --format json | python3 -c '
import json, os, sys
try:
    config = json.load(sys.stdin)
    project = config["name"]
    image = config["services"]["openclaw"]["image"]
    if not all(isinstance(v, str) and v and not any(c.isspace() for c in v)
               for v in (project, image)):
        raise ValueError()
    missing = sorted(v["file"] for v in (config.get("secrets") or {}).values()
                     if isinstance(v, dict) and v.get("file") and not os.path.exists(v["file"]))
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit("update: cannot resolve the Compose project and gateway image")
if missing:
    sys.exit("update: these secret sources do not exist: " + ", ".join(missing))
print(project + "\t" + image)
')" || die "could not read the effective Compose selection. NOTHING WAS STOPPED."
IFS=$'\t' read -r SELECTED_PROJECT SELECTED_IMAGE <<< "$SELECTION"
if [ -n "$RELEASE_TAG" ] && [ "$SELECTED_IMAGE" != "$R_IMAGE" ]; then
  die "the selected gateway image is not the verified release image. NOTHING WAS STOPPED."
fi

log "pulling the selected image"
docker compose pull --quiet 2>/dev/null || docker compose pull || die \
  "could not pull ${IMAGE_REF}.

  The package is not public, so the pull needs a login:  docker login ghcr.io
  A classic token needs the read:packages scope."

EXPECTED_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$SELECTED_IMAGE")" \
  || die "could not resolve the selected gateway image: ${SELECTED_IMAGE}."
[[ "$EXPECTED_IMAGE_ID" =~ ^sha256:[a-f0-9]{64}$ ]] \
  || die "the selected gateway image has no unambiguous local image ID."

log "starting the gateway; Compose waits up to 720 seconds for health"
# Name the gateway so an enabled cli profile cannot start a second gateway or
# make Compose wait for a one-shot command. All deployment selection is inherited.
DOWNTIME=1
docker compose up -d --wait --wait-timeout 720 openclaw \
  || die "gateway startup or the Compose health wait failed. Check: docker compose ps -a"

# Use the selected container, never the host port or the diagnostic container.
# Repeat this small check after diagnostics to reject a replaced or failed gateway.
GATEWAY_CID=""
verify_gateway() {
  local cid actual
  cid="$(docker compose ps --all --quiet openclaw)" \
    || die "could not find the selected gateway container."
  [[ "$cid" =~ ^[a-f0-9]+$ ]] \
    || die "expected exactly one gateway container in project ${SELECTED_PROJECT}."
  [ -z "$GATEWAY_CID" ] || [ "$cid" = "$GATEWAY_CID" ] \
    || die "the gateway container changed during verification; update completion is unverified."
  actual="$(docker inspect --format '{{.Image}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}' "$cid")" \
    || die "could not inspect the selected gateway container."
  [ "$actual" = "$EXPECTED_IMAGE_ID running healthy $SELECTED_PROJECT openclaw" ] \
    || die "gateway image, state, health, or Compose ownership did not match.
  Expected: ${EXPECTED_IMAGE_ID} running healthy ${SELECTED_PROJECT} openclaw
  Observed: ${actual:-<missing>}
  Check: docker compose ps -a"
  GATEWAY_CID="$cid"
}
verify_gateway

# ---------------------------------------------------------------------------
# Report. Nothing below this line changes anything.
# ---------------------------------------------------------------------------

# The container itself is the authority on config drift, and it already computes
# this on every start. Re-running the entrypoint through the one-shot `cli`
# service surfaces the same warning here rather than reimplementing the
# comparison — one source of truth, and it cannot drift from the entrypoint's.
STARTUP_RC=0
STARTUP="$(docker compose run --rm -T cli true 2>&1)" || STARTUP_RC=$?

printf '\n'
DRIFT_FOUND=0

if printf '%s' "$STARTUP" | grep -q 'predates the image'; then
  DRIFT_FOUND=1
  warn "this volume's config predates the image you just pulled."
  printf '%s\n' "$STARTUP" | grep -A15 'predates the image' | sed 's/^/  /'
  cat >&2 <<'DRIFT'

  NOTHING WAS OVERWRITTEN, and this script will not edit a config. Templates are
  seeded write-if-absent, so the config already in the volume stays authoritative
  and the new image's template fixes are not active. Two ways out:

    merge by hand — diff your config against the template shipped in the image:
      docker compose run --rm cli cat /opt/compliance-claw/openclaw-config.template.json
      docker compose run --rm cli cat /home/node/.openclaw/openclaw.json
    then record that you have merged it:
      docker compose run --rm cli bash -c \
        'cat /opt/compliance-claw/config-template.version > /home/node/.openclaw/.compliance-claw-templates'

  Use docs/upgrade.md for backup and recovery. Keep the state volumes.
DRIFT
fi

if printf '%s' "$STARTUP" | grep -q 'Slack credentials are supplied but NOT'; then
  DRIFT_FOUND=1
  warn "Slack credentials are supplied but absent from this volume's config."
  printf '%s\n' "$STARTUP" | grep -A10 'Slack credentials are supplied but NOT' | sed 's/^/  /'
fi

if printf '%s' "$STARTUP" | grep -q 'runs MCP from the image seed'; then
  DRIFT_FOUND=1
  warn "this volume runs MCP from the image seed, so CLI updates have no effect."
  printf '%s\n' "$STARTUP" | grep -A8 'runs MCP from the image seed' | sed 's/^/  /'
fi

if printf '%s' "$STARTUP" | grep -q 'still loads the Pretorin skill'; then
  DRIFT_FOUND=1
  warn "this volume's config still loads a skill this image no longer ships."
  printf '%s\n' "$STARTUP" | grep -A8 'still loads the Pretorin skill' | sed 's/^/  /'
fi

if [ "$STARTUP_RC" != 0 ]; then
  printf '%s\n' "$STARTUP" >&2
  die "configuration diagnostic failed (exit ${STARTUP_RC}); configuration status is unknown.
  Update completion is unverified. Check: docker compose ps -a"
fi

verify_gateway
RECOVERY_NOTE=""
if [ "$DRIFT_FOUND" = 0 ]; then
  log "the volume's config is current with this image."
fi

printf '\n'
log "onboarding was NOT touched. Bound sources, the active context and the recipe"
log "set live in the Pretorin state volume and survive an update like this one."
log "Re-run ${REBUILD_CMD} only after 'down -v', or when ${DECLARATION_FILE}"
log "changes — it is idempotent either way."
printf '\n'
log "done. The selected gateway is running and healthy on ${SELECTED_IMAGE}."
log "Image and independent CLI version checks:"
log "  docker compose run --rm cli cat /opt/compliance-claw/versions.env | grep IMAGE_VERSION"
log "  scripts/pretorin-update.sh --status     # the CLI, which this script does NOT move"
exit
}
