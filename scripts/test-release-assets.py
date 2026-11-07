#!/usr/bin/env python3
"""test-release-assets.py — offline checks for scripts/release-assets.py.

    python3 scripts/test-release-assets.py
    python3 scripts/release-assets.py --self-test     (runs this file)

Temporary files only; no daemon, pull or credential. git enables the source
checks, and OpenSSL 1.1.1 or later (pkey -pubcheck) enables the signature
checks; without its tool a group prints SKIP. The image signature checks use a
recording cosign stand-in. CC_TEST_PINNED_COSIGN=1 on Linux amd64 also
downloads the pinned cosign (test_real_cosign).
"""
import base64
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "release-assets.py")
_spec = importlib.util.spec_from_file_location("release_assets", HELPER)
_helper = importlib.util.module_from_spec(_spec)
sys.modules["release_assets"] = _helper
_spec.loader.exec_module(_helper)
from release_assets import (  # the module loaded from its path above
    COSIGN_CACHE, DATA, IMAGE_SIGNATURE_TYPE, OVERLAY, PLATFORM, RECORD, RECORD_SIGNATURE,
    SELECTION, SIGNATURE_LIMIT, SOURCE, TOOL, TRUST_KEY, UNSIGNED, UNVERIFIED, USAGE,
    ReleaseError, check, check_image_payloads, check_image_signature, checkout_root,
    cosign_pins, default_trust_key, dump_record, fetch, finalize, load_record, load_trust_key,
    pinned_cosign, prepare, read_bytes, sbom_name, sha256_bytes, write_atomic)

failures = 0


def ok(cond, label):
    global failures
    print(("PASS  " if cond else "FAIL  ") + label)
    failures += 0 if cond else 1


def refuses(label, code, fn, needle=""):
    global failures
    try:
        fn()
    except ReleaseError as exc:
        passed = exc.code == code and needle in str(exc)
        print(("PASS  " if passed else "FAIL  ") + "%s (exit %d: %s)" % (label, exc.code, exc))
        failures += 0 if passed else 1
        return
    print("FAIL  %s (accepted)" % label)
    failures += 1


def ck(*args, **kw):
    # Fixtures are unsigned; the signature gate has its own tests below.
    kw.setdefault("allow_unsigned", True)
    return check(*args, **kw)


commit = "a" * 40
digest = "sha256:" + "c" * 64
repo = "ghcr.io/pretorin-ai/compliance-claw"
sbom_doc = json.dumps({"spdxVersion": "SPDX-2.3", "packages": [{"name": "x"}]})
ref = repo + ":1.2.3@" + digest

# Fixtures. main() sets these paths. The groups that make the files run first:
# test_prepare makes good, test_finalize makes candset, and
# test_record_signature makes sa.
tmp = src = good = candset = absent = keys = sa = None
key_a = pub_a = key_b = pub_b = fp_a = None


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
    finalize(d, signed=True, trust_key=pub)
    write_atomic(os.path.join(d, RECORD_SIGNATURE), sign(priv, read_bytes(os.path.join(d, RECORD))))
    return d


def rck(*args, **kw):
    # The record signature alone; the image signature has its own tests below.
    return check(*args, record_only=True, **kw)


def img_payload(digest=digest, reference=repo):
    return {"critical": {"identity": {"docker-reference": reference},
                         "image": {"docker-manifest-digest": digest},
                         "type": IMAGE_SIGNATURE_TYPE}, "optional": None}


def resign(name, sig):
    d = os.path.join(tmp, name)
    shutil.copytree(sa, d)
    write_atomic(os.path.join(d, RECORD_SIGNATURE), sig)
    return d


def model(openclaw=ref, cli=ref, **extra):
    services = {}
    if openclaw is not None:
        services["openclaw"] = dict({"image": openclaw, "platform": PLATFORM}, **extra)
    if cli is not None:
        services["cli"] = {"image": cli, "platform": PLATFORM}
    return {"services": services}


