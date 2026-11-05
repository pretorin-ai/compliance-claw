#!/usr/bin/env python3
"""release-assets.py — the one resolver for a Compliance Claw release set.

    release-assets.py prepare  --version X.Y.Z --commit SHA --repository OWNER/NAME
                               --image-repository REPO --digest sha256:HEX
                               --sbom PATH --out DIR [--source DIR]
    release-assets.py finalize --dir DIR [--source DIR] [--json] [--allow-unsigned]
    release-assets.py check    [--dir DIR] [--stage final|candidate|any]
                               [--version X.Y.Z] [--all-assets]
                               [--source DIR [--tag-only]] [--allow-unsigned]
                               [--record-only]
                               [--compose | --rendered FILE|-] [--json]
    release-assets.py fetch    --version X.Y.Z --dir DIR [--json]
    release-assets.py cosign
    release-assets.py --self-test

HOST-ONLY, standard library only. Nothing in the image runs this.

A RELEASE SET is three GitHub Release assets: compliance-claw-release.json (the
record), compose.release.yaml (image selection only) and sbom-X.Y.Z.spdx.json.
A signed set adds compliance-claw-release.json.sig: one line of base64 of the
DER ECDSA P-256 SHA-256 signature over the exact record bytes. Fields,
procedure and placement: docs/releasing.md and docs/image-verification.md.

INVARIANTS
- One resolver. The publisher (release.yml) calls `prepare` and `finalize`.
  Guided setup and the updater use `fetch` and `check` and never parse the
  record themselves.
- One trust key: release-keys/compliance-claw-release.pub in the checkout that
  holds this file. No option, variable or downloaded file supplies a key.
- `finalize` (candidate -> final) writes status "signed" and the key
  fingerprint (sha256 of the DER SPKI) BEFORE the signer signs. It reuses the
  overlay and SBOM bytes, refuses without the trust key, and nothing rewrites
  the final record. `finalize --allow-unsigned` is for test fixtures only.
- `fetch` reads only a PUBLISHED release of the fixed public repository (no
  credential, no draft) into an empty directory, with the record signature of
  a signed set, and checks integrity as `check --stage final --all-assets`
  does. The signature gate is in `check` alone.
- Signatures fail closed (exit 6). "signed" passes only when the record names
  the trust key, the record signature verifies over the record bytes (openssl;
  the record binds the overlay and SBOM hashes), AND the image signature at the
  recorded digest verifies with the same key. The image check runs the cosign
  that versions.env pins (Linux amd64 only; downloaded to a temporary file,
  checksum-checked, cached under .cache/release-tools/, checked again on every
  use) with the host's docker login. `--record-only` skips only the image check
  and says so; customer flows use it only after a full check of the same set.
  `--allow-unsigned` admits "unsigned" only, prints "UNVERIFIED: publisher
  authenticity not checked", and never relaxes a signed check. Preparation,
  update preview and fixtures pass it; customer install and apply never do.
- The rendered Compose model is never printed or written: a legacy `.env`
  selection renders secret values into it. `--rendered -` reads it from stdin.
  A mismatch prints only image references.
- The overlay is generated from the record byte for byte, and `check`
  compares it, so an added key (port, volume, environment) fails. Every value
  in it comes from a pattern-validated field; no YAML parser is needed.
- A customer flow keeps `--stage final` and refuses a candidate.
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
    5  a required tool or download cannot run (git, docker compose, openssl,
       the release download; cosign: not Linux amd64, download, checksum, or
       registry access)
    6  the release is not signed or its signature is not verified (unsigned
       without --allow-unsigned; no trust key or another key; a missing,
       altered, stale or wrong-key record or image signature; an image
       signature for another digest or repository)
"""
import argparse
import base64
import binascii
import hashlib
import json
import os
import platform
import re
import shutil
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
SIGNATURE_STATUSES = ("unsigned", "signed")
# The reviewed Compliance Claw release key, read from THIS checkout only. It is
# never taken from a release set, an option or the environment. It is separate
# from vendor/cosign.pub (the Pretorin CLI key). See release-keys/README.md.
TRUST_KEY = os.path.join("release-keys", "compliance-claw-release.pub")
# DER SubjectPublicKeyInfo header of an uncompressed ECDSA P-256 key.
P256_SPKI_PREFIX = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
P256_P = 2 ** 256 - 2 ** 224 + 2 ** 192 + 2 ** 96 - 1
P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
# The image signature is checked by cosign, pinned in versions.env of the same
# checkout (no second pin), cached in a gitignored directory and checked against
# COSIGN_SHA256 on every use.
COSIGN_PINS = ("COSIGN_VERSION", "COSIGN_ASSET", "COSIGN_SHA256")
COSIGN_DOWNLOAD = "https://github.com/sigstore/cosign/releases/download"
COSIGN_CACHE = os.path.join(".cache", "release-tools")
COSIGN_LIMIT = 256 * 1024 * 1024
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
    require(isinstance(signature, dict) and signature.get("status") in SIGNATURE_STATUSES,
            "signature.status is %r, expected one of %s"
            % (signature.get("status") if isinstance(signature, dict) else signature,
               SIGNATURE_STATUSES))
    if signature["status"] == "signed":
        # finalize fixes these fields BEFORE the signer signs; nothing rewrites them.
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


def load_trust_key(path):
    """(DER SPKI, fingerprint) of the one P-256 public key in a PEM file."""
    try:
        text = read_bytes(path).decode("ascii")
    except OSError as exc:
        raise ReleaseError(UNSIGNED, "no Compliance Claw release trust key at %s (%s). This "
                           "checkout cannot verify a signed release." % (path, exc.strerror))
    except UnicodeDecodeError:
        raise ReleaseError(UNSIGNED, "trust key %s is not PEM text" % path)
    blocks = re.findall(r"-----BEGIN PUBLIC KEY-----\n([A-Za-z0-9+/=\n]+?)\n?-----END PUBLIC KEY-----",
                        text.replace("\r\n", "\n"))
    require(len(blocks) == 1 and text.count("-----BEGIN") == 1,
            "trust key %s must hold exactly one PEM PUBLIC KEY block" % path, UNSIGNED)
    try:
        der = base64.b64decode(blocks[0].replace("\n", ""), validate=True)
    except (binascii.Error, ValueError):
        raise ReleaseError(UNSIGNED, "trust key %s is not valid base64" % path)
    require(len(der) == len(P256_SPKI_PREFIX) + 65 and der.startswith(P256_SPKI_PREFIX)
            and der[len(P256_SPKI_PREFIX)] == 4,
            "trust key %s is not an uncompressed ECDSA P-256 public key" % path, UNSIGNED)
    point = der[len(P256_SPKI_PREFIX) + 1:]
    x, y = int.from_bytes(point[:32], "big"), int.from_bytes(point[32:], "big")
    require(x < P256_P and y < P256_P and (y * y - x ** 3 + 3 * x - P256_B) % P256_P == 0,
            "trust key %s is not a point on P-256" % path, UNSIGNED)
    return der, sha256_bytes(der)


def pem(der):
    body = base64.b64encode(der).decode("ascii")
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return ("-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n" % "\n".join(lines)).encode()


