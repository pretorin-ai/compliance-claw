#!/usr/bin/env bash
#
# onboard-targets.sh — register every target in targets.yaml with Pretorin as a
# host-local source resolver, then verify and provision the scope.
#
#   scripts/onboard-targets.sh                 # full onboarding (needs a key)
#   scripts/onboard-targets.sh --verify-only   # assert only, read-only, no writes
#   scripts/onboard-targets.sh --local-only    # skip the platform steps (CI/no key)
#
# Runs on the host and drives the `cli` compose service, echoing every command it
# issues so the sequence is auditable rather than magic. All state it writes is
# host-local Pretorin state in the pretorin-state volume; nothing is written to
# the Pretorin platform, so a READ-ONLY API key is sufficient and is the
# documented default.
#
# ORDER IS LOAD-BEARING: sweep, THEN bind.
#
#   `pretorin preflight unbind --name X` removes EVERY resolver named X, and
#   resolver names come from the directory basename — so a target's own
#   `<target>/docs` resolver and a stray `/app/docs` resolver are both called
#   "docs". Binding first and sweeping second would delete the legitimate one as
#   collateral. Sweeping first makes that impossible: step 4 re-creates whatever
#   belongs here, and nothing that belongs here exists yet when the blunt
#   instrument runs.
#
# The sweep only ever considers resolvers that HAVE params.path pointing outside
# /workspace/targets. Resolvers with no path — every pretorin_feature resolver
# the platform profile binds (System Specification, Policy Management, GRC,
# Evidence Repository, ...) — are never candidates. A path-blind sweep would
# destroy all of them.
#
#   1. whoami            fail fast if the key cannot authenticate
#   2. context set       active scope (platform read)
#   3. SWEEP             unbind foreign path resolvers, including /app
#   4. BIND              preflight init --workspace, once per target
#   5. verify            probe every resolver, persist results
#   6. provision --apply seed the active recipe set
#   7. ASSERT            per-resolver invariants, and no /app anywhere
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TARGETS_FILE="${TARGETS_FILE:-targets.yaml}"
PARSE="scripts/parse-targets.py"
MOUNT="/workspace/targets"

LOCAL_ONLY=0
VERIFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --local-only)  LOCAL_ONLY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'onboard: ERROR — unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log()  { printf 'onboard: %s\n' "$*"; }
warn() { printf 'onboard: WARNING — %s\n' "$*" >&2; }
die()  { printf 'onboard: ERROR — %s\n' "$*" >&2; exit 1; }

# Every Pretorin invocation goes through the same one-off container as the
# operator's own `docker compose run --rm cli ...`, so what this script does is
# reproducible by hand. -T because there is no TTY in CI and because Pretorin's
# boxed output is noise when the caller is a script.
#
# `< /dev/null` is not decoration. These run inside `while read ... done < <(...)`
# loops, and `docker compose run` attaches the caller's stdin even with -T — so
# without it the first container swallows the rest of the loop's input and every
# later iteration is silently skipped. That is exactly how the sweep first shipped
# unbinding only one of two foreign resolvers.
pcli() {
  printf '  $ docker compose run --rm -T cli pretorin %s\n' "$*" >&2
  docker compose run --rm -T cli pretorin "$@" < /dev/null
}
pcli_quiet() { docker compose run --rm -T cli pretorin "$@" < /dev/null; }

# --- artifact analysis (one implementation, two modes) ----------------------
# Kept as a single embedded program so the "which resolvers are foreign" rule and
# the "did onboarding produce the right state" rule cannot drift apart. Reads the
# artifact JSON on stdin.
#
# The program is written to a temp file and run as `python3 FILE`, NOT piped in as
# `python3 - <<EOF`: with `python3 -` the interpreter reads the PROGRAM from
# stdin, so the artifact JSON piped in would never reach sys.stdin. That mistake
# is silent — every check just sees empty input — so it is worth the temp file.
# `mktemp -t NAME` is BSD-only: GNU coreutils rejects a template without at
# least three X's and exits 1, which left this variable empty and broke every
# check on Linux. An explicit template works on both.
PF_PY="$(mktemp "${TMPDIR:-/tmp}/onboard-pf.XXXXXX")"
trap 'rm -f "$PF_PY"' EXIT
cat > "$PF_PY" <<'PYEOF'
import json, sys

MOUNT = "/workspace/targets/"
mode = sys.argv[1]
expected = sys.argv[2:]

raw = sys.stdin.read().strip()
if not raw:
    sys.stderr.write("onboard: no output from `pretorin --json preflight show`\n")
    raise SystemExit(2)
try:
    art = json.loads(raw)
except ValueError as exc:
    # Never treat unparseable output as "no artifact": that turns a broken
    # pipeline into a plausible-looking verdict about the deployment.
    sys.stderr.write("onboard: preflight output is not JSON (%s): %.200s\n" % (exc, raw))
    raise SystemExit(2)