def test_prepare():
    """prepare: the candidate set, the overlay, and prepare refusals."""
    record = prep(good)
    ok(record["stage"] == "candidate", "prepare writes a candidate record")
    ok(sorted(os.listdir(good)) == sorted([RECORD, OVERLAY, "sbom-1.2.3.spdx.json"]),
       "prepare writes exactly the record, the overlay and the SBOM")
    prep(good)
    ok(True, "prepare is idempotent for identical inputs")
    overlay = read_bytes(os.path.join(good, OVERLAY)).decode()
    ok(overlay.count('image: "%s"' % ref) == 3, "overlay names the digest reference for both services")
    overlay_keys = sorted(set(re.findall(r"^\s*([A-Za-z_-]+):", overlay, re.M)))
    ok(overlay_keys == sorted(["x-compliance-claw-release", "version", "source_commit",
                       "image", "services", "openclaw", "cli"]),
       "overlay holds image selection and release metadata only (%s)" % overlay_keys)
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


def test_record_checks():
    """check: stages, assets, checksums and record fields."""
    ok(ck(good, stage="candidate", all_assets=True)["stage"] == "candidate",
       "check accepts the candidate with --stage candidate")
    refuses("check refuses a candidate by default (customer flows need final)", DATA,
            lambda: ck(good), "is a candidate")
    refuses("check refuses a version mismatch", DATA,
            lambda: ck(good, stage="any", version="1.2.4"), "expected 1.2.4")

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


def test_finalize():
    """finalize: the publisher's call stays unsigned; --signed needs a key."""
    shutil.copytree(good, candset)
    before = {n: read_bytes(os.path.join(good, n)) for n in (OVERLAY, "sbom-1.2.3.spdx.json")}
    cand = load_record(good)
    rec, changed = finalize(good)
    ok(changed and rec["stage"] == "final", "finalize marks the set final")
    cand["stage"] = "final"
    ok(load_record(good) == cand and cand["signature"]["status"] == "unsigned",
       "finalize changes only the stage field and keeps the record unsigned")
    ok(all(read_bytes(os.path.join(good, n)) == b for n, b in before.items()),
       "finalize reuses the overlay and SBOM bytes")
    ok(finalize(good)[1] is False, "finalize is idempotent on a final set")
    ok(ck(good)["stage"] == "final", "check accepts the final set by default")
    d = variant("final-nosbom", lambda d: os.unlink(os.path.join(d, "sbom-1.2.3.spdx.json")))
    refuses("finalize requires every asset", DATA, lambda: finalize(d), "missing")
    refuses("finalize --signed without a trust key refuses to mark a set signed", UNSIGNED,
            lambda: finalize(candset, signed=True, trust_key=absent), "no Compliance Claw")
    ok(load_record(candset)["stage"] == "candidate", "a refused finalize --signed leaves the candidate unchanged")
    refuses("finalize --signed refuses an unsigned final record", DATA,
            lambda: finalize(variant("final-unsigned", lambda d: None), signed=True, trust_key=absent),
            "already final and unsigned")
    return before


def test_signature_gate():
    """The signature gate fails closed."""
    refuses("check refuses an unsigned release by default (exit 6)", UNSIGNED,
            lambda: check(good), "customer install/apply refuses it")
    d = variant("claimed", edit_record(lambda r: r["signature"].update(status="signed")))
    refuses("a signed status without its key fingerprint is invalid", DATA,
            lambda: check(d, allow_unsigned=True), "signature fields")
    d = variant("claimed-cand", edit_record(lambda r: (r.update(stage="candidate"), r["signature"].update(
        status="signed", key_sha256="0" * 64))))
    refuses("a signed candidate record is invalid", DATA,
            lambda: check(d, stage="any", allow_unsigned=True), "cannot be signed")
    for status in ("foo", "verified"):
        d = variant("status-" + status, edit_record(lambda r, s=status: r["signature"].update(status=s)))
        refuses("check refuses signature.status %r even with --allow-unsigned (exit 6)" % status,
                UNSIGNED, lambda d=d: check(d, allow_unsigned=True), "verifies only")
    refuses("the data checks run before the signature gate", DATA,
            lambda: check(variant("unsigned-bad", append(OVERLAY, "#\n"))), "does not match")


