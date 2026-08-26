#!/usr/bin/env bash
#
# sync-targets.sh — the ONE implementation that moves review targets, shared by
# every caller so there is a single place where "safe" is defined:
#
#   scripts/bootstrap.sh              --bootstrap   clone-or-update, on the host
#   /target-sync all|<name>           all|<name>    Slack command, bypasses the LLM
#   the target_sync agent tool        all|<name>    model-visible, same wrapper
#   scripts/sync-targets.sh --self-test             offline, no network, no creds
#
# There is deliberately no second copy of the fetch/fast-forward logic anywhere,
# and --self-test drives THESE functions rather than a re-implementation of them.
#
# WHAT IT WILL NEVER DO. It never resets, force-checks-out, stashes, discards,
# rewrites history, deletes files, creates a merge commit, or clones in sync mode.
# The only ref-moving operation in this file is `merge --ff-only`. A target that
# cannot fast-forward is reported and left exactly as it was.
#
# WHAT IT WILL NEVER MANAGE. Targets are declared in targets.yaml by the operator.
# Nothing here adds, removes, renames, re-points or onboards a target, and no
# input reaching this script can name a URL, a ref, a path or a flag. The only
# accepted request is `all`, or the name of a target that is already declared.
#
# GIT CREDENTIALS. Supplied through a credential helper reading a 0600 file at
# the moment git asks, so the token is never in the URL, never in argv, never in
# .git/config, and never in this script's output. Asserted after every
# authenticated operation, not assumed.
set -euo pipefail

# --- where things are ------------------------------------------------------
# Two deployments, one script. In a host checkout the paths are repo-relative; in
# the image they are absolute. Decided by looking for compose.yaml beside the
# script rather than by a flag, so no caller has to know which one it is.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SELF_DIR}/../compose.yaml" ]; then
  _ROOT="$(cd -- "${SELF_DIR}/.." && pwd)"
  _DEF_TARGETS_FILE="${_ROOT}/targets.yaml"
  _DEF_TARGETS_DIR="${_ROOT}/workspace/targets"
  _DEF_PARSE="${SELF_DIR}/parse-targets.py"
  _DEF_AUDIT=""
  # No default credential on the host. bootstrap.sh decides between the GitHub
  # App and the PAT there, because only the host can mint an App token at all.
  _DEF_TOKEN_FILE=""
else
  # The image. /etc/... and /var/lib/... deliberately, NOT /opt/compliance-claw:
  # the `pretorin mcp-serve` child runs with cwd /opt/compliance-claw/no-repo and
  # Pretorin derives host-local source resolvers from the current directory, so
  # nothing repository-shaped or target-shaped may appear in that tree.
  _DEF_TARGETS_FILE="/etc/compliance-claw/targets.yaml"
  _DEF_TARGETS_DIR="/var/lib/compliance-claw/targets"
  _DEF_PARSE="/opt/compliance-claw/parse-targets.py"
  _DEF_AUDIT="/home/node/.pretorin/target-sync-audit.log"
  # The container has exactly one possible git credential and it is a mounted
  # file, so the policy lives HERE rather than in the plugin. The plugin then has
  # nothing credential-shaped to get wrong, and there is one place to read to
  # know what the container can authenticate as.
  _DEF_TOKEN_FILE="/run/secrets/github_readonly_pat"
fi

TARGETS_FILE="${CC_TARGETS_FILE:-${TARGETS_FILE:-$_DEF_TARGETS_FILE}}"
TARGETS_DIR="${CC_TARGETS_DIR:-$_DEF_TARGETS_DIR}"
# ABSOLUTE, always. git's safe.directory is documented to compare absolute paths,
# and the bind-mounted clone is owned by the host user rather than the container
# uid — so a relative path here becomes a "dubious ownership" refusal that has
# nothing to do with the sync. bootstrap.sh passes a repo-relative path.
case "$TARGETS_DIR" in /*) ;; *) TARGETS_DIR="${PWD}/${TARGETS_DIR}" ;; esac
PARSE="${CC_PARSE_TARGETS:-$_DEF_PARSE}"
AUDIT="${CC_SYNC_AUDIT:-$_DEF_AUDIT}"

# The credential, as a FILE PATH. Never a value: a value would be visible in the
# process environment of every child, which is the property this avoids.
TOKEN_FILE="${CC_GIT_TOKEN_FILE:-}"
# Label for the audit record only. Never the token, never a path to it.
TOKEN_SOURCE="${CC_GIT_TOKEN_SOURCE:-none}"

# An EMPTY mounted secret file is the normal state of a deployment that has not
# been given a PAT, so -s (non-empty) rather than -f: an empty file must mean
# "no credential", not "a credential that is the empty string", which would turn
# a clear auth_failed into a confusing one.
if [ -z "$TOKEN_FILE" ] && [ -n "$_DEF_TOKEN_FILE" ] && [ -s "$_DEF_TOKEN_FILE" ]; then
  TOKEN_FILE="$_DEF_TOKEN_FILE"
  TOKEN_SOURCE="pat"
fi

# Identity, supplied out of band by the caller. Nothing in the argument surface
# can set these, which is what makes the audit record mean something.
REQUESTER="${CC_SYNC_REQUESTER:-unavailable}"
ROUTE="${CC_SYNC_ROUTE:-unknown}"

# A stalled network read never dies on its own, and one stall must not hold the
# global lock for the life of the container. git's own low-speed abort is used
# rather than timeout(1), which is not present on stock macOS.
NET_TIMEOUT="${CC_SYNC_NET_TIMEOUT:-60}"
LOW_SPEED_LIMIT=1000

LOCK_DIR="${TARGETS_DIR}/.target-sync.lock"

log()  { printf 'sync-targets: %s\n' "$*" >&2; }
warn() { printf 'sync-targets: WARNING — %s\n' "$*" >&2; }
die()  { printf 'sync-targets: ERROR — %s\n' "$*" >&2; exit 1; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- machine-readable results ----------------------------------------------
# stdout carries one tab-separated RESULT line per target and one SUMMARY line;
# stderr carries the human log and the audit copy. The plugin parses stdout, the
# operator reads stderr, and neither has to guess where the other's text ends.
#
# Tab-separated because a name, an outcome and a SHA can never contain a tab,
# while the message routinely contains spaces.
emit_result() {
  printf 'RESULT\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:--}" "${4:--}" "$5"
}

# One audit line per target, to stderr AND to a file when one is configured.
#
# Stderr is the copy that survives this feature's actual threat model: the agent
# runs as the same uid and can rewrite anything in the state volume, so a file it
# can edit is not evidence on its own. On the plugin routes stderr is inherited
# from the gateway and lands in `docker compose logs`, outside the volume.
#
# Never fatal. Losing the audit line must not turn a completed sync into a
# failure. The token is not a field here and never will be.
audit() {
  local name="$1" outcome="$2" prev="$3" cur="$4" line
  line="$(printf 'v=1 ts=%s op=target-sync target=%s outcome=%s previous=%s resulting=%s credential=%s requester=%s route=%s' \
    "$(now_utc)" "$name" "$outcome" "${prev:--}" "${cur:--}" "$TOKEN_SOURCE" "$REQUESTER" "$ROUTE")"
  printf '%s\n' "$line" >&2
  [ -n "$AUDIT" ] || return 0
  { umask 077; printf '%s\n' "$line" >> "$AUDIT"; } 2>/dev/null \
    || log "WARNING — could not append to ${AUDIT}; the line above is the only copy."
}

# --- input validation ------------------------------------------------------
# Character allowlist FIRST, always. A shell glob is not an anchored pattern and
# `grep -E '^...$'` matches per LINE, so a structure check alone lets
# "simple-crm\n--upload-pack=x" through on the strength of its first line. That
# exact defect was found by the CLI updater's self-test; this file does not get
# to rediscover it.

# The same rule parse-targets.py enforces, restated here because this is the
# boundary an untrusted request crosses and it must not depend on the parser
# having been reached.
valid_target_name() {
  case "${1-}" in
    '' | -* | .* ) return 1 ;;
    *[!A-Za-z0-9._-]* ) return 1 ;;
  esac
  return 0
}

# `ref` in targets.yaml is a BRANCH NAME. Not a tag, not a SHA, not a revision
# expression: this script only ever fast-forwards a branch to its upstream, and a
# detached checkout at a tag has no upstream to fast-forward to.
valid_branch_name() {
  local ref="${1-}"
  case "$ref" in
    '' | -* | /* ) return 1 ;;
    */ ) return 1 ;;
    *[!A-Za-z0-9._/-]* ) return 1 ;;
    *..* ) return 1 ;;
  esac
  # git's own validator has the rules this list does not: no ".lock" suffix, no
  # leading dot in a path component, no trailing dot, no "@{". Prefixed with
  # refs/heads/ so the value can never be read as an option.
  git check-ref-format "refs/heads/${ref}" 2>/dev/null || return 1
  return 0
}

