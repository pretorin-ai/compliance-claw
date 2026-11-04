#!/usr/bin/env python3
"""Guard for the Compliance Claw source-built OpenClaw base (openclaw-base/README.md).

  collect --root DIR --out DIR
      Run INSIDE an image (python3 -I, --network none, read-only): write the
      dist and node_modules manifests, the pnpm store list, the app and global
      npm facts, the dpkg list and facts.json.
  compare --receipt DIR --observed DIR --forbidden FILE [--diffids FILE]
          [--versions-env FILE] [--expect-version V] [--expect-commit C]
      On the host: compare an observed collection with a committed receipt.
  policy --upstream FILE --patched FILE [--allow-exclude joi@18.3.1]
      A workspace change may touch only the top-level `overrides:` block.
      With --allow-exclude (AGE_EXCLUDE_EXCEPTION), which must be the literal
      joi@18.3.1, it must also append that entry and its expiry comment to
      `minimumReleaseAgeExclude:`.
  lock-changes --upstream FILE --patched FILE
      List the package keys that a lock change removes (-) and adds (+).
  oci --archive FILE [--platform linux/amd64]
      Read a buildx OCI archive: the top digest, the platform manifest and
      config digests, the RootFS diffIDs and the attestation manifests.
  diffids --image-json FILE [--platform linux/amd64]
      Print the RootFS diffIDs from `docker buildx imagetools inspect --format
      '{{json .Image}}'` output (one image, or a map by platform).
  publish-inputs --run-id N --attempt N --artifact-id N --archive-sha256 H --top-digest D
      The format of the five publish dispatch inputs.
  publish-run --json FILE --run-id N --attempt N --repository R --repository-id N
      The build run attempt (REST "Get a workflow run attempt"): completed,
      successful, this workflow, workflow_dispatch, master, this repository and
      not a fork. Prints its head_sha.
  publish-artifact --json FILE --artifact-id N --run-id N --head-sha S --name NAME
                   --repository-id N
      The artifact (REST "Get an artifact") of that run: name, head_sha, not
      expired. Prints its API digest.
  artifact-extract --zip FILE --digest sha256:H --out DIR
      Unpack the downloaded artifact only if its bytes hash to the API digest.
  publish-binding --dir DIR --oci-json FILE --trusted-guard FILE --run-url U
                  --commit S --run-id N --attempt N --artifact-name NAME
                  --archive-sha256 H --top-digest D
      The unpacked artifact against the inputs: archive hash, OCI top digest
      (read now and in the receipt), receipt run, attempt, commit and name, and
      the guard copy against the guard at the build commit.
  registry-tag --rc N --stderr FILE
      Classify a `skopeo inspect --raw` result: present (rc 0), absent (only a
      definite MANIFEST_UNKNOWN or NAME_UNKNOWN) or error. Prints the word;
      exit 0 for present or absent, 1 for error.
  --self-test
      Fixture tests for all of the above. Standard library only.

Exit codes: 0 ok, 1 check failed, 2 usage or unreadable input.
"""

import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

GLOBAL_NPM = "usr/local/lib/node_modules/npm"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def manifest(top, base, exclude=None):
    """Sorted lines: '<sha256>  <rel>' per file, 'link <rel> -> <target>' per symlink.

    Names are relative to `base`. Symlinks are recorded and never followed.
    `exclude` is a relative directory that is skipped.
    """
    lines = []
    for dirpath, dirnames, filenames in os.walk(top, followlinks=False):
        rel_dir = os.path.relpath(dirpath, base)
        if exclude and (rel_dir == exclude or rel_dir.startswith(exclude + "/")):
            dirnames[:] = []
            continue
        for name in list(dirnames):
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                dirnames.remove(name)
                lines.append("link %s -> %s" % (os.path.relpath(p, base), os.readlink(p)))
        for name in filenames:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, base)
            if os.path.islink(p):
                lines.append("link %s -> %s" % (rel, os.readlink(p)))
            elif os.path.isfile(p):
                lines.append("%s  %s" % (sha256_file(p), rel))
    lines.sort(key=lambda s: (s.split("  ", 1)[1] if not s.startswith("link ") else s[5:]).encode())
    return "".join(line + "\n" for line in lines)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def package_version(pkg_dir):
    try:
        return read_json(os.path.join(pkg_dir, "package.json")).get("version")
    except (OSError, ValueError):
        return None


def bundled(pkg_dir):
    """name@version for each direct entry of pkg_dir/node_modules (scoped too)."""
    out = []
    nm = os.path.join(pkg_dir, "node_modules")
    if not os.path.isdir(nm):
        return out
    for name in sorted(os.listdir(nm)):
        if name.startswith("."):
            continue
        p = os.path.join(nm, name)
        names = ([name + "/" + s for s in sorted(os.listdir(p))]
                 if name.startswith("@") and os.path.isdir(p) else [name])
        for full in names:
            out.append("%s@%s" % (full, package_version(os.path.join(nm, full))))
    return out


def dpkg_list(root):
    path = os.path.join(root, "var/lib/dpkg/status")
    if not os.path.isfile(path):
        return []
    rows, cur = [], {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f.read().split("\n") + [""]:
            if not line.strip():
                if cur.get("Status", "").endswith(" installed"):
                    rows.append("%s %s %s" % (cur.get("Package"), cur.get("Version"),
                                              cur.get("Architecture")))
                cur = {}
            elif not line.startswith(" ") and ":" in line:
                k, v = line.split(":", 1)
                cur[k] = v.strip()
    return sorted(rows)


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def collect(root, out):
    root = os.path.realpath(root)
    app = os.path.join(root, "app")
    os.makedirs(out, exist_ok=True)
    facts = {}

    dist = manifest(os.path.join(app, "dist"), app)
    write_text(os.path.join(out, "dist.sha256"), dist)
    facts["dist_manifest_sha256"] = sha256_bytes(dist.encode())
    facts["dist_entries"] = dist.count("\n")

    # The app's own npm package. The Claw Dockerfile corrects it in its own
    # layer, so the node_modules manifest leaves it out; facts record it apart.
    npm_link = os.path.join(app, "node_modules", "npm")
    app_npm = os.path.realpath(npm_link) if os.path.exists(npm_link) else None
    app_npm_rel = os.path.relpath(app_npm, app) if app_npm else None
    nm = manifest(os.path.join(app, "node_modules"), app, exclude=app_npm_rel)
    write_text(os.path.join(out, "node-modules.sha256"), nm)
    facts["node_modules_manifest_sha256"] = sha256_bytes(nm.encode())
    facts["node_modules_entries"] = nm.count("\n")

    store = os.path.join(app, "node_modules", ".pnpm")
    entries = sorted(e for e in os.listdir(store) if not e.startswith(".")) if os.path.isdir(store) else []
    store_text = "".join(e + "\n" for e in entries)
    write_text(os.path.join(out, "pnpm-store.txt"), store_text)
    facts["pnpm_store_sha256"] = sha256_bytes(store_text.encode())

    facts["app_npm"] = None if not app_npm else {
        "path": app_npm_rel,
        "version": package_version(app_npm),
        "bundled": bundled(app_npm),
        "manifest_sha256": sha256_bytes(manifest(app_npm, app).encode()),
    }
    gnpm = os.path.join(root, GLOBAL_NPM)
    facts["global_npm"] = None if not os.path.isdir(gnpm) else {
        "path": "/" + GLOBAL_NPM,
        "version": package_version(gnpm),
        "bundled": bundled(gnpm),
        "manifest_sha256": sha256_bytes(manifest(gnpm, root).encode()),
    }

    try:
        facts["package_version"] = read_json(os.path.join(app, "package.json")).get("version")
    except (OSError, ValueError):
        facts["package_version"] = None
    try:
        info = read_json(os.path.join(app, "dist", "build-info.json"))
        facts["build_info"] = {k: info.get(k) for k in ("version", "commit")}
    except (OSError, ValueError):
        facts["build_info"] = None

    dpkg = "".join(r + "\n" for r in dpkg_list(root))
    write_text(os.path.join(out, "dpkg.txt"), dpkg)
    facts["dpkg_sha256"] = sha256_bytes(dpkg.encode())

    write_text(os.path.join(out, "facts.json"), json.dumps(facts, indent=2, sort_keys=True) + "\n")
    return facts


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip() and not line.startswith("#")]


def read_env(path):
    env = {}
    for line in read_lines(path):
        if "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    return env


def forbidden_hits(entries, forbidden):
    # pnpm store names are name@version, plus an optional _peer suffix.
    return sorted(e for e in entries for f in forbidden if e == f or e.startswith(f + "_"))