def test_trust_key():
    """The trust key: OpenSSL checks, fingerprint, one PEM block."""
    pub_384 = keypair("p384", "secp384r1")[1]
    ok(load_trust_key(pub_a)[1] == fp_a,
       "the key fingerprint equals sha256 of openssl's DER SPKI export")
    crlf = os.path.join(keys, "a-crlf.pub")
    write_atomic(crlf, read_bytes(pub_a).replace(b"\n", b"\r\n"))
    ok(load_trust_key(crlf)[1] == fp_a and load_trust_key(crlf)[0] == load_trust_key(pub_a)[0],
       "a CRLF copy of the trust key is the same key with the same fingerprint as the LF file")
    refuses("a P-384 trust key is refused", UNSIGNED, lambda: load_trust_key(pub_384), "P-256")
    rsa_key = os.path.join(keys, "rsa.key")
    ossl("genrsa", "-out", rsa_key, "2048")
    ossl("pkey", "-in", rsa_key, "-pubout", "-out", rsa_key + ".pub")
    refuses("an RSA trust key is refused", UNSIGNED, lambda: load_trust_key(rsa_key + ".pub"), "P-256")

    def pem_file(name, body):
        path = os.path.join(keys, name)
        write_atomic(path, b"-----BEGIN PUBLIC KEY-----\n" + body + b"\n-----END PUBLIC KEY-----\n")
        return path
    # TEST DATA: a P-256 SubjectPublicKeyInfo whose point (1, 1) is not on the curve.
    off_curve = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200") + b"\x04" \
        + (1).to_bytes(32, "big") * 2
    refuses("a trust key whose point is not on P-256 is refused by openssl", UNSIGNED,
            lambda: load_trust_key(pem_file("off-curve.pub", base64.encodebytes(off_curve).strip())),
            "not a valid public key")
    refuses("a trust key block that is not base64 is refused by openssl", UNSIGNED,
            lambda: load_trust_key(pem_file("bad-b64.pub", b"!!!!")), "not a valid public key")
    notpem = os.path.join(keys, "not-pem.pub")
    write_atomic(notpem, b"not a key\n")
    refuses("a trust key file without a PEM block is refused", UNSIGNED, lambda: load_trust_key(notpem),
            "exactly one")
    two = os.path.join(keys, "two.pub")
    write_atomic(two, read_bytes(pub_a) + read_bytes(pub_b))
    refuses("a trust key file with two keys is refused", UNSIGNED, lambda: load_trust_key(two),
            "exactly one")
    two_crlf = os.path.join(keys, "two-crlf.pub")
    write_atomic(two_crlf, read_bytes(two).replace(b"\n", b"\r\n"))
    refuses("a CRLF trust key file with two keys is refused", UNSIGNED, lambda: load_trust_key(two_crlf),
            "exactly one")
    priv_too = os.path.join(keys, "pub-and-private.pub")
    write_atomic(priv_too, read_bytes(pub_a) + read_bytes(key_a))
    refuses("a trust key file with a second (private) block is refused", UNSIGNED,
            lambda: load_trust_key(priv_too), "exactly one")