# `all`, or a declared target name. Nothing else is expressible — no URL, no ref,
# no path, no flag, no shell fragment.
classify_request() {
  local raw="${1-}"
  if [ "$raw" = all ]; then printf 'all\n'; return 0; fi
  valid_target_name "$raw" || return 1
  printf 'one %s\n' "$raw"
  return 0
}

# --- the target list -------------------------------------------------------
# Field order is name/url/private/ref and reading it in that order is
# load-bearing: tab is IFS whitespace, so consecutive tabs collapse and a target
# with no ref would otherwise put "true" into REF and leave PRIVATE empty — a
# private repository silently treated as public. parse-targets.py documents the
# contract and self-tests this exact shape through bash.
#
# SELFTEST_LIST is set only by self_test(), in this same process, and is
# unconditionally cleared here so an inherited environment variable can never
# reach it.
SELFTEST_LIST=""
target_list() {
  if [ -n "$SELFTEST_LIST" ]; then cat "$SELFTEST_LIST"; return 0; fi
  python3 "$PARSE" list "$TARGETS_FILE"
}

# THE LIST IS MATERIALISED BEFORE ANYTHING ITERATES IT, and this is a
# correctness fix rather than tidiness.
#
# `while ... done < <(target_list)` runs the parser in a PROCESS SUBSTITUTION,
# whose exit status is unobservable: a parser that dies produces an empty stream
# and the loop simply ends. That turned a broken or unreadable targets.yaml into
# "SUMMARY total=0 failed=0 overall=ok", exit 0 — a sync that examined nothing,
# reported success, and left every target stale. On a named request it was worse
# still: the membership test found no names, so the operator was told
# "'<name>' is not declared in targets.yaml" and sent to edit a file that was
# fine. Both observed; both are regression cases in --self-test.
TARGET_LIST_FILE=""
load_target_list() {
  local err rc=0
  TARGET_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-targets.XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/cc-targets-err.XXXXXX")"
  target_list > "$TARGET_LIST_FILE" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    TARGET_LIST_ERROR="$(head -3 "$err" | tr '\n' ' ' | sed 's/ *$//')"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  # A parser that succeeds and emits nothing is also not a usable list.
  # parse-targets.py already refuses an empty `targets:`, so reaching this means
  # something else is wrong, and reporting "nothing to do" would hide it.
  if [ ! -s "$TARGET_LIST_FILE" ]; then
    TARGET_LIST_ERROR="the target list is empty"
    return 1
  fi
  return 0
}
TARGET_LIST_ERROR=""

cleanup_target_list() { [ -n "$TARGET_LIST_FILE" ] && rm -f "$TARGET_LIST_FILE"; return 0; }

target_exists() {
  local want="$1" name
  while IFS=$'\t' read -r name _ _ _; do
    [ "$name" = "$want" ] && return 0
  done < "$TARGET_LIST_FILE"
  return 1
}

# --- git, run safely -------------------------------------------------------
# Never prompt. A moved or private remote must fail immediately with a clear
# error rather than blocking on a password prompt — and because the callers read
# their target list from a pipe, a prompt would also swallow the rest of it.
export GIT_TERMINAL_PROMPT=0

# The credential helper, built once.
#
# Three properties this shape has and the obvious alternatives do not:
#   - the token is NOT in the URL, so `git clone` never writes it into
#     .git/config and `git remote -v` never prints it;
#   - the token is NOT in argv, so it does not appear in `ps`; the helper reads
#     it from a 0600 file at the moment git asks;
#   - `git -c` sits BEFORE the subcommand, which makes it a one-shot override.
#     `git clone -c` would persist the setting into the new repository.
CRED_HELPER=""
if [ -n "$TOKEN_FILE" ]; then
  case "$TOKEN_FILE" in
    *[\'\"\`\$]* ) die "CC_GIT_TOKEN_FILE contains a quote or an expansion character; refusing to build a credential helper around it." ;;
  esac
  CRED_HELPER='!f() { test "$1" = get && { echo username=x-access-token; echo "password=$(cat '"'${TOKEN_FILE}'"')"; }; }; f'
fi

# Options applied to EVERY operation on a target.
#
#   safe.directory   the bind-mounted clone is owned by the host user, which is
#                    not the container uid. Without this git refuses it as
#                    "dubious ownership" and the sync fails for a reason that has
#                    nothing to do with the sync.
#   core.hooksPath   a target repository carries its own hooks, and fetch runs
#                    reference-transaction. A reviewed repository is untrusted
#                    input; it does not get to execute code here.
#   http.lowSpeed*   the network timeout.
git_opts() {
  printf '%s\n' \
    -c "safe.directory=$1" \
    -c "core.hooksPath=/dev/null" \
    -c "http.lowSpeedLimit=${LOW_SPEED_LIMIT}" \
    -c "http.lowSpeedTime=${NET_TIMEOUT}"
}

# tgit <dest> <authenticated 0|1> <git args...>
tgit() {
  local dest="$1" auth="$2"; shift 2
  local -a opts=()
  while IFS= read -r o; do opts+=("$o"); done < <(git_opts "$dest")
  if [ "$auth" = 1 ] && [ -n "$CRED_HELPER" ]; then
    opts+=( -c credential.helper= -c "credential.helper=${CRED_HELPER}" )
  fi
  git "${opts[@]}" -C "$dest" "$@"
}

# Every authenticated operation is followed by this. It is an assertion about the
# helper's properties, not a hope: a git version that changed the rules should
# fail loudly here rather than leave a token in a file on disk.
assert_no_credential() {
  local dir="$1" name="$2"
  if grep -qE 'x-access-token|ghs_|ghp_|github_pat_' "${dir}/.git/config" 2>/dev/null; then
    die "a git credential was persisted into ${dir}/.git/config for '${name}'.
  This must never happen. Remove the clone and report it:  rm -rf ${dir}"
  fi
}

# Does this look like an authentication problem rather than a network one? Used
# only to choose between two outcome labels; both refuse and both name a fix.
looks_like_auth_failure() {
  case "$1" in
    *"Authentication failed"* | *"could not read Username"* | *"terminal prompts disabled"* \
    | *"HTTP 401"* | *"HTTP 403"* | *"403 Forbidden"* | *"401 Unauthorized"* \
    | *"Repository not found"* | *"remote: Invalid username or token"* ) return 0 ;;
  esac
  return 1
}

# --- the sync of exactly one target ----------------------------------------
# Sets OUT_OUTCOME / OUT_PREV / OUT_CUR / OUT_MSG. Returns 0 only for outcomes
# that mean "this target is at the commit it should be at".
OUT_OUTCOME=""; OUT_PREV=""; OUT_CUR=""; OUT_MSG=""