def compare(receipt, observed, forbidden, diffids=None, versions_env=None,
            expect_version=None, expect_commit=None):
    errors = []
    rf = read_json(os.path.join(receipt, "facts.json"))
    of = read_json(os.path.join(observed, "facts.json"))

    for key in ("dist_manifest_sha256", "dist_entries", "node_modules_manifest_sha256",
                "node_modules_entries", "pnpm_store_sha256", "package_version", "build_info"):
        if rf.get(key) != of.get(key):
            errors.append("%s: receipt %r, observed %r" % (key, rf.get(key), of.get(key)))
    r_npm, o_npm = rf.get("app_npm") or {}, of.get("app_npm") or {}
    if r_npm.get("path") != o_npm.get("path"):
        errors.append("app npm path: receipt %r, observed %r" % (r_npm.get("path"), o_npm.get("path")))

    hits = forbidden_hits(read_lines(os.path.join(observed, "pnpm-store.txt")), read_lines(forbidden))
    if hits:
        errors.append("forbidden store entries present: %s" % ", ".join(hits))

    info = of.get("build_info") or {}
    if expect_version and of.get("package_version") != expect_version:
        errors.append("package.json version %r, expected %r" % (of.get("package_version"), expect_version))
    if expect_version and info.get("version") != expect_version:
        errors.append("build-info version %r, expected %r" % (info.get("version"), expect_version))
    # build-info may hold the full or a short commit; at least 7 characters.
    commit = info.get("commit") or ""
    if expect_commit and not (len(commit) >= 7 and (expect_commit.startswith(commit)
                                                    or commit.startswith(expect_commit))):
        errors.append("build-info commit %r, expected %r" % (info.get("commit"), expect_commit))

    if versions_env:
        # The Claw npm step: the app npm package and its two bundled copies.
        env = read_env(versions_env)
        want = {"npm": env.get("NPM_VERSION"),
                "undici": env.get("NPM_UNDICI_VERSION"),
                "ip-address": env.get("NPM_IP_ADDRESS_VERSION")}
        have = {"npm": o_npm.get("version")}
        for item in o_npm.get("bundled") or []:
            name, _, version = item.rpartition("@")
            if name in want:
                have[name] = version
        for name, version in want.items():
            if not version or have.get(name) != version:
                errors.append("app npm %s is %r, versions.env says %r" % (name, have.get(name), version))

    if diffids:
        # RootFS diffIDs only (uncompressed layer digests); never an image,
        # index or manifest digest. Every list is a linux/amd64 receipt.
        observed_ids = read_lines(diffids)
        base_ids = read_lines(os.path.join(receipt, "rootfs-diffids.txt"))
        official = read_lines(os.path.join(receipt, "official-diffids.txt"))
        node_slim = read_lines(os.path.join(receipt, "node-slim-diffids.txt"))
        if not base_ids or not node_slim or not official:
            errors.append("a diffID receipt list is empty")
        if observed_ids[:len(base_ids)] != base_ids:
            errors.append("the image does not start with the base receipt's %d layers" % len(base_ids))
        if base_ids[:len(node_slim)] != node_slim:
            errors.append("the base receipt does not start with the Node bookworm-slim layers")
        official_only = set(official) - set(node_slim)
        leaked = [d for d in observed_ids if d in official_only]
        if leaked:
            errors.append("official OpenClaw layers present: %s" % ", ".join(leaked))
    return errors


def block_span(lines, key="overrides"):
    start = next((i for i, l in enumerate(lines) if l.rstrip("\n") == key + ":"), None)
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and (lines[end].startswith((" ", "\t")) or not lines[end].strip()):
        end += 1
    return start + 1, end


# The one user-approved age exception (openclaw-base/README.md). This literal
# is the whole permission: inputs.env cannot widen it. Another value needs a
# reviewed change here.
APPROVED_EXCLUDE = "joi@18.3.1"
EXCLUDE_EXPIRY = re.compile(r"; remove after \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\.$")


def exclude_insert_ok(a, b, ea, tag, i1, i2, j1, j2, allow):
    """True only for the comment and the allowed entry, appended to the upstream list."""
    end = ea[1]
    while end > ea[0] and not a[end - 1].strip():
        end -= 1
    name, version = allow.rsplit("@", 1)
    comment = b[j1].rstrip("\n") if j2 - j1 == 2 else ""
    return (tag == "insert" and i1 == i2 == end and j2 - j1 == 2
            and comment.startswith("  # Compliance Claw: %s %s " % (name, version))
            and EXCLUDE_EXPIRY.search(comment) is not None
            and b[j1 + 1] == '  - "%s"\n' % allow)


def policy(upstream, patched, allow_exclude=""):
    """A workspace change may touch only `overrides:`. With allow_exclude (only
    APPROVED_EXCLUDE), it may also append exactly one comment and that entry at
    the end of `minimumReleaseAgeExclude:`. Nothing else in the age policy may
    change."""
    if allow_exclude and allow_exclude != APPROVED_EXCLUDE:
        return ["--allow-exclude must be %s, not %r" % (APPROVED_EXCLUDE, allow_exclude)]
    with open(upstream, encoding="utf-8") as f:
        a = f.readlines()
    with open(patched, encoding="utf-8") as f:
        b = f.readlines()
    sa, sb = block_span(a), block_span(b)
    if not sa or not sb:
        return ["no top-level overrides: block"]
    ea = block_span(a, "minimumReleaseAgeExclude")
    if allow_exclude and not ea:
        return ["no top-level minimumReleaseAgeExclude: block"]
    errors, allowed = [], 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        if sa[0] <= i1 and i2 <= sa[1] and sb[0] <= j1 and j2 <= sb[1]:
            continue
        if allow_exclude and exclude_insert_ok(a, b, ea, tag, i1, i2, j1, j2, allow_exclude):
            allowed += 1
            continue
        errors.append("change outside overrides: upstream lines %d-%d, patched lines %d-%d"
                      % (i1 + 1, i2, j1 + 1, j2))
    if allow_exclude and allowed != 1:
        errors.append("%s is not appended exactly once, with its expiry comment, at the end of "
                      "minimumReleaseAgeExclude" % allow_exclude)
    return errors


PKG_KEY = re.compile(r"^  ('?)([^\s'][^']*?)\1:\s*$")


def lock_packages(path):
    keys, section = set(), None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line and not line[0].isspace() and line.rstrip().endswith(":"):
                section = line.rstrip()[:-1]
                continue
            m = PKG_KEY.match(line.rstrip("\n"))
            if section == "packages" and m:
                keys.add(m.group(2))
    return keys


def lock_changes(upstream, patched):
    a, b = lock_packages(upstream), lock_packages(patched)
    return sorted(a - b), sorted(b - a)