def test_finalize_signed(before):
    """finalize --signed with a synthetic key."""
    fin = os.path.join(tmp, "fin")
    shutil.copytree(candset, fin)
    cand = load_record(fin)
    rec, changed = finalize(fin, signed=True, trust_key=pub_a)
    cand["stage"] = "final"
    cand["signature"] = {"status": "signed", "record_signature_asset": RECORD_SIGNATURE,
                         "key_sha256": fp_a}
    ok(changed and load_record(fin) == cand,
       "finalize --signed writes stage final, status signed and the key fingerprint, nothing else")
    ok(all(read_bytes(os.path.join(fin, n)) == b for n, b in before.items()),
       "the signed final record reuses the overlay and SBOM bytes")
    final_bytes = read_bytes(os.path.join(fin, RECORD))
    ok(finalize(fin, signed=True, trust_key=pub_a)[1] is False
       and read_bytes(os.path.join(fin, RECORD)) == final_bytes,
       "finalize --signed again with the same key leaves the record bytes unchanged")
    refuses("finalize --signed refuses a final record for another key", UNSIGNED,
            lambda: finalize(fin, signed=True, trust_key=pub_b), "this checkout trusts")
    refuses("check refuses a signed record without its signature asset", UNSIGNED,
            lambda: rck(fin, trust_key=pub_a), "is missing")
    stale = os.path.join(tmp, "stale-cand")
    shutil.copytree(candset, stale)
    write_atomic(os.path.join(stale, RECORD_SIGNATURE), b"x\n")
    refuses("finalize --signed refuses a signature beside a candidate record", DATA,
            lambda: finalize(stale, signed=True, trust_key=pub_a), "stale")