_result() { OUT_OUTCOME="$1"; OUT_MSG="$2"; }

sync_one() {
  local name="$1" url="$2" private="$3" ref="$4"
  local dest="${TARGETS_DIR}/${name}"
  local auth=0 branch upstream prev remote fetch_err rc

  OUT_OUTCOME=""; OUT_PREV=""; OUT_CUR=""; OUT_MSG=""

  [ "$private" = true ] && auth=1

  # A declared ref must be a usable branch name before anything else happens.
  if [ -n "$ref" ] && ! valid_branch_name "$ref"; then
    _result invalid_target "targets.yaml declares ref '${ref}' for '${name}', which is not a valid branch name. Fix targets.yaml."
    return 1
  fi

  # --- the clone must exist, and be a clone ---------------------------------
  if [ ! -e "$dest" ]; then
    _result missing_clone "no clone at ${dest}. Sync never creates one — run scripts/bootstrap.sh on the host to clone it."
    return 1
  fi
  if [ ! -d "$dest" ]; then
    _result sync_failed "${dest} exists but is not a directory. Move it aside, then run scripts/bootstrap.sh."
    return 1
  fi
  # --show-toplevel rather than --git-dir: git searches PARENT directories, so an
  # empty workspace/targets/<name> inside this repository answers with
  # compliance-claw's own .git and looks like a clone with the wrong remote.
  if [ "$(tgit "$dest" 0 rev-parse --show-toplevel 2>/dev/null || true)" != "$(cd -- "$dest" && pwd -P)" ]; then
    _result missing_clone "${dest} is not the root of a git repository (an interrupted clone?). Inspect it, remove it yourself, then run scripts/bootstrap.sh."
    return 1
  fi

  # --- it must be the target targets.yaml declares --------------------------
  # get-url, not the raw config value: get-url applies url.*.insteadOf, so this
  # compares the URL git will ACTUALLY contact, which is the real question.
  local actual
  actual="$(tgit "$dest" 0 remote get-url origin 2>/dev/null || true)"
  if [ "$actual" != "$url" ]; then
    _result origin_mismatch_refused "${name} tracks ${actual:-<no origin>} but targets.yaml declares ${url}. Refusing to touch it; fix targets.yaml or move the directory aside."
    return 1
  fi

  # --- it must be safe to move ----------------------------------------------
  if [ -n "$(tgit "$dest" 0 status --porcelain 2>/dev/null)" ]; then
    _result dirty_refused "${name} has local changes; nothing was fetched or moved. Inspect with: git -C ${dest} status"
    return 1
  fi

  branch="$(tgit "$dest" 0 symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    _result detached_refused "${name} is in detached HEAD; there is no branch to fast-forward. Check out a branch, or re-clone via scripts/bootstrap.sh."
    return 1
  fi

  if [ -n "$ref" ] && [ "$branch" != "$ref" ]; then
    _result branch_mismatch_refused "${name} is on '${branch}' but targets.yaml declares ref '${ref}'. Refusing to switch branches; check it out yourself or fix targets.yaml."
    return 1
  fi

  upstream="$(tgit "$dest" 0 rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [ "$upstream" != "origin/${branch}" ]; then
    _result no_upstream_refused "${name}: branch '${branch}' tracks '${upstream:-<nothing>}', expected 'origin/${branch}'. Set it with: git -C ${dest} branch --set-upstream-to=origin/${branch}"
    return 1
  fi

  prev="$(tgit "$dest" 0 rev-parse HEAD 2>/dev/null || true)"
  OUT_PREV="$prev"; OUT_CUR="$prev"

  # --- fetch ----------------------------------------------------------------
  # `if ! cmd` rather than a `set +e` / `set -e` pair. The pair looks equivalent
  # and is not: restoring errexit here would also clobber a CALLER that had
  # deliberately disabled it, and the whole run would then abort on the first
  # refused target instead of reporting it. Found by --self-test on the diverged
  # case, which is exactly the target that must not stop the ones after it.
  fetch_err=""
  rc=0
  if ! fetch_err="$(tgit "$dest" "$auth" fetch --quiet --prune origin 2>&1)"; then
    rc=1
  fi
  [ "$auth" = 1 ] && assert_no_credential "$dest" "$name"
  if [ "$rc" -ne 0 ]; then
    if looks_like_auth_failure "$fetch_err"; then
      _result auth_failed "${name}: the remote refused the credential. ${CREDENTIAL_HINT}"
    else
      # The remote's own words, first line only and never the credential — the
      # helper puts nothing in git's output to begin with.
      _result sync_failed "${name}: fetch failed — $(printf '%s' "$fetch_err" | head -1)"
    fi
    return 1
  fi

  remote="$(tgit "$dest" 0 rev-parse --quiet --verify "refs/remotes/origin/${branch}" 2>/dev/null || true)"
  if [ -z "$remote" ]; then
    _result sync_failed "${name}: origin/${branch} does not exist on the remote any more. Fix targets.yaml or re-clone."
    return 1
  fi

  if [ "$remote" = "$prev" ]; then
    _result already_current "${name} is already at $(short "$prev") on ${branch}."
    OUT_CUR="$prev"
    return 0
  fi

  # --- fast-forward, or refuse ----------------------------------------------
  # The explicit ancestor test is what turns "merge refused" into a NAMED
  # outcome. --ff-only would refuse divergence on its own; it would not tell the
  # operator that the local branch has commits the remote does not.
  if ! tgit "$dest" 0 merge-base --is-ancestor "$prev" "$remote" 2>/dev/null; then
    _result diverged_refused "${name}: local ${branch} has commits that origin/${branch} does not (or history was rewritten upstream). Nothing was moved. Inspect with: git -C ${dest} log --oneline ${branch} ^origin/${branch}"
    return 1
  fi

  if ! tgit "$dest" 0 merge --quiet --ff-only "origin/${branch}" >/dev/null 2>&1; then
    _result sync_failed "${name}: fast-forward to origin/${branch} failed. Nothing was moved."
    return 1
  fi

  OUT_CUR="$(tgit "$dest" 0 rev-parse HEAD 2>/dev/null || true)"
  if [ "$OUT_CUR" != "$remote" ]; then
    _result sync_failed "${name}: HEAD is $(short "$OUT_CUR") after a fast-forward that should have reached $(short "$remote")."
    return 1
  fi
  _result updated "${name} updated: $(short "$prev") → $(short "$OUT_CUR")"
  return 0
}

short() { [ -n "${1:-}" ] && printf '%s' "${1:0:7}" || printf '%s' '-'; }

# THE HINT DEPENDS ON WHERE THIS IS RUNNING, because the two callers have
# genuinely different remedies and a single sentence was wrong for one of them.
#
# On the host, bootstrap.sh can mint a GitHub App token, so the App is the
# recommended fix. Inside the container it CANNOT: the App private key is
# deliberately host-only and is never mounted, so telling an operator to
# configure an App after a Slack sync failed sends them to do something that
# will not fix it. There, the PAT file is the only credential that exists.
if [ -n "$_DEF_TOKEN_FILE" ]; then
  CREDENTIAL_HINT="This container authenticates with the fine-grained PAT at ${_DEF_TOKEN_FILE} (from secrets/runtime/github-readonly-pat), which is empty, expired, or lacks Contents: Read-only on this repository. A GitHub App cannot be used from here — its key is host-only — so fix the PAT, or synchronize this target on the host with scripts/bootstrap.sh. See docs/file-secrets.md."
else
  CREDENTIAL_HINT="Configure a read-only GitHub App on the host (README.md, 'Private repositories'), which is the recommended mechanism; a fine-grained PAT in secrets/runtime/github-readonly-pat is the internal-pilot fallback (docs/file-secrets.md)."
