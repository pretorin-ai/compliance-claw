#!/usr/bin/env python3
"""release-assets.py — the one resolver for a Compliance Claw release set.

    release-assets.py prepare  --version X.Y.Z --commit SHA --repository OWNER/NAME
                               --image-repository REPO --digest sha256:HEX
                               --sbom PATH --out DIR [--source DIR]
    release-assets.py finalize --dir DIR [--signed]
    release-assets.py check    [--dir DIR] [--stage final|candidate|any]
                               [--version X.Y.Z] [--all-assets]
                               [--source DIR [--tag-only]] [--allow-unsigned]
                               [--record-only]
                               [--compose | --rendered FILE|-] [--json]
    release-assets.py fetch    --version X.Y.Z --dir DIR [--json]
    release-assets.py --self-test      (runs scripts/test-release-assets.py)

HOST-ONLY, standard library only. Nothing in the image runs this.

A RELEASE SET is three GitHub Release assets: compliance-claw-release.json (the
record), compose.release.yaml (image selection only) and sbom-X.Y.Z.spdx.json.
A signed set adds compliance-claw-release.json.sig: one line of base64 of the
DER ECDSA P-256 SHA-256 signature over the exact record bytes (the form that
`cosign sign-blob` writes). Nothing signs a release yet: the trust key is not
committed and the publisher does not sign. Fields, procedure and placement:
docs/releasing.md and docs/image-verification.md.

INVARIANTS
- One resolver. The publisher (release.yml) calls `prepare` and `finalize`.
  Guided setup and the updater use `fetch` and `check` and never parse the
  record themselves.
- One trust key: release-keys/compliance-claw-release.pub in the checkout that
  holds this file. No option, variable or downloaded file supplies a key.
  OpenSSL checks it: one PEM block, a valid point (`pkey -pubcheck`, OpenSSL
  1.1.1 or later), the P-256 curve. Its fingerprint is the sha256 of its DER
  SubjectPublicKeyInfo.
- `fetch` reads only a PUBLISHED release of the fixed public repository (no
  credential, no draft) into an empty directory, with the record signature of
  a signed set, and checks integrity as `check --stage final --all-assets`
  does. It reports the signature status; the signature gate is in `check`
  alone.
- The rendered Compose model is never printed or written: a legacy `.env`
  selection renders secret values into it. `--rendered -` reads it from stdin.
  A mismatch prints only image references.
- Signatures fail closed (exit 6). "signed" passes only when the record names
  the trust key, the record signature verifies over the exact record bytes
  (openssl; the record binds the overlay and SBOM hashes), AND the image
  signature at the recorded digest verifies with the same key. The image check
  runs the cosign that versions.env pins (Linux amd64 only; downloaded to a
  temporary file, checksum-checked, cached under .cache/release-tools/, checked
  again on every use) with the host's registry login. `--record-only` skips
  only the image check and says so; customer flows use it only after a full
  check of the same set. `--allow-unsigned` admits "unsigned" only, prints
  "UNVERIFIED: publisher authenticity not checked", and never relaxes a signed
  check; preparation, publication, update preview and fixtures pass it,
  customer install and apply never do. Any other status is refused.
- The overlay is generated from the record byte for byte, and `check`
  compares it, so an added key (port, volume, environment) fails. Every value
  in it comes from a pattern-validated field; no YAML parser is needed.
- `finalize` changes only `stage` (candidate -> final); the overlay and SBOM
  bytes are reused, and the record stays "unsigned". `finalize --signed` also
  writes status "signed" and the trust key fingerprint before anything signs
  the record; it is for synthetic-key tests, and the publisher does not use it.
  A customer flow keeps `--stage final` and refuses a candidate.
- Host placement: record and overlay in the repository root (gitignored), the
  overlay directly after compose.yaml in COMPOSE_FILE. A later overlay that
  sets `image` wins in Compose; `check --compose` reports it (exit 4) and
  changes nothing.

EXIT CODES (every subcommand):
    0  valid
    1  release data invalid or mismatched (record, overlay, asset, checksum,
       stage, version); every `prepare` refusal
    2  usage error
    3  source checkout does not match the record (tag missing or at another
       commit, or HEAD is another commit; --tag-only skips the HEAD check)
    4  the effective Compose selection does not select the release image
       (overlay not selected, or a later overlay overrides it)
    5  a required tool or download cannot run (git, docker compose, the
       release download; openssl missing or without `pkey -pubcheck`; cosign:
       not Linux amd64, download, checksum, timeout, or registry access)
    6  the release is not signed or its signature is not verified (unsigned
       without --allow-unsigned; any status other than "unsigned" or "signed";
       no valid trust key or another key; a missing, altered, stale or
       wrong-key record or image signature; an image signature for another
       digest or repository)
"""
import argparse
import base64
import binascii
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

