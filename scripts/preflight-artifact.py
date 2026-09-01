#!/usr/bin/env python3
"""preflight-artifact.py — analyse `pretorin --json preflight show` output.

    ... | preflight-artifact.py sweep                    -> "<kind>\\t<name>" per line
    ... | preflight-artifact.py assert  NAME [NAME ...]  -> report; exit 1 on failure

ONE IMPLEMENTATION, TWO MODES, AND THAT IS THE POINT. The rule for "which
resolvers are foreign" and the rule for "did onboarding produce the right state"
must not drift apart, or the sweep deletes something the assert then demands.

This used to live as a heredoc inside scripts/onboard-targets.sh, written to a
temp file and run as `python3 FILE`. It is a real file now because it has two
callers: onboard-targets.sh (the legacy single-effort path) and
scripts/onboard-lib.sh (the effort-aware path clawctl drives). Two copies of a
program that decides what to unbind is exactly the drift this repo avoids.

HOST-ONLY. Not shipped in the image: the Dockerfile carries sync-targets.sh and
parse-targets.py because the gateway serves /target-sync, but nothing in a
container ever analyses a preflight artifact.

THE SWEEP RULE. A resolver is a candidate only if it HAS params.path and that
path is outside the read-only target mount. Resolvers with no path — every
pretorin_feature resolver the platform profile binds (System Specification,
Policy Management, GRC, Evidence Repository, ...) — are never candidates. A
path-blind sweep would destroy all of them.
"""

import json
import sys

MOUNT = "/workspace/targets/"


def path_of(spec):
    return (spec.get("params") or {}).get("path")


def read_artifact(stream):
    raw = stream.read().strip()
    if not raw:
        sys.stderr.write("preflight-artifact: no output from `pretorin --json preflight show`\n")
        raise SystemExit(2)
    try:
        return json.loads(raw)
    except ValueError as exc:
        # Never treat unparseable output as "no artifact": that turns a broken
        # pipeline into a plausible-looking verdict about the deployment.
        sys.stderr.write(
            "preflight-artifact: preflight output is not JSON (%s): %.200s\n" % (exc, raw))
        raise SystemExit(2)


def foreign_resolvers(kinds):
    out = []
    for kind in kinds:
        for res in kind.get("resolvers") or []:
            spec = res.get("spec") or {}
            path = path_of(spec)
            if path and not path.startswith(MOUNT):
                out.append((kind.get("kind", "?"), spec.get("name", "?"), path))
    return out


def do_sweep(kinds):
    seen = set()
    for kind, name, _path in foreign_resolvers(kinds):
        if (kind, name) not in seen:
            seen.add((kind, name))
            print("%s\t%s" % (kind, name))
    return 0


def do_assert(art, kinds, expected):
    if not kinds:
        print("  FAIL  no preflight artifact for this scope — onboarding has not run")
        return 1

    failures = 0
    warnings = 0
    foreign = foreign_resolvers(kinds)

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

    # 1b. THE SET MUST BE EQUAL, NOT MERELY A SUPERSET.
    #
    # The loop above proves every declared target IS bound. It cannot see a target
    # that is bound but NOT declared — and with several efforts sharing one
    # /workspace/targets mount, that is now a real shape: another effort's target,
    # or one removed from this effort's list, stays bound to this scope forever and
    # keeps feeding evidence into a compliance effort that no longer claims it.
    # The /app gate below only catches paths OUTSIDE the mount, so it cannot.
    declared = set(expected)
    bound = set()
    for path, entries in by_path.items():
        if not path.startswith(MOUNT):
            continue
        if not any(k == "code_repository" for k, _ in entries):
            continue
        bound.add(path[len(MOUNT):].split("/")[0])
    undeclared = sorted(bound - declared)
    if undeclared:
        for extra in undeclared:
            print("  FAIL  %s is bound to this scope but is NOT declared for this effort."
                  " It keeps feeding evidence into a compliance effort that no longer"
                  " claims it. Unbind it, or declare it." % extra)
            failures += 1
    else:
        print("  ok    bound targets are exactly the declared set (%d)" % len(declared))

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
    return 1 if failures else 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    mode = argv[1]
    if mode not in ("sweep", "assert"):
        sys.stderr.write("preflight-artifact: unknown mode '%s' (expected sweep or assert)\n" % mode)
        return 2

    art = read_artifact(sys.stdin)
    kinds = art.get("kinds") or []

    if mode == "sweep":
        return do_sweep(kinds)
    return do_assert(art, kinds, argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