def test_record_signature():
    """The record signature over the exact record bytes."""
    assert signed_set("signed-a", key_a, pub_a) == sa
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


    good_sig = read_bytes(os.path.join(sa, RECORD_SIGNATURE))
    flipped = base64.b64decode(good_sig)
    flipped = flipped[:-1] + bytes([flipped[-1] ^ 1])
    other_tag = signed_set("other-tag", key_a, pub_a, version="1.2.4", sbom=sbom_file("1.2.4"))
    other_digest = signed_set("other-digest", key_a, pub_a, digest="sha256:" + "d" * 64)
    for i, (label, sig, needle) in enumerate((
        ("an altered signature", base64.b64encode(flipped) + b"\n", "does not verify"),
        ("a signature that is not base64", b"not base64!\n", "base64"),
        ("a signature that is not DER", base64.b64encode(b"\x30\x02\x02\x00") + b"\n", "does not verify"),
        ("an empty signature", b"", "is empty"),
        ("an oversized signature", b"A" * (SIGNATURE_LIMIT + 4) + b"\n", "larger than"),
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
    return flipped


def test_command_line_trust_key():
    """The command line reads the trust key from its own checkout only."""
    me = HELPER
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
    legacy, explicit = os.path.join(tmp, "cli-final"), os.path.join(tmp, "cli-final-signed")
    shutil.copytree(candset, legacy)
    shutil.copytree(candset, explicit)
    p = subprocess.run((sys.executable, helper, "finalize", "--dir", legacy), capture_output=True, text=True)
    ok(p.returncode == 0 and load_record(legacy)["stage"] == "final"
       and load_record(legacy)["signature"] == {"status": "unsigned",
                                                "record_signature_asset": RECORD_SIGNATURE},
       "finalize without --signed stays unsigned in a checkout that has a trust key (not signed by default)")
    p = subprocess.run((sys.executable, helper, "finalize", "--dir", explicit, "--signed"),
                       capture_output=True, text=True)
    ok(p.returncode == 0 and load_record(explicit)["signature"].get("key_sha256") == fp_a,
       "finalize --signed names the trust key of the helper's own checkout")
    # A key that comes with the download, or sits in the working directory,
    # never replaces the checkout's key.
    evil = signed_set("evil", key_b, pub_b)
    shutil.copyfile(pub_b, os.path.join(evil, os.path.basename(TRUST_KEY)))
    os.makedirs(os.path.join(evil, os.path.dirname(TRUST_KEY)))
    shutil.copyfile(pub_b, os.path.join(evil, TRUST_KEY))
    p = subprocess.run((sys.executable, helper, "check", "--dir", evil, "--record-only"), cwd=evil,
                       capture_output=True, text=True)
    ok(p.returncode == UNSIGNED and "this checkout trusts %s" % fp_a in p.stderr,
       "a key file in the release set or working directory does not replace the checkout's key")
    # An openssl without `pkey -pubcheck` (for example LibreSSL) cannot check the key.
    fake = os.path.join(tmp, "libressl-bin")
    os.makedirs(fake)
    with open(os.path.join(fake, "openssl"), "w") as f:
        f.write("#!/bin/sh\ncase \"$1 $2\" in\n"
                "  'pkey -help') echo 'usage: pkey [-ciphername] [-in file] [-noout]' >&2; exit 1 ;;\n"
                "  version*) echo 'LibreSSL 3.3.6'; exit 0 ;;\nesac\nexit 1\n")
    os.chmod(os.path.join(fake, "openssl"), 0o755)
    p = subprocess.run((sys.executable, helper, "check", "--dir", sa, "--record-only"),
                       env=dict(os.environ, PATH=fake + os.pathsep + os.environ.get("PATH", "")),
                       capture_output=True, text=True)
    ok(p.returncode == TOOL and "OpenSSL 1.1.1" in p.stderr and "LibreSSL 3.3.6" in p.stderr,
       "an openssl without pkey -pubcheck refuses with exit 5 and names the requirement")
    shutil.copyfile(pub_b, os.path.join(co, TRUST_KEY))
    p = subprocess.run((sys.executable, helper, "check", "--dir", sa), capture_output=True, text=True)
    ok(p.returncode == UNSIGNED, "check from a checkout with another trust key refuses (exit 6)")


def test_fetch_signed():
    """fetch brings the record signature of a signed set; check decides."""
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


def test_image_signature(flipped):
    """The image signature, with a recording cosign stand-in."""
    behavior = os.path.join(tmp, "cosign-behavior.json")
    calls = os.path.join(tmp, "cosign-calls.json")
    stub = os.path.join(tmp, "cosign-stub")
    with open(stub, "w") as f:
        f.write("#!%s\nimport base64, hashlib, json, sys\n"
                "b = json.load(open(%r))\n"
                "key = open(sys.argv[sys.argv.index('--key') + 1]).read()\n"
                "der = base64.b64decode(''.join(l for l in key.splitlines() if '-----' not in l))\n"
                "json.dump({'argv': sys.argv[1:], 'key': hashlib.sha256(der).hexdigest()}, open(%r, 'w'))\n"
                "sys.stderr.buffer.write(bytes.fromhex(b['stderr']))\n"
                "sys.stdout.buffer.write(bytes.fromhex(b['stdout']))\n"
                "sys.exit(b.get('code', 0))\n" % (sys.executable, behavior, calls))
    os.chmod(stub, 0o755)

    def cosign_does(code=0, stdout=None, stderr=""):
        if os.path.exists(calls):
            os.unlink(calls)
        if stdout is None:
            stdout = json.dumps([img_payload()])
        # Output goes through hex, so a test can give bytes that are not UTF-8.
        out = {"code": code}
        for name, value in (("stdout", stdout), ("stderr", stderr)):
            out[name] = (value if isinstance(value, bytes) else value.encode()).hex()
        write_atomic(behavior, json.dumps(out).encode())

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
        ("a verified run whose payload image is a string",
         dict(stdout=json.dumps([{"critical": {"identity": {"docker-reference": repo}, "image": digest,
                                               "type": IMAGE_SIGNATURE_TYPE}}])),
         UNSIGNED, "simple-signing object"),
        ("a verified run whose payload identity is a list",
         dict(stdout=json.dumps([{"critical": {"identity": [repo],
                                               "image": {"docker-manifest-digest": digest},
                                               "type": IMAGE_SIGNATURE_TYPE}}])),
         UNSIGNED, "simple-signing object"),
        ("a registry that refuses access",
         dict(code=1, stdout="", stderr="Error: GET https://ghcr.io/...: UNAUTHORIZED: authentication required\n"),
         TOOL, "refused access to the image signature"),
        ("a registry that refuses access (403)",
         dict(code=1, stdout="", stderr="Error: GET https://ghcr.io/...: unexpected status code 403 Forbidden\n"),
         TOOL, "docker login ghcr.io"),
        ("a registry name that does not resolve",
         dict(code=1, stdout="", stderr="Error: Get \"https://ghcr.io/v2/\": dial tcp: lookup ghcr.io: no such host\n"),
         TOOL, "cannot reach or read the registry"),
        ("a registry TLS failure",
         dict(code=1, stdout="", stderr="Error: Get \"https://ghcr.io/v2/\": tls: failed to verify certificate: x509\n"),
         TOOL, "cannot reach or read the registry"),
        ("a registry timeout",
         dict(code=1, stdout="", stderr="Error: Get \"https://ghcr.io/v2/\": dial tcp 1.2.3.4:443: i/o timeout\n"),
         TOOL, "cannot reach or read the registry"),
        # The stdout of a verified run must be exactly one UTF-8 JSON value.
        ("a verified run that prints data after the JSON",
         dict(stdout=json.dumps([img_payload()]) + "\nNOT JSON\n"), UNSIGNED, "no JSON"),
        ("a verified run that prints a second JSON array",
         dict(stdout=json.dumps([img_payload()]) + json.dumps([img_payload()])), UNSIGNED, "no JSON"),
        ("a verified run whose output is not UTF-8", dict(stdout=b"\xff"), UNSIGNED, "no JSON"),
        ("a verified run whose JSON is followed by a byte that is not UTF-8",
         dict(stdout=json.dumps([img_payload()]).encode() + b"\xff"), UNSIGNED, "no JSON"),
        # A failed run keeps its exit code when its message is not UTF-8.
        ("an image signature refusal whose message is not UTF-8",
         dict(code=1, stdout="", stderr=b"Error: no matching signatures \xff\n"), UNSIGNED, "no image signature"),
        ("a registry refusal whose message is not UTF-8",
         dict(code=1, stdout="", stderr=b"Error: UNAUTHORIZED: authentication required \xff\n"),
         TOOL, "refused access to the image signature"),
        ("a network failure whose message is not UTF-8",
         dict(code=1, stdout="", stderr=b"Error: dial tcp 127.0.0.1:9: connect: connection refused \xff\n"),
         TOOL, "cannot reach or read the registry"),
    ):
        cosign_does(**kw)
        refuses("check refuses %s" % label, code,
                lambda: check(sa, trust_key=pub_a, cosign=stub), needle)
        if needle == "cannot reach or read the registry":
            try:
                check(sa, trust_key=pub_a, cosign=stub)
            except ReleaseError as exc:
                ok("public" not in str(exc) and "login" not in str(exc),
                   "%s makes no claim about the package visibility or a login" % label)
    for label, stdout in (("with whitespace around it", "\n  %s \n\n" % json.dumps([img_payload()])),
                          ("across several lines", json.dumps([img_payload()], indent=2) + "\n")):
        cosign_does(stdout=stdout)
        ok(check(sa, trust_key=pub_a, cosign=stub)["version"] == "1.2.3",
           "check accepts a verified payload list %s" % label)
    cosign_does()
    refuses("the record signature is checked before cosign runs", UNSIGNED,
            lambda: check(resign("img-order", base64.b64encode(flipped) + b"\n"),
                          trust_key=pub_a, cosign=stub), "does not verify")
    ok(not os.path.exists(calls), "cosign does not run when the record signature fails")
    rck(sa, trust_key=pub_a)
    ok(not os.path.exists(calls), "--record-only does not run cosign")
    ok(check(good, allow_unsigned=True, cosign=stub)["version"] == "1.2.3" and not os.path.exists(calls),
       "an unsigned fixture admitted by --allow-unsigned runs no image check")
    sleeper = os.path.join(tmp, "cosign-sleeps")
    with open(sleeper, "w") as f:
        f.write("#!/bin/sh\nexec sleep 30\n")
    os.chmod(sleeper, 0o755)
    refuses("a cosign run that does not finish in time is refused (exit 5)", TOOL,
            lambda: check_image_signature(load_record(sa), load_trust_key(pub_a), sleeper, timeout=1),
            "did not finish")
    return stub


def test_pinned_cosign(stub):
    """The pinned cosign: versions.env of the checkout, checksum on download and reuse."""
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


def test_real_cosign():
    """The real pinned cosign (CI asks for it; it downloads): the record
    signature form of cosign sign-blob verifies here, and the openssl
    form verifies in cosign. No registry write, no transparency log."""
    if os.environ.get("CC_TEST_PINNED_COSIGN") != "1":
        print("SKIP  real pinned cosign interop (set CC_TEST_PINNED_COSIGN=1 on Linux amd64)")
    else:
        real = pinned_cosign()
        ok(os.path.dirname(real) == os.path.join(checkout_root(), COSIGN_CACHE),
           "the real pinned cosign downloads and matches COSIGN_SHA256 (%s)" % real)
        env = dict(os.environ, COSIGN_PASSWORD="")
        keydir = os.path.join(tmp, "cosign-keys")
        os.makedirs(keydir)
        subprocess.run((real, "generate-key-pair", "--output-key-prefix", "release"), cwd=keydir,
                       env=env, check=True, capture_output=True)
        cpub = os.path.join(keydir, "release.pub")
        cs = os.path.join(tmp, "cosign-signed")
        prep(cs)
        finalize(cs, signed=True, trust_key=cpub)
        subprocess.run((real, "sign-blob", "--key", os.path.join(keydir, "release.key"),
                        "--tlog-upload=false", "--yes", "--output-signature",
                        os.path.join(cs, RECORD_SIGNATURE), os.path.join(cs, RECORD)),
                       env=env, check=True, capture_output=True)
        ok(rck(cs, trust_key=cpub)["signature"]["key_sha256"] == load_trust_key(cpub)[1],
           "a record signature from cosign sign-blob verifies with the cosign public key")
        p = subprocess.run((real, "verify-blob", "--key", pub_a, "--signature",
                            os.path.join(sa, RECORD_SIGNATURE), "--insecure-ignore-tlog=true",
                            os.path.join(sa, RECORD)), env=env, capture_output=True, text=True)
        ok(p.returncode == 0, "cosign verify-blob accepts the openssl record signature (%s)"
           % p.stderr.strip()[-120:])
        p = subprocess.run((real, "verify-blob", "--key", pub_b, "--signature",
                            os.path.join(sa, RECORD_SIGNATURE), "--insecure-ignore-tlog=true",
                            os.path.join(sa, RECORD)), env=env, capture_output=True, text=True)
        ok(p.returncode != 0, "cosign verify-blob refuses that signature with another key")
        # The payload that cosign signs for an image, without a key or a
        # registry: an explicit digest resolves without a lookup.
        gen_digest = "sha256:" + "e" * 64
        p = subprocess.run((real, "generate", "%s@%s" % (repo, gen_digest)), env=env,
                           capture_output=True, text=True)
        try:
            generated = json.loads(p.stdout)
        except ValueError:
            generated = None
        gen_record = {"image": {"repository": repo, "digest": gen_digest}}
        try:
            check_image_payloads([generated], gen_record)
            good_form = generated["critical"]["type"] == IMAGE_SIGNATURE_TYPE
        except (ReleaseError, TypeError, KeyError):
            good_form = False
        ok(p.returncode == 0 and good_form,
           "the payload that cosign generates for repository@digest passes the payload check")
        refuses("the generated payload does not pass for another digest", UNSIGNED,
                lambda: check_image_payloads([generated], {"image": {"repository": repo,
                                                                    "digest": digest}}),
                "names " + gen_digest)
        # A registry that cannot be reached (a closed loopback port, no egress):
        # the real cosign fails and the helper refuses with exit 5.
        unreachable = json.loads(json.dumps(load_record(sa)))
        unreachable["image"]["repository"] = "127.0.0.1:9/compliance-claw"
        refuses("the real cosign against an unreachable registry is refused (exit 5)", TOOL,
                lambda: check_image_signature(unreachable, load_trust_key(pub_a), real, timeout=300),
                "cannot reach")


def test_selection():
    """Effective selection."""
    ok(ck(good, model=model())["version"] == "1.2.3", "check accepts a model that selects the release")
    refuses("check reports a later overlay that overrides openclaw", SELECTION,
            lambda: ck(good, model=model(openclaw="compliance-claw:local")), "openclaw")
    refuses("check reports a later overlay that overrides cli", SELECTION,
            lambda: ck(good, model=model(cli=repo + ":1.2.2@sha256:" + "e" * 64)), "cli")
    refuses("check reports a model without the cli service", SELECTION,
            lambda: ck(good, model=model(cli=None)), "no cli service")
    refuses("check reports a changed platform", SELECTION,
            lambda: ck(good, model=model(platform="linux/arm64")), "platform")


def test_source():
    """Source binding."""
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
        ok(ck(srcset, stage="any", source=gitdir, tag_only=True)["version"] == "1.2.3",
           "check --source --tag-only accepts the tag without moving HEAD")
        g("tag", "-d", "v1.2.3")
        refuses("check --source --tag-only still refuses a missing tag", SOURCE,
                lambda: ck(srcset, stage="any", source=gitdir, tag_only=True), "no tag")


def test_fetch():
    """fetch: a published set from a release download location (file:// here)."""
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


def test_image_payloads():
    """Image signature payloads: exactly the recorded digest and repository."""
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
        ("a payload that is not an object", ["x"], "simple-signing object"),
        ("a payload without critical", [{"optional": None}], "simple-signing object"),
        ("a payload whose critical is a list", [{"critical": ["image"]}], "simple-signing object"),
        ("a payload whose critical.image is a string",
         [dict(payload(), critical=dict(payload()["critical"], image="sha256:" + "c" * 64))],
         "simple-signing object"),
        ("a payload whose critical.identity is a list",
         [dict(payload(), critical=dict(payload()["critical"], identity=[repo]))], "simple-signing object"),
        ("a payload whose type is missing",
         [dict(payload(), critical={k: v for k, v in payload()["critical"].items() if k != "type"})],
         "(None)"),
        ("a payload list that is an object", payload(), "no verified image signature"),
    ):
        refuses("image check refuses %s" % label, UNSIGNED,
                lambda p=payloads: check_image_payloads(p, final), needle)