RECORD = "compliance-claw-release.json"
OVERLAY = "compose.release.yaml"
RECORD_SIGNATURE = RECORD + ".sig"
PLATFORM = "linux/amd64"
SCHEMA = 1
STAGES = ("candidate", "final")
# `check` passes "unsigned" only with --allow-unsigned and "signed" only when
# both signatures verify. Every other value is refused (exit 6).
SIGNATURE_STATUS_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
# The reviewed Compliance Claw release key, read from THIS checkout only. It is
# never taken from a release set, an option or the environment. It is separate
# from vendor/cosign.pub (the Pretorin CLI key). See release-keys/README.md.
TRUST_KEY = os.path.join("release-keys", "compliance-claw-release.pub")
OPENSSL_TIMEOUT = 60
# A DER P-256 signature is at most 72 bytes, so its base64 line is much shorter.
SIGNATURE_LIMIT = 1024
# The image signature is checked by cosign, pinned in versions.env of the same
# checkout (no second pin), cached in a gitignored directory and checked against
# COSIGN_SHA256 on every use.
COSIGN_PINS = ("COSIGN_VERSION", "COSIGN_ASSET", "COSIGN_SHA256")
COSIGN_DOWNLOAD = "https://github.com/sigstore/cosign/releases/download"
COSIGN_CACHE = os.path.join(".cache", "release-tools")
COSIGN_LIMIT = 256 * 1024 * 1024
COSIGN_TIMEOUT = 600
IMAGE_SIGNATURE_TYPE = "cosign container image signature"
SERVICES = ("openclaw", "cli")
# fetch reads only published releases of this repository.
RELEASE_REPOSITORY = "pretorin-ai/compliance-claw"
RELEASE_DOWNLOAD = "https://github.com/%s/releases/download" % RELEASE_REPOSITORY
FETCH_LIMIT = 64 * 1024 * 1024

VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# registry[:port]/path, lowercase, no tag and no digest.
IMAGE_REPOSITORY_RE = re.compile(
    r"^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$")

DATA, USAGE, SOURCE, SELECTION, TOOL, UNSIGNED = 1, 2, 3, 4, 5, 6
UNVERIFIED = "UNVERIFIED: publisher authenticity not checked"


class ReleaseError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def sbom_name(version):
    return "sbom-%s.spdx.json" % version


def image_reference(image_repository, version, digest):
    return "%s:%s@%s" % (image_repository, version, digest)


def render_overlay(version, commit, reference):
    # Values are pattern-validated before they get here, so a double-quoted
    # scalar needs no escaping.
    return (
        "# Generated by scripts/release-assets.py from %s. Do not edit.\n"
        "# Selects the Compliance Claw %s image for both services. Select this\n"
        "# file directly after compose.yaml in COMPOSE_FILE.\n"
        "x-compliance-claw-release:\n"
        "  version: \"%s\"\n"
        "  source_commit: \"%s\"\n"
        "  image: \"%s\"\n"
        "services:\n"
        "  openclaw:\n"
        "    image: \"%s\"\n"
        "  cli:\n"
        "    image: \"%s\"\n"
    ) % (RECORD, version, version, commit, reference, reference, reference)


def dump_record(record):
    return json.dumps(record, indent=2, sort_keys=True) + "\n"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def write_atomic(path, data):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".release-assets.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def require(ok, message, code=DATA):
    if not ok:
        raise ReleaseError(code, message)


def require_match(pattern, value, what):
    require(isinstance(value, str) and pattern.match(value) is not None,
            "%s is missing or malformed: %r" % (what, value))


def require_keys(obj, keys, what):
    require(isinstance(obj, dict), "%s is not an object" % what)
    got = set(obj)
    require(got == set(keys), "%s fields are %s, expected %s"
            % (what, sorted(got), sorted(keys)))


def validate_sbom(data, name):
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ReleaseError(DATA, "%s is not JSON: %s" % (name, exc))
    require(isinstance(doc, dict) and isinstance(doc.get("spdxVersion"), str)
            and doc["spdxVersion"].startswith("SPDX-"),
            "%s is not an SPDX JSON document" % name)
    packages = doc.get("packages")
    require(isinstance(packages, list) and len(packages) > 0,
            "%s lists no packages" % name)


def validate_record(record):
    """Every field, every type, every cross-field binding."""
    require_keys(record, ("schema", "stage", "version", "source", "image",
                          "assets", "signature"), "record")
    require(record["schema"] == SCHEMA and type(record["schema"]) is int,
            "record schema is %r, expected %d" % (record["schema"], SCHEMA))
    require(record["stage"] in STAGES,
            "record stage is %r, expected one of %s" % (record["stage"], STAGES))
    version = record["version"]
    require_match(VERSION_RE, version, "version")

    source = record["source"]
    require_keys(source, ("repository", "tag", "commit"), "source")
    require_match(REPOSITORY_RE, source["repository"], "source.repository")
    require(source["tag"] == "v" + version,
            "source.tag is %r, expected %r" % (source["tag"], "v" + version))
    require_match(COMMIT_RE, source["commit"], "source.commit")

    image = record["image"]
    require_keys(image, ("repository", "digest", "reference", "platform"), "image")
    require_match(IMAGE_REPOSITORY_RE, image["repository"], "image.repository")
    require_match(DIGEST_RE, image["digest"], "image.digest")
    expected_ref = image_reference(image["repository"], version, image["digest"])
    require(image["reference"] == expected_ref,
            "image.reference is %r, expected %r" % (image["reference"], expected_ref))
    require(image["platform"] == PLATFORM,
            "image.platform is %r, expected %r" % (image["platform"], PLATFORM))

    assets = record["assets"]
    require(isinstance(assets, list), "assets is not a list")
    expected = {OVERLAY: "compose-overlay", sbom_name(version): "sbom"}
    names = []
    for i, asset in enumerate(assets):
        require_keys(asset, ("name", "role", "sha256", "size"), "assets[%d]" % i)
        require(isinstance(asset["name"], str) and isinstance(asset["role"], str),
                "assets[%d] name and role must be strings" % i)
        require(asset["name"] in expected and expected[asset["name"]] == asset["role"],
                "assets[%d] is %r with role %r; expected one of %s"
                % (i, asset["name"], asset["role"], expected))
        require_match(SHA256_RE, asset["sha256"], "assets[%d].sha256" % i)
        require(type(asset["size"]) is int and asset["size"] > 0,
                "assets[%d].size is %r" % (i, asset["size"]))
        names.append(asset["name"])
    require(sorted(names) == sorted(expected),
            "assets are %s, expected exactly %s" % (sorted(names), sorted(expected)))

    signature = record["signature"]
    require(isinstance(signature, dict), "signature is not an object")
    require_match(SIGNATURE_STATUS_RE, signature.get("status"), "signature.status")
    if signature["status"] == "signed":
        # finalize --signed fixes these fields before anything signs; nothing rewrites them.
        require(record["stage"] == "final", "a %s record cannot be signed" % record["stage"])
        require_keys(signature, ("status", "record_signature_asset", "key_sha256"), "signature")
        require_match(SHA256_RE, signature["key_sha256"], "signature.key_sha256")
    else:
        require_keys(signature, ("status", "record_signature_asset"), "signature")
    require(signature["record_signature_asset"] == RECORD_SIGNATURE,
            "signature.record_signature_asset is %r, expected %r"
            % (signature["record_signature_asset"], RECORD_SIGNATURE))