kinds = art.get("kinds") or []

# A resolver is a sweep candidate only if it HAS params.path and that path is
# outside the read-only target mount. Resolvers without a path (pretorin_feature
# and friends) are never touched.
def path_of(spec):
    return (spec.get("params") or {}).get("path")

foreign = []
for kind in kinds:
    for res in kind.get("resolvers") or []:
        spec = res.get("spec") or {}
        path = path_of(spec)
        if path and not path.startswith(MOUNT):
            foreign.append((kind.get("kind", "?"), spec.get("name", "?"), path))

if mode == "sweep":
    seen = set()
    for kind, name, _path in foreign:
        if (kind, name) not in seen:
            seen.add((kind, name))
            print("%s\t%s" % (kind, name))
    raise SystemExit(0)

if mode == "assert":
    if not kinds:
        print("  FAIL  no preflight artifact for this scope — onboarding has not run")
        raise SystemExit(1)

    failures = 0
    warnings = 0

    # 1. one workspace_path resolver per declared target, right path, connected.
    by_path = {}
    for kind in kinds:
        for res in kind.get("resolvers") or []:
            spec = res.get("spec") or {}
            path = path_of(spec)
            if path:
                by_path.setdefault(path, []).append((kind.get("kind"), res))

    for name in expected:
        want = MOUNT + name
        entries = by_path.get(want, [])
        repo = [(k, r) for k, r in entries if k == "code_repository"]
        if not repo:
            print("  FAIL  %s: no code_repository resolver bound to %s" % (name, want))
            failures += 1
            continue
        if len(repo) > 1:
            print("  FAIL  %s: %d code_repository resolvers share %s" % (name, len(repo), want))
            failures += 1
        _kind, res = repo[0]
        spec = res.get("spec") or {}
        status = ((res.get("last_result") or {}).get("status")) or "not probed"
        if status != "connected":
            print("  FAIL  %s: resolver status is '%s', expected 'connected'" % (name, status))
            failures += 1
        else:
            print("  ok    %s: %s connected (%s)" % (name, want, spec.get("name")))
        if "commit_history" not in (spec.get("capabilities") or []):
            print("  WARN  %s: resolver has no commit_history capability — not a git clone?"
                  " Evidence cannot carry a commit SHA." % name)
            warnings += 1

    # 2. the /app gate: no resolver anywhere may point outside the mount.
    if foreign:
        for kind, rname, path in foreign:
            print("  FAIL  %s resolver '%s' points outside %s: %s" % (kind, rname, MOUNT, path))
            failures += 1
    else:
        print("  ok    no resolver points outside %s (no /app resolver)" % MOUNT)

    # 3. basename-derived names collide across targets; last write wins silently.
    names = {}
    for kind in kinds:
        for res in kind.get("resolvers") or []:
            spec = res.get("spec") or {}
            if path_of(spec):
                names.setdefault((kind.get("kind"), spec.get("name")), []).append(path_of(spec))
    for (kind, rname), paths in sorted(names.items()):
        if len(paths) > 1:
            print("  WARN  %s has %d resolvers named '%s' (%s) — names come from the"
                  " directory basename, so one silently replaces the other."
                  % (kind, len(paths), rname, ", ".join(paths)))
            warnings += 1

    # 4. kind rollups. `degraded` on code_repository is the EXPECTED local state.
    for kind in kinds:
        if kind.get("kind") != "code_repository":
            continue
        status = kind.get("status")
        missing = kind.get("missing_capabilities") or []
        if status == "degraded":
            print("  ok    code_repository kind status: degraded — EXPECTED for a local"
                  " workspace. Missing %s needs a Connected Source (platform-side), not a"
                  " path on this host. Not a failure." % (", ".join(missing) or "capabilities"))
        else:
            print("  ok    code_repository kind status: %s" % status)

    recipes = art.get("active_recipes") or []
    print("  ok    active recipe set: %d recipe(s)" % len(recipes))
    if not recipes:
        print("  WARN  active recipe set is empty — provisioning did not seed anything")
        warnings += 1

    print("")
    print("  %d failure(s), %d warning(s)" % (failures, warnings))
    raise SystemExit(1 if failures else 0)

raise SystemExit("unknown mode %s" % mode)
PYEOF

pf_py() { python3 "$PF_PY" "$@"; }

# --- scope + targets -------------------------------------------------------

[ -f "$TARGETS_FILE" ] || die "${TARGETS_FILE} not found."
IFS=$'\t' read -r SYSTEM_ID FRAMEWORK_ID < <(python3 "$PARSE" scope "$TARGETS_FILE")
TARGET_NAMES=()
while IFS=$'\t' read -r NAME _URL _REF; do
  [ -n "$NAME" ] && TARGET_NAMES+=("$NAME")
done < <(python3 "$PARSE" list "$TARGETS_FILE")
[ "${#TARGET_NAMES[@]}" -gt 0 ] || die "no targets in ${TARGETS_FILE}."