def parse_signature(data, what):
    """One line of base64 (optional final newline) of an ASN.1 DER ECDSA signature."""
    if data.endswith(b"\n"):
        data = data[:-1]
    try:
        sig = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError):
        raise ReleaseError(UNSIGNED, "%s is not one line of base64" % what)
    # SEQUENCE { INTEGER r, INTEGER s }, short-form lengths, at most 72 bytes for P-256.
    ok = 8 <= len(sig) <= 72 and sig[0] == 0x30 and sig[1] == len(sig) - 2 and sig[2] == 0x02
    if ok:
        rlen = sig[3]
        ok = 4 + rlen + 2 <= len(sig) and sig[4 + rlen] == 0x02 and 6 + rlen + sig[5 + rlen] == len(sig)
    require(ok, "%s is not a DER ECDSA signature" % what, UNSIGNED)
    return sig


def openssl_verify(der, sig, data, what):
    """True when `sig` verifies over `data` with the key `der`. openssl is an
    install prerequisite; every input goes through a private temporary file, so
    openssl verifies exactly the bytes and the key checked here."""
    with tempfile.TemporaryDirectory(prefix="cc-verify-") as tmp:
        paths = {}
        for name, blob in (("key.pem", pem(der)), ("sig.der", sig), ("data", data)):
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "wb") as f:
                f.write(blob)
        try:
            p = subprocess.run(("openssl", "dgst", "-sha256", "-verify", paths["key.pem"],
                                "-signature", paths["sig.der"], paths["data"]),
                               capture_output=True, text=True)
        except OSError as exc:
            raise ReleaseError(TOOL, "cannot run openssl to verify %s: %s" % (what, exc.strerror))
    return p.returncode == 0 and "Verified OK" in p.stdout


def check_record_signature(directory, record, data, trust_key):
    """The record signature asset, over the exact record bytes, with the trust key
    from this checkout. A downloaded key is never used."""
    der, fingerprint = load_trust_key(trust_key)
    require(record["signature"]["key_sha256"] == fingerprint,
            "release %s names signing key %s; this checkout trusts %s (%s)"
            % (record["version"], record["signature"]["key_sha256"], fingerprint, trust_key), UNSIGNED)
    path = os.path.join(directory, RECORD_SIGNATURE)
    try:
        raw = read_bytes(path)
    except OSError as exc:
        raise ReleaseError(UNSIGNED, "release %s is marked signed but %s is missing (%s)"
                           % (record["version"], path, exc.strerror))
    sig = parse_signature(raw, RECORD_SIGNATURE)
    require(openssl_verify(der, sig, data, RECORD),
            "%s does not verify over %s with the trust key %s: the signature is altered, "
            "stale or from another key" % (RECORD_SIGNATURE, RECORD, fingerprint), UNSIGNED)
    return fingerprint


def check_image_payloads(payloads, record):
    """Each verified simple-signing payload must name exactly the recorded digest
    and image repository. A signature for another digest or repository fails."""
    image = record["image"]
    require(isinstance(payloads, list) and payloads,
            "no verified image signature for %s@%s" % (image["repository"], image["digest"]), UNSIGNED)
    for payload in payloads:
        critical = payload.get("critical") if isinstance(payload, dict) else None
        critical = critical if isinstance(critical, dict) else {}
        got = ((critical.get("image") or {}).get("docker-manifest-digest"),
               (critical.get("identity") or {}).get("docker-reference"),
               critical.get("type"))
        want = (image["digest"], image["repository"], IMAGE_SIGNATURE_TYPE)
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
REGISTRY_ACCESS_RE = re.compile(
    r"unauthorized|denied|authentication required|no such host|connection refused|"
    r"i/o timeout|tls handshake|network is unreachable|temporary failure", re.I)