def test_command_line():
    """Exit codes through the command line."""
    me = HELPER

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


def openssl_has_pubcheck():
    if shutil.which("openssl") is None:
        return False
    p = subprocess.run(("openssl", "pkey", "-help"), capture_output=True)
    return b"-pubcheck" in p.stdout + p.stderr


def main():
    global tmp, src, good, candset, absent, keys, sa, key_a, pub_a, key_b, pub_b, fp_a
    with tempfile.TemporaryDirectory(prefix="cc-release-assets-") as tmp:
        src = os.path.join(tmp, "in")
        os.makedirs(src)
        good = os.path.join(tmp, "good")
        candset = os.path.join(tmp, "candset")
        absent = os.path.join(tmp, "absent.pub")
        test_prepare()
        test_record_checks()
        before = test_finalize()
        test_signature_gate()

        # Signed sets, with synthetic keys generated here, never at the checkout's key path.
        if not openssl_has_pubcheck():
            print("SKIP  signature checks (needs OpenSSL 1.1.1 or later with pkey -pubcheck on PATH)")
        else:
            keys = os.path.join(tmp, "keys")
            os.makedirs(keys)
            key_a, pub_a = keypair("a")
            key_b, pub_b = keypair("b")
            fp_a = sha256_bytes(ossl("pkey", "-pubin", "-in", pub_a, "-outform", "DER"))
            sa = os.path.join(tmp, "signed-a")
            test_trust_key()
            test_finalize_signed(before)
            flipped = test_record_signature()
            test_command_line_trust_key()
            test_fetch_signed()
            stub = test_image_signature(flipped)
            test_pinned_cosign(stub)
            test_real_cosign()

        test_selection()
        test_source()
        test_fetch()
        test_image_payloads()
        test_command_line()
    print("\nself-test: %s" % ("all passed" if failures == 0 else "%d FAILED" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