SCOPE=(--system "$SYSTEM_ID" --framework "$FRAMEWORK_ID")
log "scope: system=${SYSTEM_ID} framework=${FRAMEWORK_ID}"
log "targets: ${TARGET_NAMES[*]}"

# The clones have to exist before anything is bound, or verify probes a path that
# is not there and every resolver comes back unreachable.
for name in "${TARGET_NAMES[@]}"; do
  [ -d "workspace/targets/${name}/.git" ] \
    || die "workspace/targets/${name} is not a git clone. Run scripts/bootstrap.sh first."
done

# --- 7 (standalone). --verify-only ----------------------------------------

assert_state() {
  log "asserting preflight state"
  if ! pcli_quiet --json preflight show "${SCOPE[@]}" | pf_py assert "${TARGET_NAMES[@]}"; then
    die "preflight state does not match ${TARGETS_FILE}."
  fi
  log "preflight state matches ${TARGETS_FILE}"
}

if [ "$VERIFY_ONLY" = 1 ]; then
  assert_state
  exit 0
fi

# --- 1. whoami -------------------------------------------------------------

if [ "$LOCAL_ONLY" = 1 ]; then
  log "--local-only: skipping the platform steps (no active context, no platform"
  log "  source profile). Resolver binding, verification and provisioning are all"
  log "  host-local and need no key."
else
  AUTHED="$(pcli_quiet --json whoami | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authenticated"))' 2>/dev/null || echo False)"
  [ "$AUTHED" = "True" ] || die "Pretorin says not authenticated.
  Put a valid PRETORIN_API_KEY in .env (a read-only key is sufficient), or run
  with --local-only to bind resolvers without touching the platform."
  log "authenticated"

  # --- 2. active context -------------------------------------------------
  # Every command below passes --system/--framework explicitly, so this step is
  # not what makes onboarding work: it is what makes the AGENT work. check_context
  # and start_task read the active scope from local config, so without this the
  # agent has no idea which system it is reviewing for.
  pcli context set --system "$SYSTEM_ID" --framework "$FRAMEWORK_ID" --no-verify
  ACTIVE="$(pcli_quiet --json context show | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s" % (d.get("active_system_id"), d.get("active_framework_id"), d.get("valid")))')"
  [ "$ACTIVE" = "${SYSTEM_ID}|${FRAMEWORK_ID}|True" ] \
    || die "active context is '${ACTIVE}', expected '${SYSTEM_ID}|${FRAMEWORK_ID}|True'."
  log "active context set and valid"
fi

# --- 3. sweep --------------------------------------------------------------

log "sweeping resolvers whose params.path is outside ${MOUNT}"
SWEPT=0
while IFS=$'\t' read -r KIND RNAME; do
  [ -n "${KIND:-}" ] || continue
  log "  unbinding ${KIND} resolver '${RNAME}' (foreign path)"
  # Exits 1 when the name is already gone, which is success for our purposes.
  pcli preflight unbind "$KIND" --name "$RNAME" "${SCOPE[@]}" >/dev/null 2>&1 || true
  SWEPT=$((SWEPT + 1))
done < <(pcli_quiet --json preflight show "${SCOPE[@]}" 2>/dev/null | pf_py sweep)
log "  swept ${SWEPT} foreign resolver name(s)"

# --- 4. bind ---------------------------------------------------------------

for name in "${TARGET_NAMES[@]}"; do
  log "binding ${name}"
  # --workspace is what makes this deterministic: without it Pretorin binds the
  # process's CURRENT DIRECTORY as the repository. Never --replace: it wipes the
  # collections of every kind it detects, so target N would erase targets 1..N-1.
  # Upsert-by-name means re-running this is a no-op rather than a duplicate.
  pcli preflight init --workspace "${MOUNT}/${name}" "${SCOPE[@]}" --no-verify
done

# --- 5. verify -------------------------------------------------------------

log "verifying resolvers (probes run locally, not on the platform)"
pcli preflight verify "${SCOPE[@]}"

# --- 6. provision ----------------------------------------------------------

log "provisioning the active recipe set"
# --apply seeds the active set from what is runnable here, replacing it. Trim
# afterwards with `pretorin recipe deactivate <id>`. Unmapped source kinds are
# reported as gaps and are expected for a repos-only deployment.
pcli preflight provision --apply "${SCOPE[@]}"

# --- 7. assert -------------------------------------------------------------

assert_state

cat <<EOF

onboard: done.
  scope:    ${SYSTEM_ID} / ${FRAMEWORK_ID}
  targets:  ${TARGET_NAMES[*]}

If the gateway is already running, its live sessions may still hold the previous
view (the preflight artifact carries a 3600s TTL and each session keeps its own
pretorin mcp-serve child, reaped after mcp.sessionIdleTtlMs = 10 min):
  docker compose run --rm cli openclaw mcp reload    # or restart the gateway
EOF