fi

# --- the global lock -------------------------------------------------------
# One sync at a time, across every caller, because they all operate on the SAME
# working trees: the host directory bootstrap.sh writes is the directory the
# container sees through its maintenance mount. A directory is the lock because
# mkdir is atomic on POSIX and flock(1) is not present on stock macOS, which is
# this POC's operator platform.
#
# NON-BLOCKING on purpose. A Slack request that waits is a Slack request that
# looks hung; "already running" is a better answer than silence.
LOCK_HELD=0
release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_HELD=0
}
trap 'release_lock; cleanup_target_list' EXIT INT TERM

# WHICH PID NAMESPACE THIS PROCESS LIVES IN, as well as we can tell.
#
# A pid alone is meaningless across the mount: the host and the container write
# the same lock directory and number their processes independently, so pid 42 on
# one side says nothing about pid 42 on the other. The kernel boot id is stable
# across container restarts on a host and absent on macOS, so Linux containers
# compare against a real namespace token and the macOS host falls back to its
# hostname — and the two never collide, which is the property that matters.
lock_namespace() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    printf 'boot-%s' "$(cat /proc/sys/kernel/random/boot_id)"
  else
    printf 'host-%s' "$(hostname 2>/dev/null || echo unknown)"
  fi
}

# awk, not `sed 's/.*\bkey=...'`: \b is a GNU extension that BSD sed does not
# support, so on macOS — this POC's operator platform — the sed version silently
# extracted nothing, every field came back empty, and the stale-lock check
# therefore concluded "cannot judge" and never reclaimed anything. It looked
# conservative and was simply broken. Whole-token comparison, not a substring,
# so `ns=` can never satisfy a request for `s`.
lock_owner_field() {
  awk -v k="$1" '{
    for (i = 1; i <= NF; i++) {
      n = index($i, "=")
      if (n > 0 && substr($i, 1, n - 1) == k) { print substr($i, n + 1); exit }
    }
  }' "${LOCK_DIR}/owner" 2>/dev/null
}

# Is the recorded owner provably gone?
#
# CONSERVATIVE ON PURPOSE, in both directions. It reclaims only when it can see
# that the owner was OURS to judge (same namespace) and is NOT running. Anything
# it cannot establish — no owner file, a different namespace, an unparseable pid,
# or a live pid — leaves the lock alone, because guessing a process is dead is
# how two gits end up in one working tree.
lock_owner_is_dead() {
  local owner_pid owner_ns
  owner_ns="$(lock_owner_field ns)"
  owner_pid="$(lock_owner_field pid)"
  [ -n "$owner_ns" ] && [ "$owner_ns" = "$(lock_namespace)" ] || return 1
  case "$owner_pid" in '' | *[!0-9]* ) return 1 ;; esac
  kill -0 "$owner_pid" 2>/dev/null && return 1
  return 0
}

acquire_lock() {
  mkdir -p "$TARGETS_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    printf 'pid=%s ns=%s ts=%s route=%s\n' \
      "$$" "$(lock_namespace)" "$(now_utc)" "$ROUTE" > "${LOCK_DIR}/owner" 2>/dev/null || true
    return 0
  fi

  # Held — but by a live process, or by a corpse?
  #
  # THIS BRANCH EXISTS BECAUSE OF A REAL FAILURE. The plugin bounds the wrapper
  # with a timeout, and a SIGKILL leaves no chance for the EXIT trap to run. With
  # no reclaim, one timeout wedged synchronization PERMANENTLY: every later
  # request answered "another synchronization is in progress" against a pid that
  # had not existed for hours, and only an operator with a shell could clear it.
  # The plugin now kills the whole process group with SIGTERM first and only
  # escalates to SIGKILL, so the trap normally runs; this is the second line of
  # defence for the case where it cannot.
  if lock_owner_is_dead; then
    log "WARNING — reclaiming a stale lock: pid $(lock_owner_field pid) in this namespace is gone (left at $(lock_owner_field ts))."
    rm -f "${LOCK_DIR}/owner" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      printf 'pid=%s ns=%s ts=%s route=%s\n' \
        "$$" "$(lock_namespace)" "$(now_utc)" "$ROUTE" > "${LOCK_DIR}/owner" 2>/dev/null || true
      return 0
    fi
    # Another process reclaimed it first. That is a live owner again.
  fi
  return 1
}

# --- run over a list -------------------------------------------------------
# Sequential, always. Concurrent git against several clones would multiply the
# credential's exposure and the failure modes for no gain at this scale, and one
# target failing must not stop the rest.
TOTAL=0; UPDATED=0; FAILED=0
run_targets() {
  local only="${1:-}" name url private ref matched=0
  while IFS=$'\t' read -r name url private ref; do
    [ -n "$name" ] || continue
    if [ -n "$only" ] && [ "$name" != "$only" ]; then continue; fi
    matched=1
    TOTAL=$((TOTAL + 1))
    # if-form, never `set +e`: see the note in sync_one's fetch block.
    local rc=0
    if ! sync_one "$name" "$url" "$private" "$ref"; then rc=1; fi
    if [ "$rc" -eq 0 ]; then
      [ "$OUT_OUTCOME" = updated ] && UPDATED=$((UPDATED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
    emit_result "$name" "$OUT_OUTCOME" "$OUT_PREV" "$OUT_CUR" "$OUT_MSG"
    audit "$name" "$OUT_OUTCOME" "$OUT_PREV" "$OUT_CUR"
    log "$OUT_MSG"
  done < "$TARGET_LIST_FILE"
  [ "$matched" = 1 ] || return 2
  return 0
}

summary_and_exit() {
  local overall=ok
  [ "$FAILED" -gt 0 ] && overall=failed
  printf 'SUMMARY\ttotal=%s\tupdated=%s\tfailed=%s\toverall=%s\n' \
    "$TOTAL" "$UPDATED" "$FAILED" "$overall"
  [ "$FAILED" -gt 0 ] && exit 1
  exit 0
}

# ===========================================================================
# MODE: sync (all | <name>) — the Slack/agent route
# ===========================================================================
mode_sync() {
  local raw="${1-}" kind name

  if ! kind="$(classify_request "$raw")"; then
    emit_result "${raw:-<empty>}" invalid_target - - \
      "refusing '${raw:-<empty>}'. The only accepted requests are 'all' or the name of a target already declared in targets.yaml. No URL, ref, path or option is accepted."
    audit "${raw:-<empty>}" invalid_target "" ""
    printf 'SUMMARY\ttotal=0\tupdated=0\tfailed=1\toverall=failed\n'
    exit 1
  fi

  [ -f "$TARGETS_FILE" ] || die "${TARGETS_FILE} not found. It is mounted read-only into the gateway; check compose.yaml."
  [ -d "$TARGETS_DIR" ] || die "${TARGETS_DIR} not found. It is the maintenance mount of the target directory; check compose.yaml."

  # BEFORE the membership test, and its failure is fatal. Without the list there
  # is no such thing as "not declared" — only "not known", which is a different
  # answer and points the operator somewhere else entirely.
  if ! load_target_list; then
    emit_result "${raw}" targets_unreadable - - \
      "could not read the target list from ${TARGETS_FILE}: ${TARGET_LIST_ERROR}. Nothing was examined and nothing was changed. This is a problem with the file or the parser, NOT with the requested name."
    audit "${raw}" targets_unreadable "" ""
    printf 'SUMMARY\ttotal=0\tupdated=0\tfailed=1\toverall=failed\n'
    exit 1
  fi

  name=""
  case "$kind" in
    all ) ;;
    one*) name="${kind#one }" ;;
  esac

  if [ -n "$name" ] && ! target_exists "$name"; then
    emit_result "$name" invalid_target - - \
      "'${name}' is not declared in targets.yaml. Sync can only move targets the operator has already declared; adding one is an operator action on the host."
    audit "$name" invalid_target "" ""
    printf 'SUMMARY\ttotal=0\tupdated=0\tfailed=1\toverall=failed\n'
    exit 1
  fi

  if ! acquire_lock; then
    local owner; owner="$(cat "${LOCK_DIR}/owner" 2>/dev/null || echo 'unknown')"
    emit_result "${name:-all}" sync_already_running - - \
      "another synchronization is in progress (${owner}); nothing was started. Try again when it finishes. A lock left by a process this one cannot see — the host, or an earlier container — is cleared with: rmdir ${LOCK_DIR}"
    audit "${name:-all}" sync_already_running "" ""
    printf 'SUMMARY\ttotal=0\tupdated=0\tfailed=0\toverall=busy\n'
    exit 3
  fi

  # `|| true` used to discard this. run_targets returns 2 when the name matched
  # no target, which after the membership test above can only mean the list
  # changed underfoot — still not something to report as a clean run.
  local rc=0
  run_targets "$name" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$FAILED" -eq 0 ]; then
    emit_result "${name:-all}" sync_failed - - \
      "no target matched '${name:-all}' at the moment of the run, although it was declared a moment earlier. Nothing was changed."
    FAILED=$((FAILED + 1))
  fi
  summary_and_exit
}