def load_record(directory):
    return load_record_bytes(directory)[0]


def load_record_bytes(directory):
    """The record and the exact bytes that the record signature covers."""
    path = os.path.join(directory, RECORD)
    try:
        data = read_bytes(path)
    except OSError as exc:
        raise ReleaseError(DATA, "cannot read the release record %s: %s" % (path, exc.strerror))
    try:
        record = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ReleaseError(DATA, "%s is not JSON: %s" % (path, exc))
    validate_record(record)
    # One byte form, so the later signature covers exactly one thing.
    require(data == dump_record(record).encode("utf-8"),
            "%s is not in canonical form (it was edited after generation)" % path)
    return record, data


def verify_assets(directory, record, all_assets):
    """The overlay is always required. Other assets are checked when present."""
    for asset in record["assets"]:
        path = os.path.join(directory, asset["name"])
        if not os.path.exists(path):
            require(asset["name"] != OVERLAY and not all_assets,
                    "release asset %s is missing from %s" % (asset["name"], directory))
            continue
        try:
            data = read_bytes(path)
        except OSError as exc:
            raise ReleaseError(DATA, "cannot read release asset %s: %s" % (path, exc.strerror))
        require(len(data) == asset["size"] and sha256_bytes(data) == asset["sha256"],
                "release asset %s does not match its recorded sha256/size" % asset["name"])
        if asset["role"] == "sbom":
            validate_sbom(data, asset["name"])
    try:
        overlay = read_bytes(os.path.join(directory, OVERLAY))
    except OSError as exc:
        raise ReleaseError(DATA, "cannot read %s: %s" % (OVERLAY, exc.strerror))
    expected = render_overlay(record["version"], record["source"]["commit"],
                              record["image"]["reference"]).encode("utf-8")
    require(overlay == expected,
            "%s does not select exactly the recorded image" % OVERLAY)


def git(source, *args):
    try:
        p = subprocess.run(("git", "-C", source) + args, capture_output=True, text=True)
    except OSError as exc:
        raise ReleaseError(TOOL, "cannot run git: %s" % exc.strerror)
    return p.stdout.strip() if p.returncode == 0 else ""