def check_image_signature(record, trust_key, cosign=None):
    """The image signature at the recorded digest, with the same trust key as the
    record. cosign does the registry work with the host's docker login; this
    function checks what cosign verified. Every failure refuses."""
    der, fingerprint = load_trust_key(trust_key)
    cosign = cosign or pinned_cosign()
    ref = "%s@%s" % (record["image"]["repository"], record["image"]["digest"])
    # Settings that could point cosign at another trust root or transparency log.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("COSIGN_", "SIGSTORE_", "TUF_"))}
    with tempfile.TemporaryDirectory(prefix="cc-cosign-") as tmp:
        key = os.path.join(tmp, "release.pub")
        with open(key, "wb") as f:
            f.write(pem(der))
        try:
            p = subprocess.run((cosign, "verify", "--key", key, "--insecure-ignore-tlog=true",
                                "--output", "json", ref),
                               capture_output=True, text=True, env=env, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ReleaseError(TOOL, "cannot run cosign %s: %s" % (cosign, getattr(exc, "strerror", None) or exc))
    if p.returncode != 0:
        last = " ".join(p.stderr.strip().splitlines()[-3:])[:400] or "no output"
        if REGISTRY_ACCESS_RE.search(p.stderr):
            raise ReleaseError(TOOL, "cannot read the image signature of %s from the registry (%s). "
                               "The package is not public: log in with docker login ghcr.io."
                               % (ref, last))
        raise ReleaseError(UNSIGNED, "no image signature of %s verifies with the trust key %s (%s)"
                           % (ref, fingerprint, last))
    try:
        payloads = json.JSONDecoder().raw_decode(p.stdout.strip())[0]
    except ValueError:
        raise ReleaseError(UNSIGNED, "cosign verified %s but printed no JSON payload list" % ref)
    check_image_payloads(payloads, record)
    return len(payloads)


def image_access(image_repository, digest, opener=urllib.request.urlopen):
    """Can the recorded digest be pulled WITHOUT a credential? Only a report:
    "anonymous", "login-required", or "unknown: <reason>". No token is sent but
    the registry's own anonymous pull token."""
    if not image_repository.startswith("ghcr.io/"):
        return "unknown: not a ghcr.io repository"
    path = image_repository[len("ghcr.io/"):]
    try:
        with opener("https://ghcr.io/token?scope=repository:%s:pull&service=ghcr.io" % path,
                    timeout=20) as response:
            token = json.loads(response.read(65536).decode("utf-8")).get("token")
        require(isinstance(token, str) and token, "no anonymous token")
        request = urllib.request.Request(
            "https://ghcr.io/v2/%s/manifests/%s" % (path, digest), method="HEAD",
            headers={"Accept": "application/vnd.oci.image.index.v1+json, "
                               "application/vnd.oci.image.manifest.v1+json, "
                               "application/vnd.docker.distribution.manifest.v2+json"})
        request.add_unredirected_header("Authorization", "Bearer " + token)
        with opener(request, timeout=20):
            return "anonymous"
    except urllib.error.HTTPError as exc:
        return "login-required" if exc.code in (401, 403) else "unknown: HTTP %d" % exc.code
    except (urllib.error.URLError, OSError, ValueError, ReleaseError) as exc:
        return "unknown: %s" % (getattr(exc, "reason", None) or type(exc).__name__)


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


def finalize(directory, allow_unsigned=False, trust_key=None, source=None):
    """candidate -> final. The final record names the trust key of this checkout
    and status "signed" BEFORE anything signs it, so the signer signs the bytes
    that publication keeps. --allow-unsigned (fixtures only) writes an unsigned
    final record; the publisher never passes it."""
    record = load_record(directory)
    verify_assets(directory, record, all_assets=True)
    if source is not None:
        # The key that the record names comes from this checkout: it must be the tag.
        check_source(source, record)
    if record["stage"] == "final":
        status = record["signature"]["status"]
        if allow_unsigned:
            require(status == "unsigned", "release %s is already final and %s" % (record["version"], status))
        else:
            require(status == "signed", "release %s is already final but unsigned; prepare a new "
                    "version" % record["version"])
            fingerprint = load_trust_key(trust_key or default_trust_key())[1]
            require(record["signature"]["key_sha256"] == fingerprint,
                    "release %s is final for key %s; this checkout trusts %s"
                    % (record["version"], record["signature"]["key_sha256"], fingerprint), UNSIGNED)
        return record, False
    # A signature beside a candidate signs other bytes: never carry it forward.
    require(not os.path.exists(os.path.join(directory, RECORD_SIGNATURE)),
            "%s exists beside a candidate record; it is stale. Remove it from the draft first"
            % RECORD_SIGNATURE)
    record["stage"] = "final"
    if not allow_unsigned:
        record["signature"] = {"status": "signed", "record_signature_asset": RECORD_SIGNATURE,
                               "key_sha256": load_trust_key(trust_key or default_trust_key())[1]}
    validate_record(record)
    write_atomic(os.path.join(directory, RECORD), dump_record(record).encode("utf-8"))
    return record, True


def check_signature(directory, record, data, allow_unsigned, trust_key=None):
    """Fail closed. "unsigned" passes only with allow_unsigned (preparation,
    preview, fixtures). "signed" passes only when the record signature verifies
    with this checkout's trust key; allow_unsigned does not relax that."""
    if record["signature"]["status"] == "unsigned":
        require(allow_unsigned,
                "release %s is not signed; customer install/apply refuses it" % record["version"],
                UNSIGNED)
        return None
    return check_record_signature(directory, record, data, trust_key or default_trust_key())


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
        check_signature(directory, record, data, allow_unsigned, trust_key)
        if record["signature"]["status"] == "signed" and not record_only:
            check_image_signature(record, trust_key or default_trust_key(), cosign)
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


# --------------------------------------------------------------------------
# self-test: offline, temporary files only. Uses git for the source checks
# and skips them, saying so, if git is absent.
# --------------------------------------------------------------------------
def self_test():
    failures = 0

    def ck(*args, **kw):
        # Fixtures are unsigned; the signature gate has its own tests below.
        kw.setdefault("allow_unsigned", True)
        return check(*args, **kw)

    def ok(cond, label):
        nonlocal failures
        print(("PASS  " if cond else "FAIL  ") + label)
        failures += 0 if cond else 1

    def refuses(label, code, fn, needle=""):
        nonlocal failures
        try:
            fn()
        except ReleaseError as exc:
            good = exc.code == code and needle in str(exc)
            print(("PASS  " if good else "FAIL  ") + "%s (exit %d: %s)" % (label, exc.code, exc))
            failures += 0 if good else 1
            return
        print("FAIL  %s (accepted)" % label)
        failures += 1

    commit = "a" * 40
    other = "b" * 40
    digest = "sha256:" + "c" * 64
    repo = "ghcr.io/pretorin-ai/compliance-claw"
    sbom_doc = json.dumps({"spdxVersion": "SPDX-2.3", "packages": [{"name": "x"}]})

    with tempfile.TemporaryDirectory(prefix="cc-release-assets-") as tmp:
        src = os.path.join(tmp, "in")
        os.makedirs(src)

        def sbom_file(version="1.2.3", body=sbom_doc):
            path = os.path.join(src, sbom_name(version))
            with open(path, "w") as f:
                f.write(body)
            return path

        def prep(out, **kw):
            if "sbom" not in kw:
                kw["sbom"] = sbom_file()
            args = dict(version="1.2.3", commit=commit, repository="pretorin-ai/compliance-claw",
                        image_repository=repo, digest=digest, out=out)
            args.update(kw)
            return prepare(**args)

        good = os.path.join(tmp, "good")
        record = prep(good)
        ok(record["stage"] == "candidate", "prepare writes a candidate record")
        ok(sorted(os.listdir(good)) == sorted([RECORD, OVERLAY, "sbom-1.2.3.spdx.json"]),
           "prepare writes exactly the record, the overlay and the SBOM")
        prep(good)
        ok(True, "prepare is idempotent for identical inputs")
        overlay = read_bytes(os.path.join(good, OVERLAY)).decode()
        ref = repo + ":1.2.3@" + digest
        ok(overlay.count('image: "%s"' % ref) == 3, "overlay names the digest reference for both services")
        keys = sorted(set(re.findall(r"^\s*([A-Za-z_-]+):", overlay, re.M)))
        ok(keys == sorted(["x-compliance-claw-release", "version", "source_commit",
                           "image", "services", "openclaw", "cli"]),
           "overlay holds image selection and release metadata only (%s)" % keys)
        for word in ("environment", "env_file", "volumes", "ports", "secrets", "build"):
            ok(word not in overlay, "overlay carries no %s" % word)

        # Refusals: missing or mismatched source, version, image, asset metadata.
        for label, kw, needle in (
            ("a version without three numbers", {"version": "1.2"}, "--version"),
            ("a v-prefixed version", {"version": "v1.2.3"}, "--version"),
            ("a short commit", {"commit": "abc1234"}, "--commit"),
            ("an uppercase commit", {"commit": "A" * 40}, "--commit"),
            ("a digest without sha256:", {"digest": "c" * 64}, "--digest"),
            ("a truncated digest", {"digest": "sha256:" + "c" * 63}, "--digest"),
            ("an image repository with a tag", {"image_repository": repo + ":1.2.3"}, "--image-repository"),
            ("an empty repository", {"repository": ""}, "--repository"),
        ):
            refuses("prepare refuses " + label, DATA,
                    lambda kw=kw: prep(os.path.join(tmp, "bad"), **kw), needle)
        refuses("prepare refuses an SBOM named for another version", DATA,
                lambda: prep(os.path.join(tmp, "bad"), sbom=sbom_file("1.2.4")), "needs sbom-1.2.3")
        refuses("prepare refuses a missing SBOM", DATA,
                lambda: prep(os.path.join(tmp, "bad"), sbom=os.path.join(tmp, "x", "sbom-1.2.3.spdx.json")),
                "cannot read")
        refuses("prepare refuses an SBOM with no packages", DATA,
                lambda: prep(os.path.join(tmp, "bad"),
                             sbom=sbom_file(body='{"spdxVersion":"SPDX-2.3","packages":[]}')),
                "no packages")
        refuses("prepare refuses an SBOM that is not JSON", DATA,
                lambda: prep(os.path.join(tmp, "bad"), sbom=sbom_file(body="not json")), "not JSON")
        refuses("prepare refuses to replace a set with different bytes", DATA,
                lambda: prep(good, digest="sha256:" + "d" * 64), "refusing to replace")
        ok(not os.path.exists(os.path.join(tmp, "bad", RECORD)), "a refused prepare writes no record")
        ok(load_record(good)["image"]["digest"] == digest, "a refused replacement leaves the set unchanged")

        # check: stages, assets, checksums.
        ok(ck(good, stage="candidate", all_assets=True)["stage"] == "candidate",
           "check accepts the candidate with --stage candidate")
        refuses("check refuses a candidate by default (customer flows need final)", DATA,
                lambda: ck(good), "is a candidate")
        refuses("check refuses a version mismatch", DATA,
                lambda: ck(good, stage="any", version="1.2.4"), "expected 1.2.4")

        def variant(name, mutate):
            d = os.path.join(tmp, name)
            shutil.copytree(good, d)
            mutate(d)
            return d

        def edit_record(fn, canonical=True):
            def mutate(d):
                path = os.path.join(d, RECORD)
                rec = json.loads(read_bytes(path))
                fn(rec)
                text = dump_record(rec) if canonical else json.dumps(rec)
                with open(path, "w") as f:
                    f.write(text)
            return mutate

        def append(name, text):
            def mutate(d):
                with open(os.path.join(d, name), "a") as f:
                    f.write(text)
            return mutate

        d = variant("ports", append(OVERLAY, '    ports: ["0.0.0.0:18789:18789"]\n'))
        refuses("check refuses an overlay with an added key", DATA,
                lambda: ck(d, stage="any"), "does not match")
        d = variant("sbom", append("sbom-1.2.3.spdx.json", " "))
        refuses("check refuses a changed SBOM", DATA, lambda: ck(d, stage="any"), "sbom-1.2.3")
        d = variant("nosbom", lambda d: os.unlink(os.path.join(d, "sbom-1.2.3.spdx.json")))
        ok(ck(d, stage="any")["version"] == "1.2.3", "check accepts a host set without the SBOM")
        refuses("check --all-assets requires the SBOM", DATA,
                lambda: ck(d, stage="any", all_assets=True), "missing")
        d = variant("nooverlay", lambda d: os.unlink(os.path.join(d, OVERLAY)))
        refuses("check always requires the overlay", DATA, lambda: ck(d, stage="any"), "missing")
        d = variant("norecord", lambda d: os.unlink(os.path.join(d, RECORD)))
        refuses("check refuses a missing record", DATA, lambda: ck(d, stage="any"), "cannot read")
        d = variant("noncanonical", edit_record(lambda r: None, canonical=False))
        refuses("check refuses a non-canonical record", DATA, lambda: ck(d, stage="any"), "canonical")
        for name, fn, needle in (
            ("schema", lambda r: r.update(schema=2), "schema"),
            ("schema-bool", lambda r: r.update(schema=True), "schema"),
            ("stage", lambda r: r.update(stage="released"), "stage"),
            ("tag", lambda r: r["source"].update(tag="v1.2.4"), "source.tag"),
            ("commit", lambda r: r["source"].pop("commit"), "source fields"),
            ("ref", lambda r: r["image"].update(reference=repo + ":1.2.3"), "image.reference"),
            ("digest", lambda r: r["image"].update(digest="sha256:" + "d" * 64), "image.reference"),
            ("platform", lambda r: r["image"].update(platform="linux/arm64"), "platform"),
            ("checksum", lambda r: r["assets"][1].update(sha256="0" * 64), "sbom-1.2.3"),
            ("extra-asset", lambda r: r["assets"].append(dict(r["assets"][1])), "exactly"),
            ("no-assets", lambda r: r.update(assets=[]), "exactly"),
            ("status", lambda r: r["signature"].update(status="Signed!"), "signature.status"),
            ("name-type", lambda r: r["assets"][0].update(name=["x"]), "must be strings"),
            ("extra-field", lambda r: r.update(customer="acme"), "record fields"),
        ):
            d = variant("rec-" + name, edit_record(fn))
            refuses("check refuses a record with a bad %s" % name, DATA,
                    lambda d=d: ck(d, stage="any"), needle)

        # finalize --allow-unsigned (fixtures only) changes only the stage.
        candset = os.path.join(tmp, "candset")
        shutil.copytree(good, candset)
        before = {n: read_bytes(os.path.join(good, n)) for n in (OVERLAY, "sbom-1.2.3.spdx.json")}
        cand = load_record(good)
        rec, changed = finalize(good, allow_unsigned=True)
        ok(changed and rec["stage"] == "final", "finalize --allow-unsigned marks the set final")
        cand["stage"] = "final"
        ok(load_record(good) == cand, "finalize --allow-unsigned changes only the stage field")
        ok(all(read_bytes(os.path.join(good, n)) == b for n, b in before.items()),
           "finalize reuses the overlay and SBOM bytes")
        ok(finalize(good, allow_unsigned=True)[1] is False, "finalize is idempotent on a final set")
        ok(ck(good)["stage"] == "final", "check accepts the final set by default")
        d = variant("final-nosbom", lambda d: os.unlink(os.path.join(d, "sbom-1.2.3.spdx.json")))
        refuses("finalize requires every asset", DATA, lambda: finalize(d, allow_unsigned=True), "missing")
        absent = os.path.join(tmp, "absent.pub")
        refuses("finalize without a trust key refuses to mark a set signed", UNSIGNED,
                lambda: finalize(candset, trust_key=absent), "no Compliance Claw")
        ok(load_record(candset)["stage"] == "candidate", "a refused finalize leaves the candidate unchanged")
        refuses("finalize refuses to sign an unsigned final record", DATA,
                lambda: finalize(variant("final-unsigned", lambda d: None), trust_key=absent),
                "already final but unsigned")

        # The signature gate fails closed.
        refuses("check refuses an unsigned release by default (exit 6)", UNSIGNED,
                lambda: check(good), "customer install/apply refuses it")
        d = variant("claimed", edit_record(lambda r: r["signature"].update(status="signed")))
        refuses("a signed status without its key fingerprint is invalid", DATA,
                lambda: check(d, allow_unsigned=True), "signature fields")
        d = variant("claimed-cand", edit_record(lambda r: (r.update(stage="candidate"), r["signature"].update(
            status="signed", key_sha256="0" * 64))))
        refuses("a signed candidate record is invalid", DATA,
                lambda: check(d, stage="any", allow_unsigned=True), "cannot be signed")
        refuses("the data checks run before the signature gate", DATA,
                lambda: check(variant("unsigned-bad", append(OVERLAY, "#\n"))), "does not match")

        # Signed sets, with synthetic keys generated here, never at the checkout's key path.
        if shutil.which("openssl") is None:
            print("SKIP  signature checks (openssl not installed)")
        else:
            keys = os.path.join(tmp, "keys")
            os.makedirs(keys)

            def ossl(*args, data=None):
                return subprocess.run(("openssl",) + args, input=data, check=True,
                                      capture_output=True).stdout

            def keypair(name, curve="prime256v1"):
                priv, pub = os.path.join(keys, name + ".key"), os.path.join(keys, name + ".pub")
                ossl("ecparam", "-name", curve, "-genkey", "-noout", "-out", priv)
                ossl("ec", "-in", priv, "-pubout", "-out", pub)
                return priv, pub

            def sign(priv, data):
                return base64.b64encode(ossl("dgst", "-sha256", "-sign", priv, data=data)) + b"\n"

            def signed_set(name, priv, pub, **kw):
                """finalize with `pub`, then sign the final record with `priv`."""
                d = os.path.join(tmp, name)
                if kw:
                    prep(d, **kw)
                else:
                    shutil.copytree(candset, d)
                finalize(d, trust_key=pub)
                write_atomic(os.path.join(d, RECORD_SIGNATURE), sign(priv, read_bytes(os.path.join(d, RECORD))))
                return d

            key_a, pub_a = keypair("a")
            key_b, pub_b = keypair("b")

            def rck(*args, **kw):
                # The record signature alone; the image signature has its own tests below.
                return check(*args, record_only=True, **kw)

            def img_payload(digest=digest, reference=repo):
                return {"critical": {"identity": {"docker-reference": reference},
                                     "image": {"docker-manifest-digest": digest},
                                     "type": IMAGE_SIGNATURE_TYPE}, "optional": None}
            pub_384 = keypair("p384", "secp384r1")[1]
            fp_a = sha256_bytes(ossl("pkey", "-pubin", "-in", pub_a, "-outform", "DER"))
            ok(load_trust_key(pub_a)[1] == fp_a,
               "the key fingerprint equals sha256 of openssl's DER SPKI export")
            refuses("a P-384 trust key is refused", UNSIGNED, lambda: load_trust_key(pub_384), "P-256")
            two = os.path.join(keys, "two.pub")
            write_atomic(two, read_bytes(pub_a) + read_bytes(pub_b))
            refuses("a trust key file with two keys is refused", UNSIGNED, lambda: load_trust_key(two),
                    "exactly one")

            fin = os.path.join(tmp, "fin")
            shutil.copytree(candset, fin)
            cand = load_record(fin)
            rec, changed = finalize(fin, trust_key=pub_a)
            cand["stage"] = "final"
            cand["signature"] = {"status": "signed", "record_signature_asset": RECORD_SIGNATURE,
                                 "key_sha256": fp_a}
            ok(changed and load_record(fin) == cand,
               "finalize writes stage final, status signed and the key fingerprint, nothing else")
            ok(all(read_bytes(os.path.join(fin, n)) == b for n, b in before.items()),
               "the signed final record reuses the overlay and SBOM bytes")
            final_bytes = read_bytes(os.path.join(fin, RECORD))
            ok(finalize(fin, trust_key=pub_a)[1] is False and read_bytes(os.path.join(fin, RECORD)) == final_bytes,
               "finalize again with the same key leaves the record bytes unchanged")
            refuses("finalize refuses a final record for another key", UNSIGNED,
                    lambda: finalize(fin, trust_key=pub_b), "this checkout trusts")
            refuses("check refuses a signed record without its signature asset", UNSIGNED,
                    lambda: rck(fin, trust_key=pub_a), "is missing")
            stale = os.path.join(tmp, "stale-cand")
            shutil.copytree(candset, stale)
            write_atomic(os.path.join(stale, RECORD_SIGNATURE), b"x\n")
            refuses("finalize refuses a signature beside a candidate record", DATA,
                    lambda: finalize(stale, trust_key=pub_a), "stale")

            sa = signed_set("signed-a", key_a, pub_a)
            ok(rck(sa, trust_key=pub_a, all_assets=True)["signature"]["status"] == "signed",
               "check accepts a correctly signed synthetic set without --allow-unsigned")
            ok(rck(sa, trust_key=pub_a, allow_unsigned=True)["version"] == "1.2.3",
               "--allow-unsigned changes nothing for a verified signed set")
            refuses("check refuses a record signed by another key", UNSIGNED,
                    lambda: rck(signed_set("wrong-key", key_b, pub_a), trust_key=pub_a), "does not verify")
            refuses("check refuses a record that names a key this checkout does not trust", UNSIGNED,
                    lambda: rck(sa, trust_key=pub_b, allow_unsigned=True), "names signing key")
            refuses("check refuses a missing trust key even with --allow-unsigned", UNSIGNED,
                    lambda: check(sa, trust_key=absent, allow_unsigned=True), "no Compliance Claw")

            def resign(name, sig):
                d = os.path.join(tmp, name)
                shutil.copytree(sa, d)
                write_atomic(os.path.join(d, RECORD_SIGNATURE), sig)
                return d

            good_sig = read_bytes(os.path.join(sa, RECORD_SIGNATURE))
            flipped = base64.b64decode(good_sig)
            flipped = flipped[:-1] + bytes([flipped[-1] ^ 1])
            other_tag = signed_set("other-tag", key_a, pub_a, version="1.2.4", sbom=sbom_file("1.2.4"))
            other_digest = signed_set("other-digest", key_a, pub_a, digest="sha256:" + "d" * 64)
            for i, (label, sig, needle) in enumerate((
                ("an altered signature", base64.b64encode(flipped) + b"\n", "does not verify"),
                ("a signature that is not base64", b"not base64!\n", "base64"),
                ("a signature that is not DER", base64.b64encode(b"\x30\x02\x02\x00") + b"\n", "DER"),
                ("an empty signature", b"", "DER"),
                ("a stale signature over the candidate record",
                 sign(key_a, read_bytes(os.path.join(candset, RECORD))), "does not verify"),
                ("a signature for another tag",
                 read_bytes(os.path.join(other_tag, RECORD_SIGNATURE)), "does not verify"),
                ("a signature for another digest",
                 read_bytes(os.path.join(other_digest, RECORD_SIGNATURE)), "does not verify"),
            )):
                d = resign("sig-%d" % i, sig)
                refuses("check refuses %s" % label, UNSIGNED, lambda d=d: rck(d, trust_key=pub_a), needle)

            # The SBOM is covered: its sha256 and size are inside the signed bytes.
            d = resign("sbom-bytes", good_sig)
            append("sbom-1.2.3.spdx.json", " ")(d)
            refuses("check refuses a changed SBOM beside a valid signature", DATA,
                    lambda: rck(d, trust_key=pub_a, all_assets=True), "sbom-1.2.3")
            d2 = resign("sbom-record", good_sig)
            append("sbom-1.2.3.spdx.json", " ")(d2)
            data = read_bytes(os.path.join(d2, "sbom-1.2.3.spdx.json"))
            edit_record(lambda r: r["assets"][1].update(sha256=sha256_bytes(data), size=len(data)))(d2)
            refuses("check refuses a changed SBOM whose new hash was written into the record",
                    UNSIGNED, lambda: rck(d2, trust_key=pub_a, all_assets=True), "does not verify")
            d3 = resign("signed-bad-overlay", good_sig)
            append(OVERLAY, "#\n")(d3)
            refuses("the data checks run before the signature check", DATA,
                    lambda: rck(d3, trust_key=pub_a), "does not match")

            # The command line reads the trust key from its own checkout only.
            me = os.path.abspath(__file__)
            if os.path.exists(default_trust_key()):
                print("SKIP  absent-key command line check (%s exists)" % default_trust_key())
            else:
                p = subprocess.run((sys.executable, me, "check", "--dir", sa, "--allow-unsigned"),
                                   capture_output=True, text=True)
                ok(p.returncode == UNSIGNED and "no Compliance Claw" in p.stderr,
                   "check with no trust key in its checkout refuses a signed set (exit 6)")
            co = os.path.join(tmp, "checkout")
            os.makedirs(os.path.join(co, "scripts"))
            os.makedirs(os.path.join(co, os.path.dirname(TRUST_KEY)))
            helper = os.path.join(co, "scripts", "release-assets.py")
            shutil.copyfile(me, helper)
            shutil.copyfile(pub_a, os.path.join(co, TRUST_KEY))
            p = subprocess.run((sys.executable, helper, "check", "--dir", sa, "--all-assets", "--json",
                                "--record-only"), capture_output=True, text=True)
            ok(p.returncode == 0 and json.loads(p.stdout or "{}").get("key_sha256") == fp_a
               and "VERIFIED" in p.stderr and UNVERIFIED not in p.stderr
               and "image signature NOT checked" in p.stderr,
               "check --record-only from a checkout with the matching key verifies the record "
               "and says the image was not checked")
            p = subprocess.run((sys.executable, helper, "check", "--dir", sa), capture_output=True, text=True)
            ok(p.returncode == TOOL and ("cosign" in p.stderr or "Linux amd64" in p.stderr),
               "check of a signed set without a usable pinned cosign refuses (exit 5), never passes")
            shutil.copyfile(pub_b, os.path.join(co, TRUST_KEY))
            p = subprocess.run((sys.executable, helper, "check", "--dir", sa), capture_output=True, text=True)
            ok(p.returncode == UNSIGNED, "check from a checkout with another trust key refuses (exit 6)")

            # fetch brings the record signature of a signed set; check decides.
            spub = os.path.join(tmp, "signedpub-ok", "v1.2.3")
            shutil.copytree(sa, spub)
            f = os.path.join(tmp, "f-signed")
            fetch("1.2.3", f, "file://" + os.path.dirname(spub))
            ok(sorted(os.listdir(f)) == sorted([RECORD, RECORD_SIGNATURE, OVERLAY, "sbom-1.2.3.spdx.json"])
               and rck(f, trust_key=pub_a)["version"] == "1.2.3",
               "fetch downloads the record signature of a signed set, and it verifies")
            os.unlink(os.path.join(spub, RECORD_SIGNATURE))
            f = os.path.join(tmp, "f-nosig")
            fetch("1.2.3", f, "file://" + os.path.dirname(spub))
            refuses("a published signed set without its signature fails check (exit 6)", UNSIGNED,
                    lambda: rck(f, trust_key=pub_a), "is missing")

            # The image signature: a stand-in cosign records what it was asked
            # and prints what a verified cosign run prints (a JSON payload list).
            behavior = os.path.join(tmp, "cosign-behavior.json")
            calls = os.path.join(tmp, "cosign-calls.json")
            stub = os.path.join(tmp, "cosign-stub")
            with open(stub, "w") as f:
                f.write("#!%s\nimport base64, hashlib, json, sys\n"
                        "b = json.load(open(%r))\n"
                        "key = open(sys.argv[sys.argv.index('--key') + 1]).read()\n"
                        "der = base64.b64decode(''.join(l for l in key.splitlines() if '-----' not in l))\n"
                        "json.dump({'argv': sys.argv[1:], 'key': hashlib.sha256(der).hexdigest()}, open(%r, 'w'))\n"
                        "sys.stderr.write(b.get('stderr', ''))\nsys.stdout.write(b.get('stdout', ''))\n"
                        "sys.exit(b.get('code', 0))\n" % (sys.executable, behavior, calls))
            os.chmod(stub, 0o755)

            def cosign_does(code=0, stdout=None, stderr=""):
                if os.path.exists(calls):
                    os.unlink(calls)
                if stdout is None:
                    stdout = json.dumps([img_payload()])
                write_atomic(behavior, json.dumps({"code": code, "stdout": stdout, "stderr": stderr}).encode())

            cosign_does()
            ok(check(sa, trust_key=pub_a, all_assets=True, cosign=stub)["version"] == "1.2.3",
               "check accepts a signed set whose image signature verifies for the recorded digest")
            seen = json.load(open(calls))
            ok(seen["argv"][:2] == ["verify", "--key"] and seen["argv"][3:] ==
               ["--insecure-ignore-tlog=true", "--output", "json", repo + "@" + digest]
               and seen["key"] == fp_a,
               "cosign verifies repository@digest with the same trust key as the record, no tlog")
            for label, kw, code, needle in (
                ("a missing image signature", dict(code=1, stdout="", stderr="Error: no signatures found\n"),
                 UNSIGNED, "no image signature"),
                ("an image signature from another key",
                 dict(code=1, stdout="", stderr="Error: no matching signatures: invalid signature\n"),
                 UNSIGNED, "no image signature"),
                ("an image signature for another digest",
                 dict(stdout=json.dumps([img_payload(digest="sha256:" + "d" * 64)])), UNSIGNED, "names sha256:d"),
                ("an image signature for another repository",
                 dict(stdout=json.dumps([img_payload(reference="ghcr.io/other/image")])), UNSIGNED, "ghcr.io/other"),
                ("a verified run with no payload", dict(stdout="[]"), UNSIGNED, "no verified image signature"),
                ("a verified run with no JSON", dict(stdout="ok"), UNSIGNED, "no JSON"),
                ("a registry that refuses access",
                 dict(code=1, stdout="", stderr="Error: GET https://ghcr.io/...: UNAUTHORIZED: authentication required\n"),
                 TOOL, "docker login"),
            ):
                cosign_does(**kw)
                refuses("check refuses %s" % label, code,
                        lambda: check(sa, trust_key=pub_a, cosign=stub), needle)
            cosign_does()
            refuses("the record signature is checked before cosign runs", UNSIGNED,
                    lambda: check(resign("img-order", base64.b64encode(flipped) + b"\n"),
                                  trust_key=pub_a, cosign=stub), "does not verify")
            ok(not os.path.exists(calls), "cosign does not run when the record signature fails")
            rck(sa, trust_key=pub_a)
            ok(not os.path.exists(calls), "--record-only does not run cosign")
            ok(check(good, allow_unsigned=True, cosign=stub)["version"] == "1.2.3" and not os.path.exists(calls),
               "an unsigned fixture admitted by --allow-unsigned runs no image check")

            # The pinned cosign: versions.env of the checkout, checksum on download and reuse.
            pins = cosign_pins(checkout_root())
            ok(pins["COSIGN_VERSION"].startswith("v2.") and pins["COSIGN_ASSET"] == "cosign-linux-amd64",
               "the image check reuses the existing versions.env cosign pin (%s)" % pins["COSIGN_VERSION"])
            stub_bytes = read_bytes(stub)
            dl = os.path.join(tmp, "dl")
            os.makedirs(os.path.join(dl, "v9.9.9"))
            write_atomic(os.path.join(dl, "v9.9.9", "cosign-linux-amd64"), stub_bytes)

            def tool_root(name, sha=sha256_bytes(stub_bytes), asset="cosign-linux-amd64", extra=""):
                r = os.path.join(tmp, name)
                os.makedirs(r)
                write_atomic(os.path.join(r, "versions.env"),
                             ("X=1\nCOSIGN_VERSION=v9.9.9\nCOSIGN_ASSET=%s\nCOSIGN_SHA256=%s\n%s"
                              % (asset, sha, extra)).encode())
                return r

            linux = dict(base="file://" + dl, system="Linux", machine="x86_64")
            r1 = tool_root("tools-1")
            path = pinned_cosign(r1, **linux)
            ok(path.startswith(os.path.join(r1, COSIGN_CACHE)) and read_bytes(path) == stub_bytes
               and os.access(path, os.X_OK) and os.listdir(os.path.dirname(path)) == [os.path.basename(path)],
               "pinned cosign is downloaded, checked and cached, with no temporary file left")
            os.rename(os.path.join(dl, "v9.9.9"), os.path.join(dl, "moved"))
            ok(pinned_cosign(r1, **linux) == path, "a cached cosign that matches the pin is reused")
            refuses("a pinned cosign that cannot be downloaded is refused", TOOL,
                    lambda: pinned_cosign(tool_root("tools-nodl"), **linux), "cannot download")
            os.rename(os.path.join(dl, "moved"), os.path.join(dl, "v9.9.9"))
            with open(path, "ab") as f:
                f.write(b"#")
            refuses("a changed cached cosign is refused on reuse", TOOL,
                    lambda: pinned_cosign(r1, **linux), "does not match COSIGN_SHA256")
            r2 = tool_root("tools-2", sha="0" * 64)
            refuses("a cosign download that does not match the pin is refused", TOOL,
                    lambda: pinned_cosign(r2, **linux), "does not match COSIGN_SHA256")
            ok(os.listdir(os.path.join(r2, COSIGN_CACHE)) == [], "a refused download keeps nothing")
            refuses("image verification refuses a macOS host", TOOL,
                    lambda: pinned_cosign(r1, base=linux["base"], system="Darwin", machine="arm64"), "Linux amd64")
            refuses("image verification refuses a Linux arm64 host", TOOL,
                    lambda: pinned_cosign(r1, base=linux["base"], system="Linux", machine="aarch64"), "Linux amd64")
            refuses("a checkout without the cosign pin is refused", TOOL,
                    lambda: pinned_cosign(os.path.join(tmp, "keys"), **linux), "cannot read the cosign pin")
            refuses("a pin for another cosign asset is refused", TOOL,
                    lambda: pinned_cosign(tool_root("tools-3", asset="cosign-darwin-arm64"), **linux),
                    "expected cosign-linux-amd64")

        # Effective selection.
        def model(openclaw=ref, cli=ref, **extra):
            services = {}
            if openclaw is not None:
                services["openclaw"] = dict({"image": openclaw, "platform": PLATFORM}, **extra)
            if cli is not None:
                services["cli"] = {"image": cli, "platform": PLATFORM}
            return {"services": services}

        ok(ck(good, model=model())["version"] == "1.2.3", "check accepts a model that selects the release")
        refuses("check reports a later overlay that overrides openclaw", SELECTION,
                lambda: ck(good, model=model(openclaw="compliance-claw:local")), "openclaw")
        refuses("check reports a later overlay that overrides cli", SELECTION,
                lambda: ck(good, model=model(cli=repo + ":1.2.2@sha256:" + "e" * 64)), "cli")
        refuses("check reports a model without the cli service", SELECTION,
                lambda: ck(good, model=model(cli=None)), "no cli service")
        refuses("check reports a changed platform", SELECTION,
                lambda: ck(good, model=model(platform="linux/arm64")), "platform")

        # Source binding.
        if shutil.which("git") is None:
            print("SKIP  source checks (git not installed)")
        else:
            gitdir = os.path.join(tmp, "src")
            os.makedirs(gitdir)
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

            def g(*args):
                return subprocess.run(("git", "-C", gitdir) + args, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()

            g("init", "-q")
            g("commit", "-q", "--allow-empty", "-m", "one")
            first = g("rev-parse", "HEAD")
            g("commit", "-q", "--allow-empty", "-m", "two")
            second = g("rev-parse", "HEAD")
            srcset = os.path.join(tmp, "srcset")
            prep(srcset, commit=second)
            refuses("prepare --source refuses a missing tag", SOURCE,
                    lambda: prep(os.path.join(tmp, "s2"), commit=second, source=gitdir), "no tag")
            g("tag", "v1.2.3", first)
            refuses("prepare --source refuses a tag at another commit", SOURCE,
                    lambda: prep(os.path.join(tmp, "s2"), commit=second, source=gitdir), first)
            refuses("check --source refuses a tag at another commit", SOURCE,
                    lambda: ck(srcset, stage="any", source=gitdir), first)
            g("tag", "-f", "-a", "-m", "annotated", "v1.2.3", second)
            ok(ck(srcset, stage="any", source=gitdir)["source"]["commit"] == second,
               "check --source accepts an annotated tag and HEAD at the record commit")
            g("checkout", "-q", first)
            refuses("check --source refuses HEAD at another commit", SOURCE,
                    lambda: ck(srcset, stage="any", source=gitdir), "Check out v1.2.3")
            refuses("finalize --source refuses HEAD at another commit (the key comes from HEAD)",
                    SOURCE, lambda: finalize(srcset, allow_unsigned=True, source=gitdir), "Check out v1.2.3")
            ok(load_record(srcset)["stage"] == "candidate", "a refused finalize --source writes nothing")
            ok(ck(srcset, stage="any", source=gitdir, tag_only=True)["version"] == "1.2.3",
               "check --source --tag-only accepts the tag without moving HEAD")
            g("tag", "-d", "v1.2.3")
            refuses("check --source --tag-only still refuses a missing tag", SOURCE,
                    lambda: ck(srcset, stage="any", source=gitdir, tag_only=True), "no tag")

        # fetch: a published set from a release download location (file:// here).
        published = os.path.join(tmp, "published", "v1.2.3")
        shutil.copytree(good, published)
        base = "file://" + os.path.join(tmp, "published")
        fetched = os.path.join(tmp, "fetched")
        ok(fetch("1.2.3", fetched, base)["stage"] == "final", "fetch downloads and checks a final set")
        ok(sorted(os.listdir(fetched)) == sorted([RECORD, OVERLAY, "sbom-1.2.3.spdx.json"]),
           "fetch writes exactly the three assets")
        refuses("fetch refuses a nonempty directory", DATA,
                lambda: fetch("1.2.3", fetched, base), "empty directory")
        # A missing file:// asset is a download failure (exit 5); over HTTPS a 404
        # is exit 1 (no such published set).
        refuses("fetch refuses a release without a set", TOOL,
                lambda: fetch("1.2.4", os.path.join(tmp, "f2"), base), "cannot download")
        cand = os.path.join(tmp, "candpub", "v1.2.3")
        shutil.copytree(os.path.join(tmp, "srcset") if os.path.isdir(os.path.join(tmp, "srcset"))
                        else good, cand)
        if load_record(cand)["stage"] == "candidate":
            refuses("fetch refuses a candidate set", DATA,
                    lambda: fetch("1.2.3", os.path.join(tmp, "f3"), "file://" + os.path.dirname(cand)),
                    "is a candidate")
        tampered = os.path.join(tmp, "tampub", "v1.2.3")
        shutil.copytree(good, tampered)
        append(OVERLAY, "    ports: []\n")(tampered)
        refuses("fetch refuses a tampered overlay", DATA,
                lambda: fetch("1.2.3", os.path.join(tmp, "f4"), "file://" + os.path.dirname(tampered)),
                "does not match")
        signedpub = os.path.join(tmp, "signedpub", "v1.2.3")
        shutil.copytree(good, signedpub)
        edit_record(lambda r: r["signature"].update(status="signed", key_sha256="0" * 64))(signedpub)
        f6 = os.path.join(tmp, "f6")
        ok(fetch("1.2.3", f6, "file://" + os.path.dirname(signedpub))["signature"]["status"] == "signed",
           "fetch checks integrity only and reports the signature status")
        refuses("a signed status alone is not proof: check refuses it", UNSIGNED,
                lambda: check(f6, trust_key=os.path.join(tmp, "absent.pub"), allow_unsigned=True),
                "no Compliance Claw")
        refuses("fetch refuses a malformed version", DATA,
                lambda: fetch("v1.2.3", os.path.join(tmp, "f5"), base), "--version")

        # Image signature payloads: exactly the recorded digest and repository.
        final = load_record(good)

        def payload(digest=digest, reference=repo, kind="cosign container image signature"):
            return {"critical": {"identity": {"docker-reference": reference},
                                 "image": {"docker-manifest-digest": digest}, "type": kind},
                    "optional": None}
        check_image_payloads([payload()], final)
        ok(True, "an image signature payload for the recorded digest and repository is accepted")
        for label, payloads, needle in (
            ("no verified image signature", [], "no verified image signature"),
            ("an image signature for another digest", [payload(digest="sha256:" + "d" * 64)], "names sha256:d"),
            ("an image signature for another repository", [payload(reference="ghcr.io/x/y")], "ghcr.io/x/y"),
            ("an image signature of another type", [payload(kind="attestation")], "attestation"),
            ("one wrong payload among good ones", [payload(), payload(digest="sha256:" + "e" * 64)], "names sha256:e"),
            ("a payload that is not an object", ["x"], "names None"),
        ):
            refuses("image check refuses %s" % label, UNSIGNED,
                    lambda p=payloads: check_image_payloads(p, final), needle)

        # Token-free pull report, with a stand-in registry (no network here).
        class Reply:
            def __init__(self, body=b"{}"):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self, n=-1):
                return self.body

        def registry(token_code=200, manifest_code=200):
            seen = []

            def opener(request, timeout=None):
                url = request if isinstance(request, str) else request.full_url
                seen.append(request)
                code = token_code if "/token?" in url else manifest_code
                if code != 200:
                    raise urllib.error.HTTPError(url, code, "x", {}, None)
                return Reply(b'{"token": "anon"}')
            return opener, seen

        opener, seen = registry()
        ok(image_access(repo, digest, opener) == "anonymous"
           and seen[1].get_method() == "HEAD" and digest in seen[1].full_url,
           "the pull report says anonymous when the registry serves the digest without a login")
        ok(image_access(repo, digest, registry(token_code=401)[0]) == "login-required",
           "the pull report says login-required when the anonymous token is refused")
        ok(image_access(repo, digest, registry(manifest_code=403)[0]) == "login-required",
           "the pull report says login-required when the digest is refused")
        ok(image_access(repo, digest, registry(manifest_code=404)[0]).startswith("unknown: HTTP 404"),
           "the pull report does not call a missing digest a login problem")
        ok(image_access("registry.example/x/y", digest).startswith("unknown"),
           "the pull report makes no claim for another registry")

        # Exit codes through the command line.
        me = os.path.abspath(__file__)

        def cli(*args):
            return subprocess.run((sys.executable, me) + args, capture_output=True, text=True)

        p = cli("check", "--dir", good, "--json", "--allow-unsigned")
        ok(p.returncode == 0 and json.loads(p.stdout)["image_reference"] == ref
           and UNVERIFIED in p.stderr,
           "check --allow-unsigned --json prints the summary and the UNVERIFIED line")
        p = cli("check", "--dir", good)
        ok(p.returncode == UNSIGNED and "customer install/apply refuses it" in p.stderr,
           "check exits 6 on an unsigned release without --allow-unsigned")
        rendered = os.path.join(tmp, "rendered.json")
        with open(rendered, "w") as f:
            json.dump(model(openclaw="compliance-claw:local"), f)
        ok(cli("check", "--dir", good, "--rendered", rendered, "--allow-unsigned").returncode == SELECTION,
           "check --rendered exits 4 on an override")
        secret_model = model(openclaw="compliance-claw:local")
        secret_model["services"]["openclaw"]["environment"] = {"X": "CANARY-MODEL-SECRET"}
        p = subprocess.run((sys.executable, me, "check", "--dir", good, "--rendered", "-", "--allow-unsigned"),
                           input=json.dumps(secret_model), capture_output=True, text=True)
        ok(p.returncode == SELECTION and "CANARY-MODEL-SECRET" not in p.stdout + p.stderr
           and "compliance-claw:local" in p.stderr and ref in p.stderr,
           "check --rendered - reads stdin and prints only image references on exit 4")
        p = subprocess.run((sys.executable, me, "check", "--dir", good, "--rendered", "-", "--allow-unsigned"),
                           input=json.dumps(model()), capture_output=True, text=True)
        ok(p.returncode == 0, "check --rendered - accepts a matching model from stdin")
        p = subprocess.run((sys.executable, me, "check", "--dir", good, "--rendered", "-", "--allow-unsigned"),
                           input='{"secret": "CANARY-MODEL-SECRET"', capture_output=True, text=True)
        ok(p.returncode == USAGE and "CANARY-MODEL-SECRET" not in p.stderr,
           "an unreadable model exits 2 without echoing it")
        ok(cli("check", "--dir", good, "--tag-only").returncode == USAGE, "--tag-only without --source exits 2")
        ok(cli("check", "--dir", os.path.join(tmp, "nowhere")).returncode == DATA,
           "check exits 1 on a missing set")
        ok(cli("check", "--stage", "released").returncode == USAGE, "a bad option exits 2")
        ok(cli("check", "--compose", "--rendered", rendered).returncode == USAGE,
           "--compose and --rendered together exit 2")

    print("\nself-test: %s" % ("all passed" if failures == 0 else "%d FAILED" % failures))
    return 0 if failures == 0 else 1


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

    fin = sub.add_parser("finalize", help="publisher: write the final record that the signer signs")
    fin.add_argument("--dir", required=True)
    fin.add_argument("--allow-unsigned", action="store_true",
                     help="write an unsigned final record (test fixtures only)")
    fin.add_argument("--source")
    fin.add_argument("--json", action="store_true")

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

    sub.add_parser("cosign", help="download or re-check the pinned cosign; print its path")

    fet = sub.add_parser("fetch", help="consumer: download and check a published release set")
    fet.add_argument("--version", required=True)
    fet.add_argument("--dir", required=True)
    fet.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
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
            record, changed = finalize(args.dir, args.allow_unsigned, source=args.source)
            if args.json:
                print(json.dumps(summary(record), sort_keys=True))
            print("release-assets: %s %s is final (%s%s)"
                  % ("marked" if changed else "already", record["version"],
                     record["signature"]["status"],
                     ", key sha256 %s" % record["signature"]["key_sha256"]
                     if "key_sha256" in record["signature"] else ""), file=sys.stderr)
        elif args.mode == "cosign":
            print(pinned_cosign())
        elif args.mode == "fetch":
            record = fetch(args.version, args.dir)
            access = image_access(record["image"]["repository"], record["image"]["digest"])
            if args.json:
                print(json.dumps(dict(summary(record), image_access=access), sort_keys=True))
            print("release-assets: fetched final %s %s into %s; integrity checked. "
                  "signature.status: %s (not verified here; check decides). "
                  "Image pull without a login: %s"
                  % (record["version"], record["image"]["reference"], args.dir,
                     record["signature"]["status"], access), file=sys.stderr)
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