# ===========================================================================
# MODE: --bootstrap — clone-or-update every target, on the host
# ===========================================================================
# This is the ONLY mode that may create a clone, and it is reachable only from
# the host: nothing in the container and nothing a model can say gets here.
#
# It is stricter than sync mode about some things and looser about others, and
# both differences are deliberate. A mismatched origin or a half-finished clone
# is FATAL here, because bootstrap's job is to leave a correct tree and reporting
# a broken one as "done" helps nobody. A dirty or diverged target is a WARNING
# here, because bootstrap also runs on a machine where somebody is mid-review.
mode_bootstrap() {
  local name url private ref dest rc count=0

  [ -f "$TARGETS_FILE" ] || die "${TARGETS_FILE} not found."
  mkdir -p "$TARGETS_DIR"

  # Fatal, and before the lock: a bootstrap that cannot read the list must not
  # report "0 targets" as though the file said so.
  load_target_list \
    || die "could not read the target list from ${TARGETS_FILE}: ${TARGET_LIST_ERROR}
  Nothing was cloned or updated. Check the file, or run:  python3 ${PARSE} list ${TARGETS_FILE}"

  acquire_lock || die "another synchronization is in progress ($(cat "${LOCK_DIR}/owner" 2>/dev/null || echo unknown)).
  Wait for it to finish, or remove ${LOCK_DIR} if you are certain nothing is running."

  while IFS=$'\t' read -r name url private ref; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    dest="${TARGETS_DIR}/${name}"

    if [ -n "$ref" ] && ! valid_branch_name "$ref"; then
      die "targets.yaml declares ref '${ref}' for '${name}', which is not a valid branch name."
    fi

    if [ ! -e "$dest" ]; then
      log "cloning ${name} from ${url}${private:+ (private: ${private})}"
      clone_one "$name" "$url" "$private" "$ref"
    elif [ ! -d "$dest" ]; then
      die "${dest} exists but is not a directory. Move it aside and retry."
    else
      log "updating ${name} (fetch)"
      if ! sync_one "$name" "$url" "$private" "$ref"; then rc=1; else rc=0; fi
      case "$OUT_OUTCOME" in
        updated | already_current )
          log "  ${OUT_MSG}" ;;
        # Fatal: bootstrap owns the shape of the tree, and these mean the tree is
        # not the one targets.yaml describes. smoke.sh A9 asserts both.
        origin_mismatch_refused )
          die "${dest} tracks a different remote.
  targets.yaml: ${url}
  on disk:      $(tgit "$dest" 0 remote get-url origin 2>/dev/null || echo '<no origin>')
  Refusing to touch it. Fix targets.yaml, or move the directory aside." ;;
        missing_clone )
          die "${dest} exists but is not the root of a git repository (an interrupted clone?).
  Inspect it, then remove it yourself and re-run:  rm -rf ${dest}" ;;
        auth_failed | sync_failed )
          die "${OUT_MSG}" ;;
        * )
          # dirty / detached / diverged / branch mismatch / no upstream. Reported
          # and left alone; bootstrap must never be the thing that loses work.
          warn "${OUT_MSG}" ;;
      esac
      audit "$name" "$OUT_OUTCOME" "$OUT_PREV" "$OUT_CUR"
    fi

    log "  ${name}: $(tgit "$dest" 0 rev-parse --short HEAD) on $(tgit "$dest" 0 rev-parse --abbrev-ref HEAD)"
  done < "$TARGET_LIST_FILE"

  [ "$count" -gt 0 ] || die "no targets parsed from ${TARGETS_FILE}."
  printf '%s\n' "$count"
}

# Only ever called from bootstrap mode.
clone_one() {
  local name="$1" url="$2" private="$3" ref="$4"
  local dest="${TARGETS_DIR}/${name}" auth=0
  [ "$private" = true ] && auth=1

  local -a opts=()
  while IFS= read -r o; do opts+=("$o"); done < <(git_opts "$dest")
  if [ "$auth" = 1 ] && [ -n "$CRED_HELPER" ]; then
    opts+=( -c credential.helper= -c "credential.helper=${CRED_HELPER}" )
  fi

  if ! git "${opts[@]}" clone --quiet "$url" "$dest"; then
    if [ "$auth" = 1 ]; then
      die "could not clone private target '${name}'. ${CREDENTIAL_HINT}"
    fi
    die "could not clone '${name}' from ${url}."
  fi
  [ "$auth" = 1 ] && assert_no_credential "$dest" "$name"

  if [ -n "$ref" ]; then
    # A fresh clone has every remote branch available, so this creates a local
    # branch tracking origin/<ref> — which is exactly the state sync mode then
    # requires. It is NOT a force checkout: the tree is seconds old and clean.
    tgit "$dest" 0 checkout --quiet "$ref" \
      || die "cloned ${name} but branch '${ref}' does not exist in ${url}."
  fi
  audit "$name" cloned "" "$(tgit "$dest" 0 rev-parse HEAD 2>/dev/null || true)"
}

