#!/usr/bin/env python3
"""Guard for the Compliance Claw source-built OpenClaw base (openclaw-base/README.md).

  collect --root DIR --out DIR
      Run INSIDE an image (python3 -I, --network none, read-only): write the
      dist and node_modules manifests, the pnpm store list, the app and global
      npm facts, the dpkg list and facts.json.
  compare --receipt DIR --observed DIR --forbidden FILE [--diffids FILE]
          [--versions-env FILE] [--expect-version V] [--expect-commit C]
      On the host: compare an observed collection with a committed receipt.
  policy --upstream FILE --patched FILE [--allow-exclude NAME@X.Y.Z]
      A workspace change may touch only the top-level `overrides:` block.
      With --allow-exclude (AGE_EXCLUDE_EXCEPTION), it must also append that
      one exact entry and its expiry comment to `minimumReleaseAgeExclude:`.
  lock-changes --upstream FILE --patched FILE
      List the package keys that a lock change removes (-) and adds (+).
  oci --archive FILE [--platform linux/amd64]
      Read a buildx OCI archive: the top digest, the platform manifest and
      config digests, the RootFS diffIDs and the attestation manifests.
  diffids --image-json FILE [--platform linux/amd64]
      Print the RootFS diffIDs from `docker buildx imagetools inspect --format
      '{{json .Image}}'` output (one image, or a map by platform).
  environment --json FILE --name NAME
      The publish gate: the GitHub environment (REST "Get an environment")
      must have a required_reviewers rule with at least one reviewer and
      self-review prevented.
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


# One user-approved age exception (openclaw-base/README.md): one exact
# name@x.y.z, never a bare name, scope wildcard, range or disjunction.
EXACT_EXCLUDE = re.compile(r"^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*@\d+\.\d+\.\d+$")
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
    """A workspace change may touch only `overrides:`. With allow_exclude, it
    may also append exactly one comment and that one exact entry at the end of
    `minimumReleaseAgeExclude:`. Nothing else in the age policy may change."""
    if allow_exclude and not EXACT_EXCLUDE.match(allow_exclude):
        return ["--allow-exclude must be one exact name@x.y.z, not %r" % allow_exclude]
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


def environment_gate(doc, name):
    """Errors unless the environment requires a reviewer and prevents self-review.

    GitHub creates a referenced environment with NO protection rules, so a
    missing rule must refuse, never pass.
    """
    if not isinstance(doc, dict) or doc.get("name") != name:
        return ["environment response is not for %r" % name]
    rules = [r for r in doc.get("protection_rules") or [] if r.get("type") == "required_reviewers"]
    if not rules:
        return ["environment %r has no required_reviewers rule" % name]
    errors = []
    if not any(r.get("reviewers") for r in rules):
        errors.append("environment %r required_reviewers rule names no reviewer" % name)
    if not all(r.get("prevent_self_review") is True for r in rules):
        errors.append("environment %r does not prevent self-review" % name)
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


def oci_image_archive(archive, out, platform="linux/amd64", name="openclaw-base:candidate"):
    """Write a single-image OCI archive for `docker load` from the same bytes.

    It holds the selected platform manifest, its config and its layers, each
    copied only after its size and sha256 match. The pushed archive names the
    same manifest digest, so the loaded image is the image that is published.
    """
    import io
    import tarfile
    facts = oci_facts(archive, platform)
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
            h, n, f = hashlib.sha256(), 0, src.extractfile(member)
            spool = tempfile.TemporaryFile()
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
                n += len(chunk)
                spool.write(chunk)
            if n != layer["size"] or h.hexdigest() != hexd:
                raise ValueError("layer %d does not match its descriptor" % i)
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

        def ws(name, exclude, age="10080", strict="true"):
            path = os.path.join(tmp, "ws-x-%s.yaml" % name)
            _write(path, "packages:\n  - .\n\nminimumReleaseAge: %s\nminimumReleaseAgeStrict: %s\n\n"
                         "minimumReleaseAgeExclude:\n  - \"solid-js\"\n"
                         "  # Upstream: remove after 2026-10-21T13:01:12.291Z.\n  - \"@o/fs@0.26.5\"\n%s\n"
                         "overrides:\n  qs: 6.16.1\n\ntrust: a\n" % (age, strict, exclude))
            return path
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
        case("exclude entry without an expiry comment is refused",
             policy(xup, ws("nonote", "  # Compliance Claw: joi 18.3.1.\n" + entry), j) != [])

        la = os.path.join(tmp, "lock-a.yaml")
        _write(la, "lockfileVersion: '9.0'\n\npackages:\n\n  joi@18.2.9:\n    resolution: {}\n\n"
                   "  '@a/b@1.0.0':\n    resolution: {}\n\nsnapshots:\n\n  joi@18.2.9: {}\n")
        lb = os.path.join(tmp, "lock-b.yaml")
        _write(lb, "lockfileVersion: '9.0'\n\npackages:\n\n  joi@18.3.1:\n    resolution: {}\n\n"
                   "  '@a/b@1.0.0':\n    resolution: {}\n\nsnapshots:\n\n  joi@18.3.1: {}\n")
        case("lock package changes are listed", lock_changes(la, lb) == (["joi@18.2.9"], ["joi@18.3.1"]))

        def oci_archive(name, extra_platform=False, single=False, corrupt_manifest=False,
                        wrong_config_size=False, sbom=True):
            import io
            import tarfile
            blobs = {}

            def put(obj, raw=None):
                data = raw if raw is not None else json.dumps(obj).encode()
                d = "sha256:" + sha256_bytes(data)
                blobs[d] = data
                return d, len(data)

            layer, layer_n = put(None, b"layer-bytes")
            cfg, cfg_n = put({"os": "linux", "architecture": "amd64",
                              "rootfs": {"type": "layers", "diff_ids": ["sha256:l1", "sha256:l2"]},
                              "config": {"Labels": {"a": "b"}}})
            img, img_n = put({"schemaVersion": 2,
                              "config": {"digest": cfg, "size": cfg_n + (1 if wrong_config_size else 0)},
                              "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                                          "digest": layer, "size": layer_n}]})
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
             f["top_digest"] == top and f["manifest_digest"] == img and f["diff_ids"] == ["sha256:l1", "sha256:l2"]
             and len(f["attestation_manifests"]) == 1 and len(f["attestation_predicates"]) == 2)
        single_out = os.path.join(tmp, "single-out.tar")
        g = oci_image_archive(path, single_out)
        import tarfile
        with tarfile.open(single_out) as t:
            names = sorted(t.getnames())
            idx = json.loads(t.extractfile("index.json").read())
        case("single-image archive holds the same manifest, config and layer",
             g["manifest_digest"] == img and idx["manifests"][0]["digest"] == img
             and len([n for n in names if n.startswith("blobs/")]) == 3 and "oci-layout" in names)
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

        env = "openclaw-base-publish"
        reviewer = {"type": "User", "reviewer": {"login": "someone", "id": 1}}
        good_env = {"name": env, "protection_rules": [
            {"id": 1, "node_id": "x", "type": "required_reviewers", "prevent_self_review": True,
             "reviewers": [reviewer]}]}
        case("protected publish environment passes", environment_gate(good_env, env) == [])
        case("environment created without rules is refused",
             environment_gate({"name": env, "protection_rules": []}, env) != [])
        case("environment with only a wait timer is refused",
             environment_gate({"name": env, "protection_rules": [{"type": "wait_timer", "wait_timer": 5}]}, env) != [])
        case("required_reviewers rule without a reviewer is refused",
             environment_gate({"name": env, "protection_rules": [
                 {"type": "required_reviewers", "prevent_self_review": True, "reviewers": []}]}, env) != [])
        case("environment that allows self-review is refused",
             environment_gate({"name": env, "protection_rules": [
                 {"type": "required_reviewers", "prevent_self_review": False, "reviewers": [reviewer]}]}, env) != [])
        case("response for another environment is refused", environment_gate(good_env, "other") != [])

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
    e = sub.add_parser("environment")
    e.add_argument("--json", required=True)
    e.add_argument("--name", required=True)
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
        if a.cmd == "environment":
            errors = environment_gate(read_json(a.json), a.name)
            for err in errors:
                print("REFUSED: %s" % err, file=sys.stderr)
            if not errors:
                print("openclaw-base-guard: environment %s is protected" % a.name)
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