def check_source(source, record, tag_only=False):
    tag, commit = record["source"]["tag"], record["source"]["commit"]
    tagged = git(source, "rev-parse", "--verify", "--quiet", "refs/tags/%s^{commit}" % tag)
    require(tagged != "", "source %s has no tag %s" % (source, tag), SOURCE)
    require(tagged == commit, "tag %s in %s is commit %s; the release record names %s"
            % (tag, source, tagged, commit), SOURCE)
    if tag_only:
        return
    head = git(source, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
    require(head == commit, "%s is at commit %s; release %s is commit %s. Check out %s first."
            % (source, head or "<none>", record["version"], commit, tag), SOURCE)


def checkout_root():
    # The checkout that holds this helper: the reviewed checkout, never the set.
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_trust_key():
    return os.path.join(checkout_root(), TRUST_KEY)


def openssl(args, what, data=None):
    """Run openssl with a time limit. Exit 5 when it cannot run at all."""
    try:
        return subprocess.run(("openssl",) + tuple(args), input=data, capture_output=True,
                              timeout=OPENSSL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ReleaseError(TOOL, "cannot run openssl to check %s: %s"
                           % (what, getattr(exc, "strerror", None) or exc))


def last_line(data):
    text = data.decode("utf-8", "replace") if isinstance(data, bytes) else data
    lines = text.strip().splitlines()
    return lines[-1][:200] if lines else "no output"


def load_trust_key(path):
    """(PEM, fingerprint) of the one ECDSA P-256 public key in `path`. OpenSSL
    checks the key: `pkey -pubcheck` proves a valid public point, the decoded
    curve must be prime256v1, and the fingerprint is the sha256 of the DER
    SubjectPublicKeyInfo that OpenSSL writes. The PEM that OpenSSL writes is
    the key that later checks use."""
    try:
        text = read_bytes(path).decode("ascii")
    except OSError as exc:
        raise ReleaseError(UNSIGNED, "no Compliance Claw release trust key at %s (%s). This "
                           "checkout cannot verify a signed release." % (path, exc.strerror))
    except UnicodeDecodeError:
        raise ReleaseError(UNSIGNED, "trust key %s is not PEM text" % path)
    # openssl reads only the first PEM block; a second key must not hide behind it.
    # CRLF and LF files are the same key.
    begins = re.findall(r"^-----BEGIN [A-Z0-9 ]+-----$", text.replace("\r\n", "\n"), re.M)
    require(begins == ["-----BEGIN PUBLIC KEY-----"],
            "trust key %s must hold exactly one PEM PUBLIC KEY block" % path, UNSIGNED)
    p = openssl(("pkey", "-help"), "the trust key")
    require(b"-pubcheck" in p.stdout + p.stderr,
            "the trust key check needs OpenSSL 1.1.1 or later (`openssl pkey -pubcheck`); "
            "this openssl does not have it (%s)" % last_line(openssl(("version",), "its version").stdout),
            TOOL)
    p = openssl(("pkey", "-pubin", "-in", path, "-pubcheck", "-noout"), path)
    require(p.returncode == 0, "trust key %s is not a valid public key (openssl: %s)"
            % (path, last_line(p.stderr)), UNSIGNED)
    p = openssl(("pkey", "-pubin", "-in", path, "-noout", "-text_pub"), path)
    require(p.returncode == 0 and re.search(rb"^ASN1 OID: prime256v1\s*$", p.stdout, re.M),
            "trust key %s is not an ECDSA P-256 (prime256v1) key" % path, UNSIGNED)
    key = openssl(("pkey", "-pubin", "-in", path), path)
    der = openssl(("pkey", "-pubin", "-in", path, "-outform", "DER"), path)
    require(key.returncode == 0 and der.returncode == 0 and key.stdout and der.stdout,
            "openssl cannot export trust key %s" % path, UNSIGNED)
    return key.stdout, sha256_bytes(der.stdout)


def read_record_signature(path, version):
    """The detached record signature: one line of base64 (an optional final
    newline). OpenSSL decides whether the decoded bytes are a valid signature."""
    try:
        raw = read_bytes(path)
    except OSError as exc:
        raise ReleaseError(UNSIGNED, "release %s is marked signed but %s is missing (%s)"
                           % (version, path, exc.strerror))
    require(len(raw) <= SIGNATURE_LIMIT, "%s is larger than %d bytes" % (RECORD_SIGNATURE, SIGNATURE_LIMIT),
            UNSIGNED)
    try:
        sig = base64.b64decode(raw[:-1] if raw.endswith(b"\n") else raw, validate=True)
    except (binascii.Error, ValueError):
        raise ReleaseError(UNSIGNED, "%s is not one line of base64" % RECORD_SIGNATURE)
    require(sig, "%s is empty" % RECORD_SIGNATURE, UNSIGNED)
    return sig


def openssl_verify(key, sig, data, what):
    """True when `sig` verifies over exactly `data` with the PEM `key`. Every input
    goes through a private temporary file."""
    with tempfile.TemporaryDirectory(prefix="cc-verify-") as tmp:
        paths = {}
        for name, blob in (("key.pem", key), ("sig.der", sig), ("data", data)):
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "wb") as f:
                f.write(blob)
        p = openssl(("dgst", "-sha256", "-verify", paths["key.pem"], "-signature", paths["sig.der"],
                     paths["data"]), what)
    return p.returncode == 0 and b"Verified OK" in p.stdout


def check_record_signature(directory, record, data, key, trust_key):
    """The record signature asset, over the exact record bytes, with the trust key
    from this checkout. A downloaded key is never used."""
    pem, fingerprint = key
    require(record["signature"]["key_sha256"] == fingerprint,
            "release %s names signing key %s; this checkout trusts %s (%s)"
            % (record["version"], record["signature"]["key_sha256"], fingerprint, trust_key), UNSIGNED)
    sig = read_record_signature(os.path.join(directory, RECORD_SIGNATURE), record["version"])
    require(openssl_verify(pem, sig, data, RECORD),
            "%s does not verify over %s with the trust key %s: the signature is altered, "
            "stale, malformed or from another key" % (RECORD_SIGNATURE, RECORD, fingerprint), UNSIGNED)


def check_image_payloads(payloads, record):
    """Each verified simple-signing payload must name exactly the recorded digest
    and image repository. A signature for another digest or repository fails."""
    image = record["image"]
    require(isinstance(payloads, list) and payloads,
            "no verified image signature for %s@%s" % (image["repository"], image["digest"]), UNSIGNED)
    want = (image["digest"], image["repository"], IMAGE_SIGNATURE_TYPE)
    for payload in payloads:
        # Every level must be a JSON object before a field is read from it.
        critical = payload.get("critical") if isinstance(payload, dict) else None
        signed = critical.get("image") if isinstance(critical, dict) else None
        identity = critical.get("identity") if isinstance(critical, dict) else None
        require(isinstance(signed, dict) and isinstance(identity, dict),
                "an image signature payload for %s@%s is not a cosign simple-signing object"
                % (image["repository"], image["digest"]), UNSIGNED)
        got = (signed.get("docker-manifest-digest"), identity.get("docker-reference"), critical.get("type"))
        require(got == want, "an image signature names %s for %s (%s); the release record names "
                "%s for %s" % (got[0], got[1], got[2], want[0], want[1]), UNSIGNED)


def cosign_pins(root):
    path = os.path.join(root, "versions.env")
    try:
        text = read_bytes(path).decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ReleaseError(TOOL, "cannot read the cosign pin in %s (%s)" % (path, type(exc).__name__))
    pins = {}
    for line in text.splitlines():
        m = re.match(r"^(%s)=([A-Za-z0-9._-]+)$" % "|".join(COSIGN_PINS), line)
        if m:
            pins[m.group(1)] = m.group(2)
    require(set(pins) == set(COSIGN_PINS) and re.match(r"^v[0-9]+\.[0-9]+\.[0-9]+$", pins["COSIGN_VERSION"])
            and SHA256_RE.match(pins["COSIGN_SHA256"]),
            "%s does not pin cosign (%s)" % (path, ", ".join(COSIGN_PINS)), TOOL)
    return pins


def pinned_cosign(root=None, base=COSIGN_DOWNLOAD, system=None, machine=None):
    """The cosign that versions.env pins, by checksum. Download to a temporary
    file, check its sha256, then move it into the gitignored cache. A cached
    copy is checked against the pin again on every use. Every failure refuses."""
    system = system or platform.system()
    machine = machine or platform.machine()
    require(system == "Linux" and machine in ("x86_64", "amd64"),
            "image signature verification runs only on a Linux amd64 host; this host is %s %s. "
            "Verify from the deployment VM." % (system, machine), TOOL)
    root = root or checkout_root()
    pins = cosign_pins(root)
    require(pins["COSIGN_ASSET"] == "cosign-linux-amd64",
            "versions.env pins %s, expected cosign-linux-amd64" % pins["COSIGN_ASSET"], TOOL)
    cache = os.path.join(root, COSIGN_CACHE)
    path = os.path.join(cache, "cosign-%s-%s" % (pins["COSIGN_VERSION"], pins["COSIGN_SHA256"][:16]))
    if os.path.lexists(path):
        try:
            cached = read_bytes(path)
        except OSError as exc:
            raise ReleaseError(TOOL, "cannot read the cached cosign %s: %s" % (path, exc.strerror))
        require(not os.path.islink(path) and sha256_bytes(cached) == pins["COSIGN_SHA256"],
                "the cached cosign %s does not match COSIGN_SHA256 in versions.env. Delete it, "
                "then run again." % path, TOOL)
        return path
    os.makedirs(cache, exist_ok=True)
    url = "%s/%s/%s" % (base, pins["COSIGN_VERSION"], pins["COSIGN_ASSET"])
    fd, tmp = tempfile.mkstemp(prefix=".cosign.", dir=cache)
    try:
        digest = hashlib.sha256()
        size = 0
        with os.fdopen(fd, "wb") as out:
            try:
                with urllib.request.urlopen(url, timeout=120) as response:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        size += len(chunk)
                        require(size <= COSIGN_LIMIT, "%s is larger than %d bytes" % (url, COSIGN_LIMIT), TOOL)
                        digest.update(chunk)
                        out.write(chunk)
            except (urllib.error.URLError, OSError) as exc:
                raise ReleaseError(TOOL, "cannot download cosign from %s: %s"
                                   % (url, getattr(exc, "reason", None) or exc))
        require(digest.hexdigest() == pins["COSIGN_SHA256"],
                "the cosign download from %s does not match COSIGN_SHA256 in versions.env "
                "(got %s); nothing was kept" % (url, digest.hexdigest()), TOOL)
        os.chmod(tmp, 0o755)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return path


# cosign messages that mean the registry could not be read, not a bad signature.
# Only an authentication or authorization failure says anything about a login;
# a network or TLS failure says nothing about the package visibility.
REGISTRY_AUTH_RE = re.compile(
    r"unauthorized|denied|authentication required|\b40[13]\b|forbidden", re.I)
REGISTRY_NETWORK_RE = re.compile(
    r"no such host|connection refused|connection reset|i/o timeout|timeout|tls|x509|"
    r"certificate|network is unreachable|temporary failure|\b50[0234]\b|\beof\b", re.I)


def check_image_signature(record, key, cosign=None, timeout=None):
    """The image signature at the recorded digest, with the same trust key as the
    record. cosign does the registry work with the host's registry login; this
    function checks what cosign verified. Every failure refuses."""
    pem, fingerprint = key
    cosign = cosign or pinned_cosign()
    ref = "%s@%s" % (record["image"]["repository"], record["image"]["digest"])
    # Settings that could point cosign at another trust root or transparency log.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("COSIGN_", "SIGSTORE_", "TUF_"))}
    with tempfile.TemporaryDirectory(prefix="cc-cosign-") as tmp:
        path = os.path.join(tmp, "release.pub")
        with open(path, "wb") as f:
            f.write(pem)
        try:
            p = subprocess.run((cosign, "verify", "--key", path, "--insecure-ignore-tlog=true",
                                "--output", "json", ref),
                               capture_output=True, env=env, timeout=timeout or COSIGN_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise ReleaseError(TOOL, "cosign did not finish the image signature check of %s in %d "
                               "seconds. Check this host's route to the registry." % (ref, timeout or COSIGN_TIMEOUT))
        except OSError as exc:
            raise ReleaseError(TOOL, "cannot run cosign %s: %s" % (cosign, exc.strerror))
    if p.returncode != 0:
        # The message only explains the refusal, so bytes that are not UTF-8 are replaced.
        stderr = p.stderr.decode("utf-8", "replace")
        last = " ".join(stderr.strip().splitlines()[-3:])[:400] or "no output"
        if REGISTRY_AUTH_RE.search(stderr):
            raise ReleaseError(TOOL, "the registry refused access to the image signature of %s (%s). "
                               "Log in with an account that can read the package: docker login ghcr.io."
                               % (ref, last))
        if REGISTRY_NETWORK_RE.search(stderr):
            raise ReleaseError(TOOL, "cannot reach or read the registry for the image signature of %s "
                               "(%s). Check this host's network route and TLS to the registry."
                               % (ref, last))
        raise ReleaseError(UNSIGNED, "no image signature of %s verifies with the trust key %s (%s)"
                           % (ref, fingerprint, last))
    # The whole stdout must be one UTF-8 JSON value: whitespace around it is
    # allowed, and anything after it is refused.
    try:
        payloads = json.loads(p.stdout.decode("utf-8"))
    except ValueError:
        raise ReleaseError(UNSIGNED, "cosign verified %s but printed no JSON payload list "
                           "(stdout must be exactly one UTF-8 JSON array)" % ref)
    check_image_payloads(payloads, record)
    return len(payloads)


def render_compose():
    # --profile cli: without it Compose leaves the profile-gated cli service out.
    # The rendered model holds environment values, so it is parsed, never printed.
    try:
        p = subprocess.run(("docker", "compose", "--profile", "cli", "config",
                            "--format", "json"), capture_output=True, text=True)
    except OSError as exc:
        raise ReleaseError(TOOL, "cannot run docker compose: %s" % exc.strerror)
    if p.returncode != 0:
        last = (p.stderr.strip().splitlines() or ["no output"])[-1][:300]
        raise ReleaseError(TOOL, "docker compose config failed for the selected files: %s" % last)
    try:
        return json.loads(p.stdout)
    except ValueError:
        raise ReleaseError(TOOL, "docker compose config did not return JSON")


def check_selection(model, record):
    reference = record["image"]["reference"]
    services = model.get("services") if isinstance(model, dict) else None
    require(isinstance(services, dict), "the rendered Compose model has no services", SELECTION)
    effective = {}
    for name in SERVICES:
        service = services.get(name)
        require(isinstance(service, dict),
                "the rendered Compose model has no %s service" % name, SELECTION)
        image = service.get("image")
        effective[name] = image if isinstance(image, str) else "<none>"
    if any(effective[name] != reference for name in SERVICES):
        # Only image references: the rest of the model can hold secret values.
        raise ReleaseError(SELECTION,
                           "Compose does not select release %s.\n"
                           "  expected  %s\n  openclaw  %s\n  cli       %s\n"
                           "Select %s directly after compose.yaml in COMPOSE_FILE. A later "
                           "overlay that sets image (for example a restore overlay) overrides "
                           "it; this check reports that and changes nothing."
                           % (record["version"], reference, effective["openclaw"],
                              effective["cli"], OVERLAY))
    for name in SERVICES:
        platform = services[name].get("platform", PLATFORM)
        require(platform == PLATFORM, "Compose selects platform %r for %s, expected %r"
                % (platform, name, PLATFORM), SELECTION)


def summary(record):
    return {
        "version": record["version"],
        "stage": record["stage"],
        "commit": record["source"]["commit"],
        "tag": record["source"]["tag"],
        "image_reference": record["image"]["reference"],
        "digest": record["image"]["digest"],
        "platform": record["image"]["platform"],
        "signature_status": record["signature"]["status"],
        "key_sha256": record["signature"].get("key_sha256", ""),
    }


def prepare(version, commit, repository, image_repository, digest, sbom, out, source=None):
    require_match(VERSION_RE, version, "--version")
    require_match(COMMIT_RE, commit, "--commit")
    require_match(REPOSITORY_RE, repository, "--repository")
    require_match(IMAGE_REPOSITORY_RE, image_repository, "--image-repository")
    require_match(DIGEST_RE, digest, "--digest")
    require(os.path.basename(sbom) == sbom_name(version),
            "--sbom is %r; release %s needs %s" % (sbom, version, sbom_name(version)))
    try:
        sbom_data = read_bytes(sbom)
    except OSError as exc:
        raise ReleaseError(DATA, "cannot read the SBOM %s: %s" % (sbom, exc.strerror))
    validate_sbom(sbom_data, sbom)

    reference = image_reference(image_repository, version, digest)
    overlay = render_overlay(version, commit, reference).encode("utf-8")
    record = {
        "schema": SCHEMA,
        "stage": "candidate",
        "version": version,
        "source": {"repository": repository, "tag": "v" + version, "commit": commit},
        "image": {"repository": image_repository, "digest": digest,
                  "reference": reference, "platform": PLATFORM},
        "assets": [
            {"name": OVERLAY, "role": "compose-overlay",
             "sha256": sha256_bytes(overlay), "size": len(overlay)},
            {"name": sbom_name(version), "role": "sbom",
             "sha256": sha256_bytes(sbom_data), "size": len(sbom_data)},
        ],
        "signature": {"status": "unsigned", "record_signature_asset": RECORD_SIGNATURE},
    }
    validate_record(record)
    if source is not None:
        # The publisher runs from a checkout of the tag, but CI may check out the
        # commit detached; the tag binding is the part that must hold.
        check_source(source, record, tag_only=True)

    os.makedirs(out, exist_ok=True)
    files = ((OVERLAY, overlay), (sbom_name(version), sbom_data),
             (RECORD, dump_record(record).encode("utf-8")))
    # Refuse before writing anything: a half-replaced set is worse than none.
    for name, data in files:
        path = os.path.join(out, name)
        if os.path.exists(path):
            require(read_bytes(path) == data,
                    "%s already exists with different content; refusing to replace it" % path)
    for name, data in files:
        path = os.path.join(out, name)
        if not os.path.exists(path):
            write_atomic(path, data)
    return record


def finalize(directory, signed=False, trust_key=None):
    """candidate -> final. Only `stage` changes; the overlay and SBOM bytes are
    reused and the record stays "unsigned" (the publisher's call). `signed`
    (synthetic-key tests; the publisher does not pass it) also writes status
    "signed" and the fingerprint of this checkout's trust key, before anything
    signs the record."""
    record = load_record(directory)
    verify_assets(directory, record, all_assets=True)
    if record["stage"] == "final":
        if signed:
            require(record["signature"]["status"] == "signed",
                    "release %s is already final and %s; prepare a new version"
                    % (record["version"], record["signature"]["status"]))
            fingerprint = load_trust_key(trust_key or default_trust_key())[1]
            require(record["signature"]["key_sha256"] == fingerprint,
                    "release %s is final for key %s; this checkout trusts %s"
                    % (record["version"], record["signature"]["key_sha256"], fingerprint), UNSIGNED)
        return record, False
    record["stage"] = "final"
    if signed:
        # A signature beside a candidate signs other bytes: never carry it forward.
        require(not os.path.exists(os.path.join(directory, RECORD_SIGNATURE)),
                "%s exists beside a candidate record; it is stale. Remove it first" % RECORD_SIGNATURE)
        record["signature"] = {"status": "signed", "record_signature_asset": RECORD_SIGNATURE,
                               "key_sha256": load_trust_key(trust_key or default_trust_key())[1]}
    validate_record(record)
    write_atomic(os.path.join(directory, RECORD), dump_record(record).encode("utf-8"))
    return record, True


def check_signature(directory, record, data, allow_unsigned, trust_key=None):
    """Fail closed. "unsigned" passes only with allow_unsigned (preparation,
    preview, fixtures). "signed" passes only when the record signature verifies
    with this checkout's trust key; allow_unsigned does not relax that. Any other
    status is refused. Returns the trust key for the image check, or None."""
    status = record["signature"]["status"]
    if status == "unsigned":
        require(allow_unsigned,
                "release %s is not signed; customer install/apply refuses it" % record["version"],
                UNSIGNED)
        return None
    require(status == "signed",
            "signature.status is %r: this version verifies only \"signed\"; customer "
            "install/apply refuses it" % status, UNSIGNED)
    trust_key = trust_key or default_trust_key()
    key = load_trust_key(trust_key)
    check_record_signature(directory, record, data, key, trust_key)
    return key


def check(directory, stage="final", version=None, all_assets=False, source=None,
          model=None, tag_only=False, allow_unsigned=False, gate_signature=True, trust_key=None,
          record_only=False, cosign=None):
    """For a signed record the default is BOTH signatures: the record signature,
    then the image signature at the digest. record_only skips only the image."""
    record, data = load_record_bytes(directory)
    if stage != "any":
        require(record["stage"] == stage,
                "release %s is a %s, expected %s" % (record["version"], record["stage"], stage))
    if version is not None:
        require(record["version"] == version,
                "release record is version %s, expected %s" % (record["version"], version))
    verify_assets(directory, record, all_assets)
    if gate_signature:
        key = check_signature(directory, record, data, allow_unsigned, trust_key)
        if key is not None and not record_only:
            check_image_signature(record, key, cosign)
    if source is not None:
        check_source(source, record, tag_only)
    if model is not None:
        check_selection(model, record)
    return record


def download(url, path, missing_ok=False):
    """One published asset, no credential. False when missing_ok and HTTP 404."""
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(FETCH_LIMIT + 1)
    except urllib.error.HTTPError as exc:
        if missing_ok and exc.code == 404:
            return False
        raise ReleaseError(DATA if exc.code == 404 else TOOL,
                           "cannot download %s (HTTP %d). The release may not exist, may be "
                           "a draft, or may predate release sets." % (url, exc.code))
    except (urllib.error.URLError, OSError) as exc:
        if missing_ok and isinstance(getattr(exc, "reason", None), FileNotFoundError):
            return False
        raise ReleaseError(TOOL, "cannot download %s: %s" % (url, getattr(exc, "reason", exc)))
    require(len(data) <= FETCH_LIMIT, "%s is larger than %d bytes" % (url, FETCH_LIMIT))
    write_atomic(path, data)
    return True


def fetch(version, directory, base=RELEASE_DOWNLOAD):
    """Download a published release set into an empty directory, then check it.
    A signed record brings its record signature; check verifies it."""
    require_match(VERSION_RE, version, "--version")
    if os.path.exists(directory):
        require(os.path.isdir(directory) and not os.listdir(directory),
                "%s must be an empty directory or not exist" % directory)
    else:
        os.makedirs(directory)
    for name in (RECORD, OVERLAY, sbom_name(version)):
        download("%s/v%s/%s" % (base, version, name), os.path.join(directory, name))
    if load_record(directory)["signature"]["status"] == "signed":
        # Missing is reported by check (exit 6), not here.
        download("%s/v%s/%s" % (base, version, RECORD_SIGNATURE),
                 os.path.join(directory, RECORD_SIGNATURE), missing_ok=True)
    return check(directory, stage="final", version=version, all_assets=True,
                 gate_signature=False)


def read_model(rendered):
    try:
        if rendered == "-":
            return json.load(sys.stdin)
        with open(rendered) as f:
            return json.load(f)
    except (OSError, ValueError) as exc:
        # The exception text can quote the input; never echo it.
        raise ReleaseError(USAGE, "cannot read the rendered Compose model from %s (%s)"
                           % ("stdin" if rendered == "-" else rendered, type(exc).__name__))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="mode")

    prep = sub.add_parser("prepare", help="publisher: write a candidate release set")
    prep.add_argument("--version", required=True)
    prep.add_argument("--commit", required=True)
    prep.add_argument("--repository", required=True)
    prep.add_argument("--image-repository", required=True)
    prep.add_argument("--digest", required=True)
    prep.add_argument("--sbom", required=True)
    prep.add_argument("--out", required=True)
    prep.add_argument("--source")

    fin = sub.add_parser("finalize", help="publisher: mark a checked candidate final")
    fin.add_argument("--dir", required=True)
    fin.add_argument("--signed", action="store_true",
                     help="also mark the final record signed with this checkout's trust key "
                          "(synthetic-key tests; the publisher does not pass it)")

    chk = sub.add_parser("check", help="consumer: validate a release set")
    chk.add_argument("--dir", default=".")
    chk.add_argument("--stage", choices=("final", "candidate", "any"), default="final")
    chk.add_argument("--version")
    chk.add_argument("--all-assets", action="store_true")
    chk.add_argument("--source")
    chk.add_argument("--allow-unsigned", action="store_true",
                     help="admit an unsigned release (preparation, preview, fixtures only)")
    chk.add_argument("--record-only", action="store_true",
                     help="signed set: check the record signature but not the image signature")
    chk.add_argument("--tag-only", action="store_true",
                     help="with --source: check only that the tag names the record commit")
    how = chk.add_mutually_exclusive_group()
    how.add_argument("--compose", action="store_true")
    how.add_argument("--rendered")
    chk.add_argument("--json", action="store_true")

    fet = sub.add_parser("fetch", help="consumer: download and check a published release set")
    fet.add_argument("--version", required=True)
    fet.add_argument("--dir", required=True)
    fet.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    if args.self_test:
        # The offline checks are in their own script beside this file.
        test = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-release-assets.py")
        return subprocess.run((sys.executable, test)).returncode
    if args.mode is None:
        parser.print_usage(sys.stderr)
        return USAGE
    try:
        if args.mode == "prepare":
            record = prepare(args.version, args.commit, args.repository,
                             args.image_repository, args.digest, args.sbom, args.out,
                             args.source)
            print("release-assets: prepared candidate %s -> %s in %s"
                  % (record["version"], record["image"]["reference"], args.out), file=sys.stderr)
        elif args.mode == "finalize":
            record, changed = finalize(args.dir, args.signed)
            print("release-assets: %s %s is final (signature.status: %s)"
                  % ("marked" if changed else "already", record["version"],
                     record["signature"]["status"]), file=sys.stderr)
        elif args.mode == "fetch":
            record = fetch(args.version, args.dir)
            if args.json:
                print(json.dumps(summary(record), sort_keys=True))
            print("release-assets: fetched final %s %s into %s; integrity checked. "
                  "signature.status: %s (not verified here; check decides)"
                  % (record["version"], record["image"]["reference"], args.dir,
                     record["signature"]["status"]), file=sys.stderr)
        else:
            if args.tag_only and not args.source:
                raise ReleaseError(USAGE, "--tag-only needs --source")
            model = None
            if args.rendered:
                model = read_model(args.rendered)
            elif args.compose:
                model = render_compose()
            record = check(args.dir, args.stage, args.version, args.all_assets,
                           args.source, model, args.tag_only, args.allow_unsigned,
                           record_only=args.record_only)
            if record["signature"]["status"] == "unsigned":
                print("release-assets: %s" % UNVERIFIED, file=sys.stderr)
            else:
                print("release-assets: VERIFIED: %s signature with trust key sha256 %s"
                      % (RECORD, record["signature"]["key_sha256"]), file=sys.stderr)
                print("release-assets: %s" % (
                    "image signature NOT checked here (--record-only)" if args.record_only else
                    "VERIFIED: image signature at %s with the same key" % record["image"]["digest"]),
                    file=sys.stderr)
            if args.json:
                print(json.dumps(summary(record), sort_keys=True))
            print("release-assets: %s %s %s is valid%s (%s)"
                  % (record["stage"], record["version"], record["image"]["reference"],
                     " and selected" if model is not None else "",
                     record["signature"]["status"]), file=sys.stderr)
    except ReleaseError as exc:
        print("release-assets: ERROR — %s" % exc, file=sys.stderr)
        return exc.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