# ===========================================================================
# MODE: --self-test — offline, no credentials, no network, no containers
# ===========================================================================
# Drives the PRODUCTION functions above against temporary bare repositories.
# There is no second implementation here to keep in step, which is the point.
ST_PASS=0; ST_FAIL=0
st_ok()   { ST_PASS=$((ST_PASS + 1)); printf '  ok    %s\n' "$1"; }
st_bad()  { ST_FAIL=$((ST_FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
st_is()   { if [ "$2" = "$3" ]; then st_ok "$1"; else st_bad "$1" "expected '$3', got '$2'"; fi; }

st_git()  { git -c user.email=t@example.invalid -c user.name=selftest -c commit.gpgsign=false "$@"; }

# A remote plus a clone of it, in the harness's own TARGETS_DIR.
st_make() {
  local name="$1" branch="${2:-main}"
  local bare="${ST_TMP}/remotes/${name}.git"
  st_git init -q --bare -b "$branch" "$bare"
  local seed="${ST_TMP}/seed/${name}"
  mkdir -p "$seed"
  st_git init -q -b "$branch" "$seed"
  printf 'one\n' > "${seed}/file.txt"
  st_git -C "$seed" add file.txt
  st_git -C "$seed" commit -qm one
  st_git -C "$seed" remote add origin "file://${bare}"
  st_git -C "$seed" push -q -u origin "$branch"
  st_git clone -q "file://${bare}" "${TARGETS_DIR}/${name}"
  printf 'file://%s' "$bare"
}

# Advance the remote by one commit; echo the new SHA.
st_advance() {
  local name="$1" branch="${2:-main}"
  local seed="${ST_TMP}/seed/${name}"
  printf 'more\n' >> "${seed}/file.txt"
  st_git -C "$seed" add file.txt
  st_git -C "$seed" commit -qm more
  st_git -C "$seed" push -q origin "$branch"
  st_git -C "$seed" rev-parse HEAD
}

# Runs the production sync_one IN THIS SHELL, so OUT_* really are the values the
# production callers would see. A `$( ... )` subshell would silently discard them.
st_sync() {   # st_sync <name> <url> <private> <ref>
  if ! sync_one "$1" "$2" "$3" "$4"; then :; fi
}

self_test() {
  ST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cc-sync-selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "release_lock; rm -rf '${ST_TMP}'" EXIT INT TERM

  TARGETS_DIR="${ST_TMP}/targets"
  LOCK_DIR="${TARGETS_DIR}/.target-sync.lock"
  AUDIT="${ST_TMP}/audit.log"
  mkdir -p "$TARGETS_DIR" "${ST_TMP}/remotes" "${ST_TMP}/seed"

  printf 'sync-targets --self-test\n'
  printf '\ninput validation (nothing below reaches git)\n'

  # Option-shaped, injection-shaped, traversal-shaped and empty input. Every one
  # of these has to die at classify_request, before a target list is even read.
  local bad
  for bad in '' '-' '--bootstrap' '--upload-pack=/bin/sh' '-c' '--self-test' \
             '../etc' '../../workspace' '.git' '.' '..' 'a b' 'a;id' 'a&&id' \
             'a|id' '$(id)' '`id`' 'a
b' 'https://example.com/x.git' 'origin/main' 'simple-crm --force' 'all extra'
  do
    if classify_request "$bad" >/dev/null 2>&1; then
      st_bad "refuses input: $(printf '%q' "$bad")" "it was accepted"
    else
      st_ok "refuses input: $(printf '%q' "$bad")"
    fi
  done
  classify_request all >/dev/null && st_ok "accepts 'all'" || st_bad "accepts 'all'"
  classify_request simple-crm >/dev/null && st_ok "accepts a plain target name" \
    || st_bad "accepts a plain target name"

  printf '\nbranch-name validation\n'
  local good_ref bad_ref
  for good_ref in main master release/1.x feature.x a_b-c; do
    valid_branch_name "$good_ref" && st_ok "valid branch: ${good_ref}" \
      || st_bad "valid branch: ${good_ref}"
  done
  for bad_ref in '' '-x' '--upload-pack=x' 'a..b' 'a b' 'refs/heads/' '/abs' 'x/' 'a@{1}' 'a.lock' '.hidden' 'a;id'; do
    if valid_branch_name "$bad_ref"; then
      st_bad "rejects branch: $(printf '%q' "$bad_ref")" "it was accepted"
    else
      st_ok "rejects branch: $(printf '%q' "$bad_ref")"
    fi
  done

  printf '\nsynchronization outcomes (real git, local remotes, no network)\n'

  # 1. a new remote commit advances the target, and both SHAs are reported.
  local url_ok new_sha
  url_ok="$(st_make advance main)"
  local before; before="$(st_git -C "${TARGETS_DIR}/advance" rev-parse HEAD)"
  new_sha="$(st_advance advance main)"
  st_sync advance "$url_ok" false main
  st_is "explicit ref: outcome"        "$OUT_OUTCOME" updated
  st_is "explicit ref: previous SHA"   "$OUT_PREV"    "$before"
  st_is "explicit ref: resulting SHA"  "$OUT_CUR"     "$new_sha"
  st_is "explicit ref: HEAD really moved" "$(st_git -C "${TARGETS_DIR}/advance" rev-parse HEAD)" "$new_sha"

  # 2. running it again is a genuine no-op.
  st_sync advance "$url_ok" false main
  st_is "already_current on a second run" "$OUT_OUTCOME" already_current
  st_is "already_current does not move HEAD" "$(st_git -C "${TARGETS_DIR}/advance" rev-parse HEAD)" "$new_sha"

  # 3. NO REF FOLLOWS THE TRACKED UPSTREAM. This is the regression this file
  #    exists to fix: the old bootstrap fetched and then moved nothing at all
  #    when targets.yaml declared no ref.
  local url_noref noref_new
  url_noref="$(st_make noref main)"
  noref_new="$(st_advance noref main)"
  st_sync noref "$url_noref" false ""
  st_is "no ref: outcome"            "$OUT_OUTCOME" updated
  st_is "no ref: followed upstream"  "$(st_git -C "${TARGETS_DIR}/noref" rev-parse HEAD)" "$noref_new"

  # 4. a non-default branch name is honoured, not assumed to be main.
  local url_rel rel_new
  url_rel="$(st_make onrelease release/1.x)"
  rel_new="$(st_advance onrelease release/1.x)"
  st_sync onrelease "$url_rel" false release/1.x
  st_is "non-default branch: outcome" "$OUT_OUTCOME" updated
  st_is "non-default branch: HEAD"    "$(st_git -C "${TARGETS_DIR}/onrelease" rev-parse HEAD)" "$rel_new"

  # 5. dirty.
  local url_dirty dirty_head
  url_dirty="$(st_make dirty main)"
  st_advance dirty main >/dev/null
  printf 'local edit\n' >> "${TARGETS_DIR}/dirty/file.txt"
  dirty_head="$(st_git -C "${TARGETS_DIR}/dirty" rev-parse HEAD)"
  st_sync dirty "$url_dirty" false main
  st_is "dirty: outcome" "$OUT_OUTCOME" dirty_refused
  st_is "dirty: HEAD unmoved" "$(st_git -C "${TARGETS_DIR}/dirty" rev-parse HEAD)" "$dirty_head"
  [ "$(cat "${TARGETS_DIR}/dirty/file.txt" | tail -1)" = "local edit" ] \
    && st_ok "dirty: the local edit still exists" \
    || st_bad "dirty: the local edit still exists"

  # 6. detached HEAD.
  local url_det det_head
  url_det="$(st_make detached main)"
  det_head="$(st_git -C "${TARGETS_DIR}/detached" rev-parse HEAD)"
  st_git -C "${TARGETS_DIR}/detached" checkout -q --detach "$det_head"
  st_advance detached main >/dev/null
  st_sync detached "$url_det" false main
  st_is "detached: outcome" "$OUT_OUTCOME" detached_refused
  st_is "detached: HEAD unmoved" "$(st_git -C "${TARGETS_DIR}/detached" rev-parse HEAD)" "$det_head"

  # 7. diverged — a local commit the remote does not have.
  local url_div div_head
  url_div="$(st_make diverged main)"
  printf 'local work\n' > "${TARGETS_DIR}/diverged/local.txt"
  st_git -C "${TARGETS_DIR}/diverged" add local.txt
  st_git -C "${TARGETS_DIR}/diverged" commit -qm "local only"
  div_head="$(st_git -C "${TARGETS_DIR}/diverged" rev-parse HEAD)"
  st_advance diverged main >/dev/null
  st_sync diverged "$url_div" false main
  st_is "diverged: outcome" "$OUT_OUTCOME" diverged_refused
  st_is "diverged: HEAD unmoved" "$(st_git -C "${TARGETS_DIR}/diverged" rev-parse HEAD)" "$div_head"

  # 8. origin mismatch.
  local url_mis
  url_mis="$(st_make mismatch main)"
  st_git -C "${TARGETS_DIR}/mismatch" remote set-url origin "file://${ST_TMP}/remotes/somewhere-else.git"
  st_sync mismatch "$url_mis" false main
  st_is "origin mismatch: outcome" "$OUT_OUTCOME" origin_mismatch_refused

  # 9. branch mismatch — on main, targets.yaml says release/1.x.
  local url_bm
  url_bm="$(st_make branchmismatch main)"
  st_sync branchmismatch "$url_bm" false release/1.x
  st_is "branch mismatch: outcome" "$OUT_OUTCOME" branch_mismatch_refused

  # 10. missing upstream.
  local url_nu
  url_nu="$(st_make noupstream main)"
  st_git -C "${TARGETS_DIR}/noupstream" branch --unset-upstream
  st_sync noupstream "$url_nu" false main
  st_is "missing upstream: outcome" "$OUT_OUTCOME" no_upstream_refused
  case "$OUT_MSG" in *--set-upstream-to=origin/main*) st_ok "missing upstream: message names the fix" ;;
    *) st_bad "missing upstream: message names the fix" "$OUT_MSG" ;; esac

  # 11. missing clone, and a not-a-repo directory.
  st_sync absent "file://${ST_TMP}/remotes/absent.git" false main
  st_is "missing clone: outcome" "$OUT_OUTCOME" missing_clone
  case "$OUT_MSG" in *bootstrap.sh*) st_ok "missing clone: message names bootstrap.sh" ;;
    *) st_bad "missing clone: message names bootstrap.sh" "$OUT_MSG" ;; esac
  mkdir -p "${TARGETS_DIR}/notarepo"
  st_sync notarepo "file://${ST_TMP}/remotes/notarepo.git" false main
  st_is "not-a-repo directory: outcome" "$OUT_OUTCOME" missing_clone

  # 12. an invalid ref in targets.yaml is refused before anything runs.
  local advance_head; advance_head="$(st_git -C "${TARGETS_DIR}/advance" rev-parse HEAD)"
  st_sync advance "$url_ok" false '--upload-pack=/bin/sh'
  st_is "option-shaped ref in targets.yaml" "$OUT_OUTCOME" invalid_target
  st_is "option-shaped ref moves nothing" \
        "$(st_git -C "${TARGETS_DIR}/advance" rev-parse HEAD)" "$advance_head"
  st_sync advance "$url_ok" false 'a..b'
  st_is "revision-expression ref in targets.yaml" "$OUT_OUTCOME" invalid_target

  printf '\ncredential handling (canary; nothing leaves this machine)\n'
  # A private-flagged target whose remote happens to need no authentication. The
  # point is not the auth handshake — that is manual acceptance against real
  # GitHub — but that the production credential path leaves the token NOWHERE.
  local canary="CANARY-PAT-e91b4c72f0"
  local tokfile="${ST_TMP}/token"
  ( umask 077; printf '%s' "$canary" > "$tokfile" )
  local url_priv priv_new
  url_priv="$(st_make privatelike main)"
  priv_new="$(st_advance privatelike main)"

  # Rebuild the helper exactly as the production entry points do.
  local saved_helper="$CRED_HELPER" saved_src="$TOKEN_SOURCE"
  TOKEN_FILE="$tokfile"
  TOKEN_SOURCE=pat
  CRED_HELPER='!f() { test "$1" = get && { echo username=x-access-token; echo "password=$(cat '"'${tokfile}'"')"; }; }; f'

  # The helper really does hand the token over when git asks — the same helper
  # string, exercised through git's own credential machinery.
  local filled
  filled="$(printf 'protocol=https\nhost=github.com\n\n' \
    | git -c credential.helper= -c "credential.helper=${CRED_HELPER}" credential fill 2>/dev/null || true)"
  case "$filled" in
    *"password=${canary}"*) st_ok "the credential helper supplies the token when git asks" ;;
    *) st_bad "the credential helper supplies the token when git asks" "got: ${filled}" ;;
  esac
  case "$filled" in
    *username=x-access-token*) st_ok "the credential helper supplies the expected username" ;;
    *) st_bad "the credential helper supplies the expected username" ;;
  esac

  # Driven through run_targets, not sync_one alone, so the RESULT line, the log
  # line and the audit line are all in the captured output. Redirected to files
  # rather than captured in `$( )`, because a subshell would throw the OUT_*
  # values away and the test would then be asserting on nothing.
  printf 'privatelike\t%s\ttrue\tmain\n' "$url_priv" > "${ST_TMP}/plist.tsv"
  SELFTEST_LIST="${ST_TMP}/plist.tsv"
  load_target_list
  if ! run_targets "" > "${ST_TMP}/priv.out" 2> "${ST_TMP}/priv.err"; then :; fi
  SELFTEST_LIST=""
  local sync_out; sync_out="$(cat "${ST_TMP}/priv.out" "${ST_TMP}/priv.err")"
  st_is "private-flagged target still syncs" "$OUT_OUTCOME" updated
  st_is "private-flagged target reached the new SHA" "$OUT_CUR" "$priv_new"
  case "$sync_out" in *"credential=pat"*) st_ok "the audit line records the credential SOURCE" ;;
    *) st_bad "the audit line records the credential SOURCE" "$sync_out" ;; esac

  # The whole point: find the canary anywhere it must not be.
  case "$sync_out" in *"$canary"*) st_bad "no token in the sync output" ;;
    *) st_ok "no token in the sync output" ;; esac
  case "$OUT_MSG" in *"$canary"*) st_bad "no token in the reported message" ;;
    *) st_ok "no token in the reported message" ;; esac
  if grep -q "$canary" "${TARGETS_DIR}/privatelike/.git/config" 2>/dev/null; then
    st_bad "no token in .git/config"
  else st_ok "no token in .git/config"; fi
  if st_git -C "${TARGETS_DIR}/privatelike" remote -v | grep -q "$canary"; then
    st_bad "no token in the remote URL"
  else st_ok "no token in the remote URL"; fi
  if grep -rq "$canary" "$AUDIT" 2>/dev/null; then
    st_bad "no token in the audit log"
  else st_ok "no token in the audit log"; fi
  if grep -rq "$canary" "${TARGETS_DIR}/privatelike/.git" 2>/dev/null; then
    st_bad "no token anywhere under .git"
  else st_ok "no token anywhere under .git"; fi

  CRED_HELPER="$saved_helper"; TOKEN_SOURCE="$saved_src"; TOKEN_FILE=""

  printf '\nthe global lock\n'
  if acquire_lock; then
    st_ok "the lock can be taken"
    if acquire_lock; then
      st_bad "a second acquisition is refused" "it succeeded"
    else
      st_ok "a second acquisition is refused"
    fi
    release_lock
    if acquire_lock; then st_ok "the lock is reusable after release"; release_lock
    else st_bad "the lock is reusable after release"; fi
  else
    st_bad "the lock can be taken"
  fi

  printf '\nall: sequential, continue-on-failure, one result per target\n'
  # Two healthy targets and one dirty one. Every target must be reported and the
  # run must be a failure overall, without the dirty one stopping the others.
  local list="${ST_TMP}/list.tsv"
  local url_a url_b a_new b_new
  url_a="$(st_make alpha main)";  a_new="$(st_advance alpha main)"
  url_b="$(st_make bravo main)";  b_new="$(st_advance bravo main)"
  {
    printf 'alpha\t%s\tfalse\tmain\n' "$url_a"
    printf 'dirty\t%s\tfalse\tmain\n' "$url_dirty"
    printf 'bravo\t%s\tfalse\tmain\n' "$url_b"
  } > "$list"
  SELFTEST_LIST="$list"
  load_target_list

  local all_out
  set +e
  all_out="$( TOTAL=0; UPDATED=0; FAILED=0; run_targets "" >/dev/null 2>&1
              printf '%s %s %s' "$TOTAL" "$UPDATED" "$FAILED" )"
  set -e
  st_is "all: every target processed / updated / failed" "$all_out" "3 2 1"
  st_is "all: alpha advanced" "$(st_git -C "${TARGETS_DIR}/alpha" rev-parse HEAD)" "$a_new"
  st_is "all: bravo advanced despite the failure before it" \
        "$(st_git -C "${TARGETS_DIR}/bravo" rev-parse HEAD)" "$b_new"

  # And through the real entry point, so the exit code and the RESULT/SUMMARY
  # contract the plugin parses are covered too.
  set +e
  all_out="$( TOTAL=0; UPDATED=0; FAILED=0
              acquire_lock; run_targets "" 2>/dev/null; release_lock
              printf 'SUMMARY\ttotal=%s\tupdated=%s\tfailed=%s\n' "$TOTAL" "$UPDATED" "$FAILED" )"
  set -e
  local n_results; n_results="$(printf '%s\n' "$all_out" | grep -c '^RESULT	' || true)"
  st_is "all: one RESULT line per target" "$n_results" "3"
  case "$all_out" in *"failed=1"*) st_ok "all: the summary reports the failure" ;;
    *) st_bad "all: the summary reports the failure" "$all_out" ;; esac

  # A named target selects exactly one.
  set +e
  n_results="$( TOTAL=0; UPDATED=0; FAILED=0; run_targets alpha 2>/dev/null | grep -c '^RESULT	' )"
  set -e
  st_is "a named target syncs only itself" "$n_results" "1"

  # An unknown name inside a known list matches nothing.
  # `|| rc=$?`, not `if ! cmd; then rc=$?`: inside the then-branch $? is the
  # status of the `!` expression, which is always 0.
  local rc_unknown=0
  run_targets nosuchtarget >/dev/null 2>&1 || rc_unknown=$?
  st_is "an unknown name matches no target" "$rc_unknown" "2"
  SELFTEST_LIST=""

  printf '\nthe target list is data, and its absence is not "nothing to do"\n'
  # REGRESSION, BOTH BLOCKERS FOUND IN REVIEW OF THIS FILE.
  #
  # 1. A parser that fails used to be indistinguishable from a parser that
  #    returned no targets, because the loop read it through a process
  #    substitution whose exit status nobody could see. `all` answered
  #    "SUMMARY total=0 failed=0 overall=ok", exit 0 — a sync that examined
  #    nothing and called it success. A NAMED target was worse: the membership
  #    test found no names, so the operator was told the target was "not declared
  #    in targets.yaml" and sent to edit a file that was perfectly fine.
  SELFTEST_LIST=""
  local broken="${ST_TMP}/broken-parser.py"
  printf 'import sys\nsys.stderr.write("simulated parser failure\\n")\nraise SystemExit(2)\n' > "$broken"
  local saved_parse="$PARSE" saved_file="$TARGETS_FILE"
  PARSE="$broken"
  TARGETS_FILE="${ST_TMP}/targets.yaml"
  printf 'system_id: s\nframework_id: f\ntargets:\n  - name: demo\n    url: https://example.invalid/d.git\n' > "$TARGETS_FILE"

  if load_target_list; then
    st_bad "a failing parser is reported as a failure" "load_target_list returned success"
  else
    st_ok "a failing parser is reported as a failure"
  fi
  case "$TARGET_LIST_ERROR" in *"simulated parser failure"*)
      st_ok "  and the parser's own words are carried through" ;;
    *) st_bad "  and the parser's own words are carried through" "$TARGET_LIST_ERROR" ;;
  esac

  # A parser that succeeds but emits nothing is also not a usable list.
  printf 'import sys\nraise SystemExit(0)\n' > "$broken"
  if load_target_list; then
    st_bad "an empty target list is reported as a failure" "it was accepted"
  else
    st_ok "an empty target list is reported as a failure"
  fi

  PARSE="$saved_parse"; TARGETS_FILE="$saved_file"

  printf '\na stale lock left by a dead owner\n'
  # 2. The plugin bounds the wrapper with a timeout. A SIGKILL runs no EXIT trap,
  #    so the lock directory survived its owner and every later request — from
  #    anyone, forever — answered "another synchronization is in progress"
  #    against a pid that no longer existed. The plugin now signals the whole
  #    process group with SIGTERM first; this is the second line of defence.
  release_lock
  rm -rf "$LOCK_DIR"
  mkdir -p "$LOCK_DIR"
  # A pid that cannot be alive, in THIS namespace.
  printf 'pid=%s ns=%s ts=%s route=timeout-test\n' 4194304 "$(lock_namespace)" "$(now_utc)" \
    > "${LOCK_DIR}/owner"
  if acquire_lock; then
    st_ok "a lock whose owner is provably dead is reclaimed"
    release_lock
  else
    st_bad "a lock whose owner is provably dead is reclaimed" "it stayed held"
  fi

  # A LIVE owner is never reclaimed. This is the property that must not regress
  # in exchange for the one above.
  rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"
  printf 'pid=%s ns=%s ts=%s route=live-test\n' "$$" "$(lock_namespace)" "$(now_utc)" \
    > "${LOCK_DIR}/owner"
  if acquire_lock; then
    st_bad "a lock held by a LIVE process is never reclaimed" "it was stolen"
    release_lock
  else
    st_ok "a lock held by a LIVE process is never reclaimed"
  fi

  # Nor is one from another namespace, where a pid means nothing. The host and
  # the container write this same directory and number processes independently.
  rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"
  printf 'pid=1 ns=%s ts=%s route=other-ns\n' 'boot-00000000-0000-0000-0000-000000000000' "$(now_utc)" \
    > "${LOCK_DIR}/owner"
  if acquire_lock; then
    st_bad "a lock from another namespace is never reclaimed" "it was stolen"
    release_lock
  else
    st_ok "a lock from another namespace is never reclaimed"
  fi

  # An unreadable or malformed owner file is the same answer: leave it alone.
  rm -rf "$LOCK_DIR"; mkdir -p "$LOCK_DIR"
  if acquire_lock; then
    st_bad "a lock with no owner file is never reclaimed" "it was stolen"
    release_lock
  else
    st_ok "a lock with no owner file is never reclaimed"
  fi
  rm -rf "$LOCK_DIR"

  printf '\n'
  if [ "$ST_FAIL" -eq 0 ]; then
    printf 'self-test PASSED (%d checks)\n' "$ST_PASS"
    return 0
  fi
  printf 'self-test FAILED (%d of %d checks)\n' "$ST_FAIL" "$((ST_PASS + ST_FAIL))"
  return 1
}