# Manual publication (README.md "Publication"): a later `operation=publish`
# dispatch names one successful build run attempt and its artifact, and
# pushes exactly those bytes. Nothing here trusts the artifact about itself.
WORKFLOW_PATH = ".github/workflows/openclaw-base.yml"
RUN_NUMBER = re.compile(r"^[1-9][0-9]{0,19}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
SHA256_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_SHA = re.compile(r"^[0-9a-f]{40}$")
RECEIPT_KEYS = ("builder_run", "builder_commit", "run_id", "run_attempt", "artifact_name", "archive_sha256")


def artifact_name(tag, attempt):
    return "openclaw-base-%s-attempt-%s" % (tag, attempt)


def publish_inputs(run_id, attempt, artifact_id, archive_sha256, top_digest):
    errors = []
    for name, value, rule in (("build_run_id", run_id, RUN_NUMBER), ("build_run_attempt", attempt, RUN_NUMBER),
                              ("artifact_id", artifact_id, RUN_NUMBER), ("archive_sha256", archive_sha256, SHA256_HEX),
                              ("top_digest", top_digest, SHA256_DIGEST)):
        if not isinstance(value, str) or not rule.match(value):
            errors.append("input %s is not valid: %r" % (name, value))
    return errors


def _want(errors, what, got, expected):
    # `is` for booleans: 0 must not pass as False.
    same = got is expected if isinstance(expected, bool) else (type(got) is type(expected) and got == expected)
    if not same:
        errors.append("%s is %r, expected %r" % (what, got, expected))


def _numbers(**values):
    bad = sorted(k for k, v in values.items() if not RUN_NUMBER.match(str(v)))
    return ["not a positive number: %s" % ", ".join(bad)] if bad else []


def publish_run(doc, run_id, attempt, repository, repository_id):
    """The REST "Get a workflow run attempt" response of the build: a completed,
    successful workflow_dispatch of this workflow on master in this repository."""
    bad = _numbers(run_id=run_id, attempt=attempt, repository_id=repository_id)
    if bad:
        return bad
    if not isinstance(doc, dict):
        return ["run response is not an object"]
    errors = []
    _want(errors, "run id", doc.get("id"), int(run_id))
    _want(errors, "run run_attempt", doc.get("run_attempt"), int(attempt))
    _want(errors, "run path", doc.get("path"), WORKFLOW_PATH)
    _want(errors, "run event", doc.get("event"), "workflow_dispatch")
    _want(errors, "run head_branch", doc.get("head_branch"), "master")
    _want(errors, "run status", doc.get("status"), "completed")
    _want(errors, "run conclusion", doc.get("conclusion"), "success")
    if not COMMIT_SHA.match(str(doc.get("head_sha"))):
        errors.append("run head_sha is not a commit: %r" % doc.get("head_sha"))
    for key in ("repository", "head_repository"):
        repo = doc.get(key)
        if not isinstance(repo, dict):
            errors.append("run %s is not a repository object" % key)
            continue
        _want(errors, "run %s.full_name" % key, repo.get("full_name"), repository)
        _want(errors, "run %s.id" % key, repo.get("id"), int(repository_id))
        _want(errors, "run %s.fork" % key, repo.get("fork"), False)
    return errors


def publish_artifact(doc, artifact_id, run_id, head_sha, name, repository_id):
    """The REST "Get an artifact" response: that run's unexpired artifact with
    the expected name, and an authenticated sha256 digest."""
    bad = _numbers(artifact_id=artifact_id, run_id=run_id, repository_id=repository_id)
    if not COMMIT_SHA.match(str(head_sha)):
        bad.append("head_sha is not a commit: %r" % head_sha)
    if bad:
        return bad
    if not isinstance(doc, dict):
        return ["artifact response is not an object"]
    errors = []
    _want(errors, "artifact id", doc.get("id"), int(artifact_id))
    _want(errors, "artifact name", doc.get("name"), name)
    _want(errors, "artifact expired", doc.get("expired"), False)
    if not SHA256_DIGEST.match(str(doc.get("digest"))):
        errors.append("artifact has no sha256 digest: %r" % doc.get("digest"))
    run = doc.get("workflow_run")
    if not isinstance(run, dict):
        return errors + ["artifact workflow_run is not an object"]
    _want(errors, "artifact workflow_run.id", run.get("id"), int(run_id))
    _want(errors, "artifact workflow_run.head_sha", run.get("head_sha"), head_sha)
    _want(errors, "artifact workflow_run.head_branch", run.get("head_branch"), "master")
    _want(errors, "artifact workflow_run.repository_id", run.get("repository_id"), int(repository_id))
    _want(errors, "artifact workflow_run.head_repository_id", run.get("head_repository_id"), int(repository_id))
    return errors


def extract_artifact(zip_path, digest, out):
    """Unpack the downloaded artifact only after its bytes hash to the API digest.
    Regular files only: no absolute path, no `..`, no link."""
    import stat
    import zipfile
    if not SHA256_DIGEST.match(str(digest)):
        return ["artifact digest is not sha256: %r" % digest]
    have = "sha256:" + sha256_file(zip_path)
    if have != digest:
        return ["downloaded artifact is %s; the API digest is %s" % (have, digest)]
    if os.path.exists(out):
        return ["%s exists" % out]
    with zipfile.ZipFile(zip_path) as z:
        infos = z.infolist()
        for i in infos:
            parts = i.filename.replace("\\", "/").split("/")
            kind = stat.S_IFMT(i.external_attr >> 16)   # 0 when the zip records no type
            if (i.filename.startswith(("/", "\\")) or ".." in parts or ":" in parts[0]
                    or kind not in (0, stat.S_IFREG, stat.S_IFDIR)):
                return ["artifact entry %r is not a plain relative file" % i.filename]
        os.makedirs(out)
        for i in infos:
            target = os.path.join(out, *[p for p in i.filename.split("/") if p])
            if i.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(i) as src, open(target, "xb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
    return []


def receipt_fields(path):
    """receipt.env lines hold one or more key=value words. A key with two values is ambiguous."""
    fields = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            for word in line.split():
                if "=" in word:
                    k, v = word.split("=", 1)
                    fields.setdefault(k, set()).add(v)
    return fields


def publish_binding(base, fresh_top_digest, trusted_guard, expect):
    """The extracted artifact against the inputs, the run and the trusted guard.

    expect: run_url, commit, run_id, attempt, artifact_name, archive_sha256, top_digest.
    """
    errors = []
    archive = os.path.join(base, "base.oci.tar")
    have = sha256_file(archive) if os.path.isfile(archive) else None
    _want(errors, "base.oci.tar sha256", have, expect["archive_sha256"])
    _want(errors, "OCI top digest read now", fresh_top_digest, expect["top_digest"])
    try:
        recorded = read_json(os.path.join(base, "receipt", "oci.json")).get("top_digest")
    except (OSError, ValueError):
        recorded = None
    _want(errors, "receipt oci.json top_digest", recorded, expect["top_digest"])
    try:
        fields = receipt_fields(os.path.join(base, "receipt", "receipt.env"))
    except OSError:
        fields = {}
    wanted = {"builder_run": expect["run_url"], "builder_commit": expect["commit"],
              "run_id": expect["run_id"], "run_attempt": expect["attempt"],
              "artifact_name": expect["artifact_name"], "archive_sha256": expect["archive_sha256"]}
    for key in RECEIPT_KEYS:
        values = fields.get(key, set())
        got = next(iter(values)) if len(values) == 1 else sorted(values) or None
        _want(errors, "receipt %s" % key, got, wanted[key])
    copy = os.path.join(base, "tools", "openclaw-base-guard.py")
    try:
        with open(copy, "rb") as f1, open(trusted_guard, "rb") as f2:
            same = f1.read() == f2.read()
    except OSError:
        same = False
    if not same:
        errors.append("the artifact's guard copy is not the guard at the build commit")
    return errors


# OCI distribution error codes for "this tag (or repository) does not exist".
ABSENT_MARKERS = ("manifest unknown", "name unknown")


def registry_tag_state(rc, stderr):
    if rc == 0:
        return "present"
    text = stderr.lower()
    return "absent" if any(m in text for m in ABSENT_MARKERS) else "error"


def image_json_diffids(path, platform="linux/amd64"):
    doc = read_json(path)
    if platform in doc and isinstance(doc[platform], dict):
        doc = doc[platform]
    os_, arch = platform.split("/")
    if (doc.get("os"), doc.get("architecture")) != (os_, arch):
        raise ValueError("image JSON is %s/%s, expected %s" % (doc.get("os"), doc.get("architecture"), platform))
    ids = (doc.get("rootfs") or {}).get("diff_ids") or []
    if not ids:
        raise ValueError("image JSON has no rootfs.diff_ids")
    return ids


INDEX_TYPES = ("application/vnd.oci.image.index.v1+json",
               "application/vnd.docker.distribution.manifest.list.v2+json")


PROVENANCE_PREDICATES = ("https://slsa.dev/provenance/v0.2", "https://slsa.dev/provenance/v1")
SBOM_PREDICATE = "https://spdx.dev/Document"
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _blob_member(tar, desc, what):
    digest = desc.get("digest") or ""
    algo, _, hexd = digest.partition(":")
    if algo != "sha256" or not HEX64.match(hexd):
        raise ValueError("%s descriptor has no sha256 digest" % what)
    if not isinstance(desc.get("size"), int):
        raise ValueError("%s descriptor has no size" % what)
    try:
        return tar.getmember("blobs/sha256/" + hexd), hexd
    except KeyError:
        raise ValueError("%s blob %s is missing" % (what, digest))


def verified_blob(tar, desc, what):
    """The bytes of a descriptor's blob, only after its size and sha256 match."""
    member, hexd = _blob_member(tar, desc, what)
    data = tar.extractfile(member).read()
    if len(data) != desc["size"]:
        raise ValueError("%s size is %d, its descriptor says %d" % (what, len(data), desc["size"]))
    if sha256_bytes(data) != hexd:
        raise ValueError("%s bytes do not match %s" % (what, desc["digest"]))
    return data


def oci_facts(archive, platform="linux/amd64", require_attestations=False):
    """Digests of a `docker buildx build --output type=oci` archive.

    The top digest is what a registry push of this archive names. The image
    may be a single manifest, or an index with exactly one image for
    `platform` plus BuildKit attestation manifests (the release contract).
    Every manifest and config is used only after its size and sha256 match
    the descriptor that references it. Layers are checked by oci_image_archive.
    """
    import tarfile
    want_os, want_arch = platform.split("/")
    with tarfile.open(archive) as tar:
        layout = json.loads(tar.extractfile("index.json").read())
        if len(layout.get("manifests", [])) != 1:
            raise ValueError("the OCI archive must name exactly one image")
        top = layout["manifests"][0]
        doc = json.loads(verified_blob(tar, top, "top manifest"))
        images, attestations, other = [], [], []
        if top.get("mediaType") in INDEX_TYPES or doc.get("manifests") is not None:
            for d in doc["manifests"]:
                ann = d.get("annotations") or {}
                plat = d.get("platform") or {}
                if ann.get("vnd.docker.reference.type") == "attestation-manifest":
                    attestations.append(d)
                elif plat.get("os") == want_os and plat.get("architecture") == want_arch:
                    images.append(d)
                else:
                    other.append(d)
            if len(images) != 1 or other:
                raise ValueError("the index must hold one %s image plus attestations only" % platform)
            image_desc = images[0]
            image_manifest = json.loads(verified_blob(tar, image_desc, "image manifest"))
        else:
            image_desc, image_manifest = top, doc
        config_desc = image_manifest["config"]
        config = json.loads(verified_blob(tar, config_desc, "image config"))
        if (config.get("os"), config.get("architecture")) != (want_os, want_arch):
            raise ValueError("config platform is %s/%s" % (config.get("os"), config.get("architecture")))

        predicates = []
        for d in attestations:
            # Only attestations for this image count.
            if (d.get("annotations") or {}).get("vnd.docker.reference.digest") != image_desc["digest"]:
                continue
            att = json.loads(verified_blob(tar, d, "attestation manifest"))
            for layer in att.get("layers") or []:
                p = (layer.get("annotations") or {}).get("in-toto.io/predicate-type")
                if p:
                    predicates.append(p)
        if require_attestations:
            if not any(p in PROVENANCE_PREDICATES for p in predicates):
                raise ValueError("no SLSA provenance attestation for the image")
            if SBOM_PREDICATE not in predicates:
                raise ValueError("no SPDX SBOM attestation for the image")
    return {
        "top_digest": top["digest"],
        "top_media_type": top.get("mediaType"),
        "manifest_digest": image_desc["digest"],
        "manifest_size": image_desc["size"],
        "manifest_media_type": image_desc.get("mediaType"),
        "config_digest": config_desc["digest"],
        "config_size": config_desc["size"],
        "diff_ids": config["rootfs"]["diff_ids"],
        "layers": image_manifest.get("layers") or [],
        "attestation_manifests": [d["digest"] for d in attestations],
        "attestation_predicates": sorted(set(predicates)),
        "labels": (config.get("config") or {}).get("Labels") or {},
    }


GZIP_LAYERS = ("application/vnd.oci.image.layer.v1.tar+gzip",
               "application/vnd.docker.image.rootfs.diff.tar.gzip")
TAR_LAYERS = ("application/vnd.oci.image.layer.v1.tar",)
IMAGE_NAME = re.compile(r"^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


def layer_diff_id(f, media_type):
    """The sha256 of a layer's uncompressed tar: the diffID its config names."""
    import zlib
    h = hashlib.sha256()
    if media_type in TAR_LAYERS:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
        return "sha256:" + h.hexdigest()
    if media_type not in GZIP_LAYERS:
        raise ValueError("layer media type %s is not supported" % media_type)
    d, fed = zlib.decompressobj(31), False
    try:
        for data in iter(lambda: f.read(1 << 20), b""):
            while data:
                fed = True
                # max_length keeps a small compressed chunk from filling memory.
                h.update(d.decompress(data, 1 << 24))
                if d.eof:
                    # Another gzip member follows, as Go's gzip reader accepts.
                    data, d, fed = d.unused_data, zlib.decompressobj(31), False
                else:
                    data = d.unconsumed_tail
    except zlib.error as e:
        raise ValueError("gzip layer cannot be read: %s" % e)
    if fed and not d.eof:
        raise ValueError("gzip layer is truncated")
    return "sha256:" + h.hexdigest()


def load_view_errors(path, facts, layer_diff_ids, name):
    """Why a load view is not the verified image in Docker's archive form.

    Moby's classic loader (image/tarexport/load.go) reads manifest.json:
    Config is the config blob, Layers[i] is the blob for rootfs diff_ids[i],
    and RepoTags are the names it tags. Without manifest.json it falls back
    to the legacy layout and reads blobs/json. `layer_diff_ids` maps each
    layer blob digest to the diffID of its uncompressed bytes.
    """
    import tarfile

    def blob(digest):
        return "blobs/sha256/" + digest.split(":", 1)[1]

    want = ([blob(facts["manifest_digest"]), blob(facts["config_digest"])]
            + [blob(d["digest"]) for d in facts["layers"]])
    errors = []
    with tarfile.open(path) as tar:
        names = []
        for m in tar.getmembers():
            names.append(m.name)
            if m.name.startswith("/") or ".." in m.name.split("/") or not m.isreg():
                errors.append("entry %s is not a plain relative file" % m.name)
        if len(set(names)) != len(names):
            errors.append("an entry name occurs twice")
        expected = set(want) | {"index.json", "oci-layout", "manifest.json"}
        for n in sorted(expected - set(names)):
            errors.append("entry %s is missing" % n)
        for n in sorted(set(names) - expected):
            errors.append("entry %s is not part of the image" % n)
        if errors:
            return errors
        doc = json.loads(tar.extractfile("manifest.json").read())
        index = json.loads(tar.extractfile("index.json").read())
    if not isinstance(doc, list) or len(doc) != 1 or not isinstance(doc[0], dict):
        return ["manifest.json must hold exactly one image"]
    item = doc[0]
    if sorted(item) != ["Config", "Layers", "RepoTags"]:
        errors.append("manifest.json keys are %s" % sorted(item))
    if item.get("Config") != blob(facts["config_digest"]):
        errors.append("manifest.json Config is not the verified config blob")
    if item.get("RepoTags") != [name]:
        errors.append("manifest.json RepoTags is not [%s]" % name)
    layers = item.get("Layers")
    if layers != [blob(d["digest"]) for d in facts["layers"]]:
        errors.append("manifest.json Layers are not the verified layer blobs in manifest order")
    elif [layer_diff_ids.get(d["digest"]) for d in facts["layers"]] != facts["diff_ids"]:
        errors.append("the layer blobs do not agree with the config diff_ids in order")
    if [m.get("digest") for m in index.get("manifests") or []] != [facts["manifest_digest"]]:
        errors.append("index.json does not name the verified image manifest")
    return errors


def oci_image_archive(archive, out, platform="linux/amd64", name="openclaw-base:candidate"):
    """Write a single-image archive for `docker load` from the same bytes.

    It holds the selected platform manifest, its config and its layers, each
    copied once only after its size and sha256 match, and each layer's
    uncompressed sha256 must be its config diffID. manifest.json is the
    Docker archive record that `docker save` writes for the classic image
    store; index.json is the OCI record for the containerd store. The pushed
    archive names the same manifest digest, so the loaded image is the image
    that is published.
    """
    import io
    import tarfile
    if not IMAGE_NAME.match(name):
        raise ValueError("image name %s must be name:tag" % name)
    facts = oci_facts(archive, platform)
    if len(facts["layers"]) != len(facts["diff_ids"]):
        raise ValueError("the manifest has %d layers, the config %d diff_ids"
                         % (len(facts["layers"]), len(facts["diff_ids"])))
    diff_of = {}
    with tarfile.open(archive) as src, tarfile.open(out, "w") as dst:
        def add(n, data):
            ti = tarfile.TarInfo(n)
            ti.size = len(data)
            dst.addfile(ti, io.BytesIO(data))

        for d in ({"digest": facts["manifest_digest"], "size": facts["manifest_size"]},
                  {"digest": facts["config_digest"], "size": facts["config_size"]}):
            add("blobs/sha256/" + d["digest"].split(":", 1)[1], verified_blob(src, d, "image blob"))
        for i, layer in enumerate(facts["layers"]):
            member, hexd = _blob_member(src, layer, "layer %d" % i)
            if layer["digest"] in diff_of:
                # The same blob again (for example an empty layer): one copy.
                continue
            h, n, f = hashlib.sha256(), 0, src.extractfile(member)
            spool = tempfile.TemporaryFile()
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
                n += len(chunk)
                spool.write(chunk)
            if n != layer["size"] or h.hexdigest() != hexd:
                raise ValueError("layer %d does not match its descriptor" % i)
            spool.seek(0)
            diff_of[layer["digest"]] = layer_diff_id(spool, layer.get("mediaType"))
            spool.seek(0)
            ti = tarfile.TarInfo("blobs/sha256/" + hexd)
            ti.size = n
            dst.addfile(ti, spool)
            spool.close()
        tag = name.rpartition(":")[2]
        add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        add("index.json", json.dumps({"schemaVersion": 2, "manifests": [{
            "mediaType": facts["manifest_media_type"] or "application/vnd.oci.image.manifest.v1+json",
            "digest": facts["manifest_digest"], "size": facts["manifest_size"],
            "annotations": {"io.containerd.image.name": "docker.io/library/" + name,
                            "org.opencontainers.image.ref.name": tag}}]}).encode())
        add("manifest.json", (json.dumps([{
            "Config": "blobs/sha256/" + facts["config_digest"].split(":", 1)[1],
            "RepoTags": [name],
            "Layers": ["blobs/sha256/" + d["digest"].split(":", 1)[1] for d in facts["layers"]],
        }], separators=(",", ":")) + "\n").encode())
    errors = load_view_errors(out, facts, diff_of, name)
    if errors:
        os.remove(out)
        raise ValueError("the load view is refused: " + "; ".join(errors))
    return facts


# --------------------------------------------------------------------- self-test

def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_text(path, text)


def _fixture_root(root, dist_text="a", extra_store=None):
    app = os.path.join(root, "app")
    _write(os.path.join(app, "package.json"), '{"version": "2026.10.10"}')
    _write(os.path.join(app, "dist/build-info.json"), '{"version": "2026.10.10", "commit": "7dc3350c"}')
    _write(os.path.join(app, "dist/control-ui/index.js"), dist_text)
    npm = os.path.join(app, "node_modules/.pnpm/npm@12.2.0/node_modules/npm")
    _write(os.path.join(npm, "package.json"), '{"version": "12.2.0"}')
    _write(os.path.join(npm, "node_modules/undici/package.json"), '{"version": "6.29.0"}')
    _write(os.path.join(npm, "node_modules/ip-address/package.json"), '{"version": "10.7.2"}')
    os.symlink(".pnpm/npm@12.2.0/node_modules/npm", os.path.join(app, "node_modules/npm"))
    _write(os.path.join(app, "node_modules/.pnpm/qs@6.16.1/node_modules/qs/package.json"), '{"version": "6.16.1"}')
    if extra_store:
        _write(os.path.join(app, "node_modules/.pnpm", extra_store, "x"), "x")
    _write(os.path.join(root, GLOBAL_NPM, "package.json"), '{"version": "12.2.1"}')
    _write(os.path.join(root, "var/lib/dpkg/status"),
           "Package: tini\nStatus: install ok installed\nVersion: 0.19\nArchitecture: amd64\n\n")


def _claw_npm(root, version="12.2.1", undici="6.29.1", ip="10.7.4"):
    npm = os.path.join(root, "app/node_modules/.pnpm/npm@12.2.0/node_modules/npm")
    _write(os.path.join(npm, "package.json"), '{"version": "%s"}' % version)
    _write(os.path.join(npm, "node_modules/undici/package.json"), '{"version": "%s"}' % undici)
    _write(os.path.join(npm, "node_modules/ip-address/package.json"), '{"version": "%s"}' % ip)


def self_test():
    tmp = tempfile.mkdtemp(prefix="openclaw-base-guard-")
    results = []

    def case(name, ok):
        results.append((name, ok))
        print("%s %s" % ("PASS" if ok else "FAIL", name))

    try:
        forbidden = os.path.join(tmp, "forbidden.txt")
        _write(forbidden, "# test\nqs@6.16.0\njoi@18.2.9\n")
        versions = os.path.join(tmp, "versions.env")
        _write(versions, "NPM_VERSION=12.2.1\nNPM_UNDICI_VERSION=6.29.1\nNPM_IP_ADDRESS_VERSION=10.7.4\n")

        base = os.path.join(tmp, "base")
        _fixture_root(base)
        receipt = os.path.join(tmp, "receipt")
        collect(base, receipt)
        _write(os.path.join(receipt, "node-slim-diffids.txt"), "sha256:n1\nsha256:n2\n")
        _write(os.path.join(receipt, "official-diffids.txt"), "sha256:n1\nsha256:n2\nsha256:o3\n")
        _write(os.path.join(receipt, "rootfs-diffids.txt"), "sha256:n1\nsha256:n2\nsha256:b3\n")
        claw_ids = os.path.join(tmp, "claw-diffids.txt")
        _write(claw_ids, "sha256:n1\nsha256:n2\nsha256:b3\nsha256:c4\n")

        def claw(name, dist_text="a", extra_store=None, **npm):
            root = os.path.join(tmp, name)
            _fixture_root(root, dist_text, extra_store)
            _claw_npm(root, **npm)
            out = os.path.join(tmp, name + "-observed")
            collect(root, out)
            return out

        good = claw("claw-good")
        case("claw image with the npm correction matches the base receipt",
             compare(receipt, good, forbidden, claw_ids, versions, "2026.10.10", "7dc3350c") == [])
        case("base receipt checks itself (forbidden entries, layers, version surfaces)",
             compare(receipt, receipt, forbidden, os.path.join(receipt, "rootfs-diffids.txt"),
                     None, "2026.10.10", "7dc3350c") == [])
        case("changed dist file is refused",
             any("dist_manifest" in e for e in compare(receipt, claw("claw-dist", dist_text="b"), forbidden)))
        case("forbidden store entry is refused",
             any("forbidden" in e for e in compare(receipt, claw("claw-qs", extra_store="qs@6.16.0"), forbidden)))
        case("forbidden entry with a peer suffix is refused",
             any("forbidden" in e for e in compare(receipt, claw("claw-joi", extra_store="joi@18.2.9_x@1"), forbidden)))
        case("wrong app npm version is refused",
             any("app npm npm" in e for e in compare(receipt, claw("claw-npm", version="12.2.0"), forbidden,
                                                      versions_env=versions)))
        case("missing bundled ip-address correction is refused",
             any("ip-address" in e for e in compare(receipt, claw("claw-ip", ip="10.7.2"), forbidden,
                                                     versions_env=versions)))
        bad_ids = os.path.join(tmp, "bad-ids.txt")
        _write(bad_ids, "sha256:n1\nsha256:n2\nsha256:o3\nsha256:c4\n")
        errs = compare(receipt, good, forbidden, bad_ids)
        case("official OpenClaw layer and a wrong base prefix are refused",
             any("official OpenClaw layers" in e for e in errs) and any("does not start" in e for e in errs))
        case("wrong build-info commit is refused",
             any("commit" in e for e in compare(receipt, good, forbidden, expect_commit="deadbeef")))

        up = os.path.join(tmp, "ws-up.yaml")
        _write(up, "packages:\n  - .\n\nminimumReleaseAge: 10080\n\noverrides:\n  qs: 6.16.0\n\ntrust: a\n")
        ok = os.path.join(tmp, "ws-ok.yaml")
        _write(ok, "packages:\n  - .\n\nminimumReleaseAge: 10080\n\noverrides:\n  joi@18.2.9: 18.3.1\n  qs: 6.16.1\n\ntrust: a\n")
        bad = os.path.join(tmp, "ws-bad.yaml")
        _write(bad, "packages:\n  - .\n\nminimumReleaseAge: 0\n\noverrides:\n  qs: 6.16.1\n\ntrust: a\n")
        case("workspace change inside overrides is accepted", policy(up, ok) == [])
        case("workspace change outside overrides (age rule) is refused", policy(up, bad) != [])

        def ws(name, exclude, age="10080", strict="true", trust="trustPolicy: no-downgrade\n"):
            path = os.path.join(tmp, "ws-x-%s.yaml" % name)
            _write(path, "packages:\n  - .\n\nminimumReleaseAge: %s\nminimumReleaseAgeStrict: %s\n\n"
                         "minimumReleaseAgeExclude:\n  - \"solid-js\"\n"
                         "  # Upstream: remove after 2026-10-21T13:01:12.291Z.\n  - \"@o/fs@0.26.5\"\n%s\n"
                         "%s\noverrides:\n  qs: 6.16.1\n\ntrust: a\n" % (age, strict, exclude, trust))
            return path

        def agreeing(selector):
            name, version = selector.rsplit("@", 1)
            return ("  # Compliance Claw: %s %s for GHSA-x; remove after 2026-11-04T09:59:49.641Z.\n"
                    '  - "%s"\n' % (name, version, selector))
        note = "  # Compliance Claw: joi 18.3.1 for GHSA-x; remove after 2026-11-04T09:59:49.641Z.\n"
        entry = '  - "joi@18.3.1"\n'
        xup = ws("up", "")
        xok = ws("ok", note + entry)
        j = "joi@18.3.1"
        case("exact exclude entry with its expiry comment is accepted", policy(xup, xok, j) == [])
        case("exclude entry without --allow-exclude is refused", policy(xup, xok) != [])
        case("allowed exclude entry that is missing is refused", policy(xup, ws("none", ""), j) != [])
        case("second exclude entry is refused",
             policy(xup, ws("two", note + entry + '  - "joi@18.3.2"\n'), j) != []
             and policy(xup, ws("two-c", note + entry + note + '  - "joi@18.3.2"\n'), j) != [])
        case("name-only exclude entry is refused",
             policy(xup, ws("bare", note + '  - "joi"\n'), j) != [] and policy(xup, xok, "joi") != [])
        case("other version of the exclude entry is refused",
             policy(xup, ws("v", note.replace("18.3.1", "18.3.0") + '  - "joi@18.3.0"\n'), j) != [])
        case("exclude disjunction is refused",
             policy(xup, ws("or", note + '  - "joi@18.3.1 || 18.3.2"\n'), "joi@18.3.1 || 18.3.2") != [])
        case("exclude range is refused",
             policy(xup, ws("range", note + '  - "joi@^18.3.1"\n'), "joi@^18.3.1") != [])
        case("exclude scope wildcard is refused",
             policy(xup, ws("scope", note + '  - "@hapi/*"\n'), "@hapi/*") != [])
        def edit(path, old, new):
            with open(path, encoding="utf-8") as f:
                text = f.read()
            assert old in text
            _write(path, text.replace(old, new, 1))
            return path
        case("exclude entry not at the end of the list is refused",
             policy(xup, edit(ws("mid", ""), '  - "solid-js"\n', '  - "solid-js"\n' + note + entry), j) != [])
        case("changed or removed upstream exclude entry is refused",
             policy(xup, edit(ws("mod", note + entry), '"@o/fs@0.26.5"', '"@o/fs@0.26.6"'), j) != []
             and policy(xup, edit(ws("rm", note + entry), '  - "solid-js"\n', ""), j) != [])
        case("age rule change with the exclude entry is refused",
             policy(xup, ws("age", note + entry, age="0"), j) != []
             and policy(xup, ws("strict", note + entry, strict="false"), j) != [])
        case("trust rule change with the exclude entry is refused",
             policy(xup, ws("tp", note + entry, trust="trustPolicy: off\n"), j) != []
             and policy(xup, ws("tl", note + entry, trust="trustPolicy: no-downgrade\ntrustLockfile: true\n"),
                        j) != [])
        for other in ("other-package@1.2.3", "joi@18.3.0", "lodash@4.17.21"):
            case("other exact selector %s, with a matching line and comment, is refused" % other,
                 any("must be joi@18.3.1" in e
                     for e in policy(xup, ws("sel-" + other, agreeing(other)), other)))
        case("exclude entry without an expiry comment is refused",
             policy(xup, ws("nonote", "  # Compliance Claw: joi 18.3.1.\n" + entry), j) != [])

        la = os.path.join(tmp, "lock-a.yaml")
        _write(la, "lockfileVersion: '9.0'\n\npackages:\n\n  joi@18.2.9:\n    resolution: {}\n\n"
                   "  '@a/b@1.0.0':\n    resolution: {}\n\nsnapshots:\n\n  joi@18.2.9: {}\n")
        lb = os.path.join(tmp, "lock-b.yaml")
        _write(lb, "lockfileVersion: '9.0'\n\npackages:\n\n  joi@18.3.1:\n    resolution: {}\n\n"
                   "  '@a/b@1.0.0':\n    resolution: {}\n\nsnapshots:\n\n  joi@18.3.1: {}\n")
        case("lock package changes are listed", lock_changes(la, lb) == (["joi@18.2.9"], ["joi@18.3.1"]))

        # Layer tars as BuildKit writes them: gzip, and an empty layer twice
        # (one blob, two diff_ids), as in the real base image.
        import gzip
        layer_plain = [b"layer-a", b"", b"layer-b", b""]
        layer_gz = [gzip.compress(p, mtime=0) for p in layer_plain]
        diff_ids = ["sha256:" + sha256_bytes(p) for p in layer_plain]

        def oci_archive(name, extra_platform=False, single=False, corrupt_manifest=False,
                        wrong_config_size=False, sbom=True, swap_diff_ids=False,
                        layer_type="application/vnd.oci.image.layer.v1.tar+gzip"):
            import io
            import tarfile
            blobs = {}

            def put(obj, raw=None):
                data = raw if raw is not None else json.dumps(obj).encode()
                d = "sha256:" + sha256_bytes(data)
                blobs[d] = data
                return d, len(data)

            layers = []
            for data in layer_gz:
                d, n = put(None, data)
                layers.append({"mediaType": layer_type, "digest": d, "size": n})
            layer, layer_n = layers[0]["digest"], layers[0]["size"]
            ids = list(diff_ids)
            if swap_diff_ids:
                ids[0], ids[2] = ids[2], ids[0]
            cfg, cfg_n = put({"os": "linux", "architecture": "amd64",
                              "rootfs": {"type": "layers", "diff_ids": ids},
                              "config": {"Labels": {"a": "b"}}})
            img, img_n = put({"schemaVersion": 2,
                              "config": {"digest": cfg, "size": cfg_n + (1 if wrong_config_size else 0)},
                              "layers": layers})
            if corrupt_manifest:
                # Same name, one changed byte: the digest no longer matches.
                data = bytearray(blobs[img])
                data[-2] = ord("x") if data[-2] != ord("x") else ord("y")
                blobs[img] = bytes(data)
            predicates = ["https://slsa.dev/provenance/v0.2"] + (["https://spdx.dev/Document"] if sbom else [])
            att, att_n = put({"schemaVersion": 2, "layers": [
                {"mediaType": "application/vnd.in-toto+json", "digest": layer, "size": layer_n,
                 "annotations": {"in-toto.io/predicate-type": p}} for p in predicates]})
            entries = [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": img, "size": img_n,
                        "platform": {"os": "linux", "architecture": "amd64"}},
                       {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": att, "size": att_n,
                        "platform": {"os": "unknown", "architecture": "unknown"},
                        "annotations": {"vnd.docker.reference.type": "attestation-manifest",
                                        "vnd.docker.reference.digest": img}}]
            if extra_platform:
                entries.append({"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": img,
                                "size": img_n, "platform": {"os": "linux", "architecture": "arm64"}})
            if single:
                top = {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": img, "size": img_n}
            else:
                idx, idx_n = put({"schemaVersion": 2, "manifests": entries})
                top = {"mediaType": "application/vnd.oci.image.index.v1+json", "digest": idx, "size": idx_n}
            path = os.path.join(tmp, name)
            with tarfile.open(path, "w") as tar:
                for n, data in [("index.json", json.dumps({"schemaVersion": 2, "manifests": [top]}).encode())] + \
                        [("blobs/sha256/" + d.split(":", 1)[1], b) for d, b in blobs.items()]:
                    ti = tarfile.TarInfo(n)
                    ti.size = len(data)
                    tar.addfile(ti, io.BytesIO(data))
            return path, top["digest"], img

        path, top, img = oci_archive("index.tar")
        f = oci_facts(path, require_attestations=True)
        case("OCI index with one amd64 image plus provenance and SBOM attestations is read",
             f["top_digest"] == top and f["manifest_digest"] == img and f["diff_ids"] == diff_ids
             and len(f["attestation_manifests"]) == 1 and len(f["attestation_predicates"]) == 2)
        single_out = os.path.join(tmp, "single-out.tar")
        g = oci_image_archive(path, single_out)
        import io
        import tarfile
        with tarfile.open(single_out) as t:
            names = sorted(t.getnames())
            idx = json.loads(t.extractfile("index.json").read())
            view = {n: t.extractfile(n).read() for n in names}
        case("single-image archive holds the same manifest, config and layer",
             g["manifest_digest"] == img and idx["manifests"][0]["digest"] == img
             and len([n for n in names if n.startswith("blobs/")]) == 5 and "oci-layout" in names)

        # Docker 28 classic `docker load` reads manifest.json; without it, it
        # reads the legacy layout and fails on blobs/json (run 41785277435).
        def blob_name(digest):
            return "blobs/sha256/" + digest.split(":", 1)[1]
        name = "openclaw-base:candidate"
        doc = json.loads(view.get("manifest.json", b"[]"))
        item = doc[0] if isinstance(doc, list) and len(doc) == 1 else {"Layers": [None] * 4}
        case("load view has manifest.json: Config is the verified config blob, RepoTags the image name",
             sorted(item) == ["Config", "Layers", "RepoTags"]
             and item["Config"] == blob_name(g["config_digest"])
             and "sha256:" + sha256_bytes(view[item["Config"]]) == g["config_digest"]
             and item["RepoTags"] == [name] and "blobs/json" not in view)
        case("load view Layers are the verified layer blobs in diff_ids order",
             item["Layers"] == [blob_name(d["digest"]) for d in g["layers"]]
             and ["sha256:" + sha256_bytes(gzip.decompress(view[n])) for n in item["Layers"]] == g["diff_ids"])
        case("load view stores a repeated layer blob once and names it twice",
             names.count(item["Layers"][1]) == 1 and item["Layers"][1] == item["Layers"][3])
        diff_of = {d["digest"]: "sha256:" + sha256_bytes(gzip.decompress(view[blob_name(d["digest"])]))
                   for d in g["layers"]}
        case("load view check passes the written view", load_view_errors(single_out, g, diff_of, name) == [])

        def tampered(label, drop=(), extra=(), manifest=None, symlink=None):
            out = os.path.join(tmp, "view-" + label + ".tar")
            with tarfile.open(out, "w") as t:
                files = [(n, b) for n, b in view.items() if n not in drop] + list(extra)
                if manifest is not None:
                    files = [(n, b) for n, b in files if n != "manifest.json"] + \
                            [("manifest.json", json.dumps([manifest]).encode())]
                for n, b in files:
                    ti = tarfile.TarInfo(n)
                    ti.size = len(b)
                    t.addfile(ti, io.BytesIO(b))
                if symlink:
                    ti = tarfile.TarInfo(symlink)
                    ti.type, ti.linkname = tarfile.SYMTYPE, "/etc/passwd"
                    t.addfile(ti)
            return load_view_errors(out, g, diff_of, name)

        cfg_blob = blob_name(g["config_digest"])
        lay = [blob_name(d["digest"]) for d in g["layers"]]
        l0, l2 = lay[0], lay[2]

        def edit(**kw):
            m = {"Config": cfg_blob, "RepoTags": [name], "Layers": lay}
            m.update(kw)
            return m

        for label, errs, word in (
                ("without manifest.json (the failed run's view)", tampered("old", drop=["manifest.json"]),
                 "manifest.json is missing"),
                ("with a missing layer blob", tampered("miss", drop=[l2]), "is missing"),
                ("with a missing config blob", tampered("nocfg", drop=[cfg_blob]), "is missing"),
                ("with an extra blob", tampered("extra", extra=[("blobs/sha256/" + "0" * 64, b"x")]),
                 "not part of the image"),
                ("with a legacy blobs/json entry", tampered("json", extra=[("blobs/json", b"{}")]),
                 "not part of the image"),
                ("with a path escape entry", tampered("dots", extra=[("../escape", b"x")]),
                 "not a plain relative file"),
                ("with an absolute entry", tampered("abs", extra=[("/etc/x", b"x")]), "not a plain relative file"),
                ("with a symlink entry", tampered("link", symlink="blobs/sha256/" + "1" * 64),
                 "not a plain relative file"),
                ("with an entry twice", tampered("twice", extra=[("oci-layout", b"{}")]), "occurs twice"),
                ("whose Config is the manifest blob", tampered("cfg", manifest=edit(Config=blob_name(img))),
                 "Config is not the verified config blob"),
                ("whose Config escapes the archive",
                 tampered("cfgesc", manifest=edit(Config="../" + cfg_blob)), "Config is not"),
                ("with a wrong layer reference",
                 tampered("lref", manifest=edit(Layers=[l2] + lay[1:])), "Layers are not"),
                ("whose layer order does not follow the diff_ids",
                 tampered("lorder", manifest=edit(Layers=[l2, lay[1], l0, lay[3]])),
                 "Layers are not"),
                ("with a layer missing from Layers", tampered("lshort", manifest=edit(Layers=lay[:3])),
                 "Layers are not"),
                ("whose layer path escapes the archive",
                 tampered("lesc", manifest=edit(Layers=["../../" + l0] + lay[1:])), "Layers are not"),
                ("with other RepoTags", tampered("tag", manifest=edit(RepoTags=["openclaw-base:other"])),
                 "RepoTags"),
                ("with an extra manifest.json key", tampered("key", manifest=edit(Parent="sha256:" + "2" * 64)),
                 "keys are"),
        ):
            case("load view %s is refused" % label, any(word in e for e in errs))
        case("load view whose blobs do not give the diff_ids in order is refused",
             any("do not agree with the config diff_ids" in e
                 for e in load_view_errors(single_out, g, dict(diff_of, **{g["layers"][0]["digest"]: diff_ids[2]}),
                                           name)))

        def writer_refusal(archive, out, **kw):
            try:
                oci_image_archive(archive, out, **kw)
                return ""
            except ValueError as e:
                return str(e)
        p, _, _ = oci_archive("swapped.tar", swap_diff_ids=True)
        out = os.path.join(tmp, "swapped-view.tar")
        msg = writer_refusal(p, out)
        case("a source whose layers do not give the config diff_ids in order makes no load view",
             "do not agree with the config diff_ids" in msg and not os.path.exists(out))
        p, _, _ = oci_archive("zstd.tar", layer_type="application/vnd.oci.image.layer.v1.tar+zstd")
        case("a layer media type the guard cannot read is refused",
             "is not supported" in writer_refusal(p, os.path.join(tmp, "zstd-view.tar")))
        case("an image name without a tag is refused",
             "name:tag" in writer_refusal(path, os.path.join(tmp, "notag.tar"), name="openclaw-base"))
        for label, data, word in (("truncated", layer_gz[0][:-6], "truncated"),
                                  ("corrupt", layer_gz[0][:10] + b"\xff" * 8 + layer_gz[0][18:], "cannot be read")):
            try:
                layer_diff_id(io.BytesIO(data), "application/vnd.oci.image.layer.v1.tar+gzip")
                msg = ""
            except ValueError as e:
                msg = str(e)
            case("a %s gzip layer is refused" % label, word in msg)
        case("a gzip layer of two members gives the diffID of both parts",
             layer_diff_id(io.BytesIO(layer_gz[0] + layer_gz[2]), "application/vnd.oci.image.layer.v1.tar+gzip")
             == "sha256:" + sha256_bytes(layer_plain[0] + layer_plain[2]))
        for label, kw, word in (("changed child manifest byte", {"corrupt_manifest": True}, "image manifest"),
                                ("wrong config size", {"wrong_config_size": True}, "image config")):
            p, _, _ = oci_archive(label.replace(" ", "-") + ".tar", **kw)
            try:
                oci_facts(p)
                msg = ""
            except ValueError as e:
                msg = str(e)
            case("OCI %s is refused" % label, word in msg)
        p, _, _ = oci_archive("no-sbom.tar", sbom=False)
        try:
            oci_facts(p, require_attestations=True)
            msg = ""
        except ValueError as e:
            msg = str(e)
        case("OCI image without an SBOM attestation is refused when required", "SBOM" in msg)
        path, top, img = oci_archive("single.tar", single=True)
        f = oci_facts(path)
        case("OCI single image manifest is read", f["top_digest"] == top == f["manifest_digest"] == img)
        path, _, _ = oci_archive("multi.tar", extra_platform=True)
        try:
            oci_facts(path)
            refused = False
        except ValueError:
            refused = True
        case("OCI index with another platform image is refused", refused)

        one = os.path.join(tmp, "one.json")
        _write(one, json.dumps({"os": "linux", "architecture": "amd64", "rootfs": {"diff_ids": ["sha256:a"]}}))
        many = os.path.join(tmp, "many.json")
        _write(many, json.dumps({"linux/arm64": {"os": "linux", "architecture": "arm64",
                                                 "rootfs": {"diff_ids": ["sha256:x"]}},
                                 "linux/amd64": {"os": "linux", "architecture": "amd64",
                                                 "rootfs": {"diff_ids": ["sha256:b"]}}}))
        case("diffIDs are read from one image and from a platform map",
             image_json_diffids(one) == ["sha256:a"] and image_json_diffids(many) == ["sha256:b"])

        # Manual publication. Response shapes follow REST "Get a workflow run
        # attempt" and "Get an artifact" (field names read back from run
        # 41690155854 and its artifacts; repository objects as the REST schema).
        gh_repo, gh_id = "pretorin-ai/compliance-claw", 1322225829
        commit, rid, att, aid = "a" * 40, "41700000001", "2", "13300000001"
        h, top = "c" * 64, "sha256:" + "d" * 64
        repo_obj = {"id": gh_id, "full_name": gh_repo, "fork": False}

        def run_doc(**change):
            doc = {"id": int(rid), "run_attempt": int(att), "path": WORKFLOW_PATH, "event": "workflow_dispatch",
                   "head_branch": "master", "head_sha": commit, "status": "completed", "conclusion": "success",
                   "repository": dict(repo_obj), "head_repository": dict(repo_obj)}
            doc.update(change)
            return doc

        def run_refused(doc, run_id=rid, attempt=att):
            return publish_run(doc, run_id, attempt, gh_repo, str(gh_id)) != []

        case("publish inputs in the right format pass", publish_inputs(rid, att, aid, h, top) == [])
        case("publish inputs in a wrong format are refused",
             all(publish_inputs(*bad) != [] for bad in (
                 ("41700000001x", att, aid, h, top), ("0", att, aid, h, top), (rid, "01", aid, h, top),
                 (rid, att, "", h, top), (rid, att, aid, h.upper(), top), (rid, att, aid, h[:63], top),
                 (rid, att, aid, h, "d" * 64), (rid, att, aid, h, "sha256:" + "d" * 63), (rid, "1;id", aid, h, top))))
        case("successful master dispatch of this workflow is accepted",
             publish_run(run_doc(), rid, att, gh_repo, str(gh_id)) == [])
        historical = run_doc(id=41690155854, run_attempt=1, path=".github/workflows/exp-68-source-build.yml",
                             event="push", head_branch="exp/68-source-build-ci",
                             head_sha="3b9b2498997588ddf4f2375b4daa3540d2502ff6")
        errs = publish_run(historical, "41690155854", "1", gh_repo, str(gh_id))
        case("historical experiment run 41690155854 (push, experiment branch) is refused",
             any("path" in e for e in errs) and any("event" in e for e in errs)
             and any("head_branch" in e for e in errs))
        case("run with another id is refused", run_refused(run_doc(), run_id="41700000002"))
        case("run with another attempt is refused", run_refused(run_doc(), attempt="1"))
        case("run of another workflow path is refused",
             run_refused(run_doc(path=".github/workflows/release.yml")))
        case("run of another event is refused", run_refused(run_doc(event="push")))
        case("run on another branch is refused", run_refused(run_doc(head_branch="codex/x")))
        case("run in another repository is refused",
             run_refused(run_doc(repository={"id": 9, "full_name": "other/compliance-claw", "fork": False})))
        case("run from a fork is refused",
             run_refused(run_doc(head_repository={"id": 9, "full_name": "someone/compliance-claw", "fork": True})))
        case("run that is not completed is refused", run_refused(run_doc(status="in_progress", conclusion=None)))
        case("failed or cancelled run is refused",
             run_refused(run_doc(conclusion="failure")) and run_refused(run_doc(conclusion="cancelled")))
        case("run response with a flat repository string is refused", run_refused(run_doc(repository=gh_repo)))

        name = artifact_name("2026.10.10-src.1", att)
        api_digest = "sha256:" + "e" * 64

        def art_doc(**change):
            doc = {"id": int(aid), "name": name, "digest": api_digest, "expired": False,
                   "expires_at": "2026-12-04T00:00:00Z",
                   "workflow_run": {"id": int(rid), "repository_id": gh_id, "head_repository_id": gh_id,
                                    "head_branch": "master", "head_sha": commit}}
            for k, v in change.items():
                if k.startswith("run_"):
                    doc["workflow_run"][k[4:]] = v
                else:
                    doc[k] = v
            return doc

        def art_refused(doc, art_name=name):
            return publish_artifact(doc, aid, rid, commit, art_name, str(gh_id)) != []

        case("artifact of the named run, unexpired, with a digest is accepted",
             publish_artifact(art_doc(), aid, rid, commit, name, str(gh_id)) == [])
        case("artifact of another run is refused", art_refused(art_doc(run_id=41700000009)))
        case("artifact of another head_sha is refused", art_refused(art_doc(run_head_sha="b" * 40)))
        case("artifact from a fork head repository is refused", art_refused(art_doc(run_head_repository_id=9)))
        case("artifact with another tag in its name is refused",
             art_refused(art_doc(name=artifact_name("2026.10.5-src.1", att))))
        case("artifact of another attempt is refused", art_refused(art_doc(name=artifact_name("2026.10.10-src.1", "1"))))
        case("expired artifact is refused", art_refused(art_doc(expired=True)))
        case("artifact without an API digest is refused",
             art_refused(art_doc(digest=None)) and art_refused(art_doc(digest="sha1:" + "e" * 40)))
        case("historical experiment artifact is refused",
             publish_artifact({"digest": "sha256:" + "f" * 64, "expired": False, "id": 13257712762,
                               "name": "exp68-unmodified",
                               "workflow_run": {"head_branch": "exp/68-source-build-ci", "head_repository_id": gh_id,
                                                "head_sha": "3b9b2498997588ddf4f2375b4daa3540d2502ff6",
                                                "id": 41690155854, "repository_id": gh_id}},
                              "13257712762", "41690155854", "3b9b2498997588ddf4f2375b4daa3540d2502ff6",
                              artifact_name("2026.10.10-src.1", "1"), str(gh_id)) != [])

        import zipfile

        def zipped(zname, entries, link=None):
            path = os.path.join(tmp, zname)
            with zipfile.ZipFile(path, "w") as z:
                for n, data in entries:
                    z.writestr(n, data)
                if link:
                    info = zipfile.ZipInfo(link)
                    info.external_attr = (0o120777 << 16)
                    z.writestr(info, "/etc/passwd")
            return path, "sha256:" + sha256_file(path)

        trusted = os.path.join(tmp, "trusted-guard.py")
        _write(trusted, "guard v1\n")
        run_url = "https://github.com/%s/actions/runs/%s/attempts/%s" % (gh_repo, rid, att)
        archive = b"oci archive bytes"
        good_receipt = ("builder_run=%s\nbuilder_commit=%s\nrun_id=%s run_attempt=%s artifact_name=%s\n"
                        "source=https://x bytes=1 sha256=%s commit=%s\narchive_sha256=%s archive_bytes=%d\n"
                        % (run_url, commit, rid, att, name, "9" * 64, commit, sha256_bytes(archive), len(archive)))

        def artifact_zip(zname, receipt=good_receipt, oci_top=top, guard="guard v1\n", data=archive):
            return zipped(zname, [("base.oci.tar", data), ("receipt/receipt.env", receipt),
                                  ("receipt/oci.json", json.dumps({"top_digest": oci_top})),
                                  ("tools/openclaw-base-guard.py", guard)])

        zpath, zdigest = artifact_zip("good.zip")
        ok_dir = os.path.join(tmp, "unpacked-good")
        case("artifact that hashes to the API digest is unpacked", extract_artifact(zpath, zdigest, ok_dir) == []
             and os.path.isfile(os.path.join(ok_dir, "receipt", "receipt.env")))
        no_dir = os.path.join(tmp, "unpacked-bad")
        case("artifact that differs from the API digest is refused before unpacking",
             extract_artifact(zpath, "sha256:" + "0" * 64, no_dir) != [] and not os.path.exists(no_dir))
        case("missing API digest is refused", extract_artifact(zpath, "", no_dir) != [] and not os.path.exists(no_dir))
        for label, entries, link in (("a .. path", [("../escape", "x")], None),
                                     ("an absolute path", [("/tmp/escape", "x")], None),
                                     ("a symlink", [("ok.txt", "x")], "tools/link")):
            p, d = zipped("evil-%d.zip" % len(label), entries, link)
            case("artifact entry with %s is refused" % label,
                 extract_artifact(p, d, no_dir) != [] and not os.path.exists(no_dir))

        expect = {"run_url": run_url, "commit": commit, "run_id": rid, "attempt": att, "artifact_name": name,
                  "archive_sha256": sha256_bytes(archive), "top_digest": top}

        def binding(zname, fresh=top, **zip_change):
            p, d = artifact_zip(zname + ".zip", **zip_change)
            out = os.path.join(tmp, "unpacked-" + zname)
            assert extract_artifact(p, d, out) == []
            return publish_binding(out, fresh, trusted, expect)

        case("artifact bound to the inputs, run and trusted guard passes", binding("bind-ok") == [])
        case("receipt of another run attempt is refused",
             binding("bind-att", receipt=good_receipt.replace("/attempts/%s" % att, "/attempts/1")
                     .replace("run_attempt=%s" % att, "run_attempt=1")) != [])
        case("receipt of another run is refused",
             binding("bind-run", receipt=good_receipt.replace(rid, "41700000002")) != [])
        case("receipt of another commit is refused",
             binding("bind-commit", receipt=good_receipt.replace(commit, "b" * 40)) != [])
        case("receipt with another artifact name is refused",
             binding("bind-name", receipt=good_receipt.replace(name, artifact_name("2026.10.10-src.1", "1"))) != [])
        case("receipt with two values for one key is refused",
             binding("bind-dup", receipt=good_receipt + "run_attempt=1\n") != [])
        case("archive with other bytes is refused", binding("bind-bytes", data=b"other bytes") != [])
        case("OCI top digest read now that differs from the input is refused",
             binding("bind-top", fresh="sha256:" + "1" * 64) != [])
        case("receipt oci.json top digest that differs is refused",
             binding("bind-rtop", oci_top="sha256:" + "1" * 64) != [])
        case("artifact guard that differs from the build-commit guard is refused",
             binding("bind-guard", guard="guard v2\n") != [])

        case("existing tag is present", registry_tag_state(0, "") == "present")
        case("manifest unknown is absent", registry_tag_state(
            1, "Error: reading manifest x in ghcr.io/a/b: manifest unknown") == "absent")
        case("name unknown is absent", registry_tag_state(
            1, "Error: name unknown: repository name not known to registry") == "absent")
        case("network error is not absent", registry_tag_state(
            1, "Error: pinging container registry ghcr.io: dial tcp: i/o timeout") == "error")
        case("auth error is not absent", registry_tag_state(
            1, "Error: reading manifest x: unauthorized: authentication required") == "error")
        case("denied is not absent", registry_tag_state(
            1, "Error: denied: requested access to the resource is denied") == "error")
    finally:
        shutil.rmtree(tmp)
    failed = [n for n, ok in results if not ok]
    print("%d/%d passed" % (len(results) - len(failed), len(results)))
    return 1 if failed else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--root", required=True)
    c.add_argument("--out", required=True)
    m = sub.add_parser("compare")
    m.add_argument("--receipt", required=True)
    m.add_argument("--observed", required=True)
    m.add_argument("--forbidden", required=True)
    m.add_argument("--diffids")
    m.add_argument("--versions-env")
    m.add_argument("--expect-version")
    m.add_argument("--expect-commit")
    for name in ("policy", "lock-changes"):
        q = sub.add_parser(name)
        q.add_argument("--upstream", required=True)
        q.add_argument("--patched", required=True)
        if name == "policy":
            q.add_argument("--allow-exclude", default="")
    o = sub.add_parser("oci")
    o.add_argument("--archive", required=True)
    o.add_argument("--platform", default="linux/amd64")
    o.add_argument("--require-attestations", action="store_true")
    o.add_argument("--image-out", help="also write a single-image archive for docker load")
    o.add_argument("--image-name", default="openclaw-base:candidate")
    d = sub.add_parser("diffids")
    d.add_argument("--image-json", required=True)
    d.add_argument("--platform", default="linux/amd64")
    pi = sub.add_parser("publish-inputs")
    for flag in ("--run-id", "--attempt", "--artifact-id", "--archive-sha256", "--top-digest"):
        pi.add_argument(flag, required=True)
    pr = sub.add_parser("publish-run")
    for flag in ("--json", "--run-id", "--attempt", "--repository", "--repository-id"):
        pr.add_argument(flag, required=True)
    pa = sub.add_parser("publish-artifact")
    for flag in ("--json", "--artifact-id", "--run-id", "--head-sha", "--name", "--repository-id"):
        pa.add_argument(flag, required=True)
    ax = sub.add_parser("artifact-extract")
    for flag in ("--zip", "--digest", "--out"):
        ax.add_argument(flag, required=True)
    pb = sub.add_parser("publish-binding")
    for flag in ("--dir", "--oci-json", "--trusted-guard", "--run-url", "--commit", "--run-id",
                 "--attempt", "--artifact-name", "--archive-sha256", "--top-digest"):
        pb.add_argument(flag, required=True)
    t = sub.add_parser("registry-tag")
    t.add_argument("--rc", type=int, required=True)
    t.add_argument("--stderr", required=True)
    a = p.parse_args(argv)
    try:
        if a.cmd == "registry-tag":
            with open(a.stderr, encoding="utf-8", errors="replace") as f:
                state = registry_tag_state(a.rc, f.read())
            print(state)
            return 1 if state == "error" else 0
        if a.cmd in ("publish-run", "publish-artifact"):
            doc = read_json(a.json)
            if a.cmd == "publish-run":
                errors = publish_run(doc, a.run_id, a.attempt, a.repository, a.repository_id)
                value = doc.get("head_sha") if isinstance(doc, dict) else None
            else:
                errors = publish_artifact(doc, a.artifact_id, a.run_id, a.head_sha, a.name, a.repository_id)
                value = doc.get("digest") if isinstance(doc, dict) else None
            for err in errors:
                print("REFUSED: %s" % err, file=sys.stderr)
            if not errors:
                print(value)
            return 1 if errors else 0
        if a.cmd == "publish-inputs":
            errors = publish_inputs(a.run_id, a.attempt, a.artifact_id, a.archive_sha256, a.top_digest)
        elif a.cmd == "artifact-extract":
            errors = extract_artifact(a.zip, a.digest, a.out)
        elif a.cmd == "publish-binding":
            fresh = read_json(a.oci_json).get("top_digest")
            errors = publish_binding(a.dir, fresh, a.trusted_guard, {
                "run_url": a.run_url, "commit": a.commit, "run_id": a.run_id, "attempt": a.attempt,
                "artifact_name": a.artifact_name, "archive_sha256": a.archive_sha256,
                "top_digest": a.top_digest})
        if a.cmd in ("publish-inputs", "artifact-extract", "publish-binding"):
            for err in errors:
                print("REFUSED: %s" % err, file=sys.stderr)
            if not errors:
                print("openclaw-base-guard: %s passed" % a.cmd)
            return 1 if errors else 0
        if a.cmd == "diffids":
            print("".join(i + "\n" for i in image_json_diffids(a.image_json, a.platform)), end="")
            return 0
        if a.cmd == "oci":
            facts = oci_facts(a.archive, a.platform, a.require_attestations)
            if a.image_out:
                oci_image_archive(a.archive, a.image_out, a.platform, a.image_name)
            print(json.dumps(facts, indent=2, sort_keys=True))
            return 0
        if a.cmd == "collect":
            facts = collect(a.root, a.out)
            print(json.dumps({k: facts[k] for k in ("dist_entries", "node_modules_entries",
                                                    "package_version", "build_info")}, sort_keys=True))
            return 0
        if a.cmd == "lock-changes":
            removed, added = lock_changes(a.upstream, a.patched)
            print("".join("- %s\n" % k for k in removed) + "".join("+ %s\n" % k for k in added), end="")
            return 0
        if a.cmd == "compare":
            errors = compare(a.receipt, a.observed, a.forbidden, a.diffids, a.versions_env,
                             a.expect_version, a.expect_commit)
        else:
            errors = policy(a.upstream, a.patched, a.allow_exclude)
    except (OSError, ValueError) as e:
        print("openclaw-base-guard: %s" % e, file=sys.stderr)
        return 2
    for e in errors:
        print("REFUSED: %s" % e, file=sys.stderr)
    if not errors:
        print("openclaw-base-guard: %s passed" % a.cmd)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