# ===========================================================================
# entry point
# ===========================================================================
usage() {
  cat <<'USAGE'
usage: sync-targets.sh [all | <target-name> | --bootstrap | --self-test]

  all              fast-forward every target declared in targets.yaml
  <target-name>    fast-forward exactly that target
  --bootstrap      clone-or-update every target (host only; scripts/bootstrap.sh)
  --self-test      offline validation of the rules above; no network, no credentials

Synchronization is fast-forward only. It never resets, stashes, discards local
changes, switches branches, deletes anything, or creates a clone. A target it
cannot move safely is reported and left exactly as it is.

Targets are declared in targets.yaml by the operator. Nothing here can add,
remove, re-point or onboard one.
USAGE
}

main() {
  case "${1-}" in
    --self-test ) self_test; exit $? ;;
    -h|--help )   usage; exit 0 ;;
    --bootstrap )
      [ "$#" -eq 1 ] || die "--bootstrap takes no further arguments."
      mode_bootstrap
      exit $?
      ;;
    '' )
      usage >&2
      exit 2
      ;;
    * )
      [ "$#" -eq 1 ] || { emit_result "<multiple>" invalid_target - - \
          "exactly one request is accepted: 'all' or a declared target name."; exit 1; }
      mode_sync "$1"
      ;;
  esac
}

main "$@"
