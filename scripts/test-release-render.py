#!/usr/bin/env python3
"""Render release selections with real Compose and inert fixtures.

Usage: python3 scripts/test-release-render.py

Needs the Docker Compose CLI only. The daemon is made unreachable on purpose:
`docker compose config` resolves the model without it. No registry, image pull,
credential, container, or network is used. Digests are the published v0.5.2
values or inert placeholders; nothing is pulled.

Proves:
  1. REGRESSION EVIDENCE. The v0.5.2 source tag (fixtures copied byte for byte
     from the tag) renders v0.5.1 for both services. Its generated release
     overlay renders the v0.5.2 digest for both.
  2. With the current files and a full customer selection, the release overlay
     changes only services.*.image. State volumes, secret paths, ports, mounts,
     environment and ordered customer overlays render the same.
  3. `release-assets.py check --compose` accepts that selection, and reports a
     missing overlay or a later image override with exit 4.
  4. The release assets contain no customer data or secret values.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "scripts" / "release-assets.py"
OLD_TAG = ROOT / "scripts" / "fixtures" / "release-v0.5.2"
REPO = "ghcr.io/pretorin-ai/compliance-claw"
# The published v0.5.2 release: its tag commit and the digest the release run
# verified (compose.yaml on master pins the same digest).
V052_COMMIT = "ee12a031bd7a019837db4ed28b395ab4761a5d01"
V052_DIGEST = "sha256:b2380d21dfe2265d0de209819875ad1ad25bc7a64f85c6f226b1e09f05b01b09"
V051_DIGEST = "sha256:b40b96523d696fb20963e5aaee61e26c4526c6e91902a56a5354a262562526da"
# Inert: a future version and a digest that names no image.
NEXT_VERSION = "9.9.9"
NEXT_COMMIT = "0123456789abcdef0123456789abcdef01234567"
NEXT_DIGEST = "sha256:" + "9" * 64
CANARY = "CANARY-RELEASE-DO-NOT-PRINT"

failures = 0


def ok(cond, label, detail=""):
    global failures
    print(("PASS  " if cond else "FAIL  ") + label + ("" if cond or not detail else "\n      " + detail))
    failures += 0 if cond else 1


def main():
    docker = shutil.which("docker")
    if docker is None:
        print("SKIP  docker CLI not installed; this test needs the Compose CLI")
        return 1
    base_env = {k: v for k, v in os.environ.items()
                if not k.startswith("COMPOSE_") and k not in ("DOCKER_CONTEXT", "COMPLIANCE_CLAW_SECRET_DIR")}
    base_env["DOCKER_HOST"] = "unix:///nonexistent-cc-release-render.sock"

    with tempfile.TemporaryDirectory(prefix="cc-release-render-") as tmp:
        tmp = Path(tmp).resolve()

        def run(args, cwd, compose_file=None, extra=None):
            env = dict(base_env, **(extra or {}))
            if compose_file is not None:
                env["COMPOSE_FILE"] = compose_file
            p = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
            assert CANARY not in p.stdout + p.stderr or args[:3] == [docker, "compose", "--profile"], \
                "a canary value was printed"
            return p

        def model(cwd, compose_file):
            p = run([docker, "compose", "--profile", "cli", "config", "--format", "json"],
                    cwd, compose_file)
            assert p.returncode == 0, p.stderr
            return json.loads(p.stdout)

        def images(m):
            return {name: m["services"][name]["image"] for name in ("openclaw", "cli")}

        def project(path, files):
            path.mkdir()
            for src, name in files:
                shutil.copyfile(src, path / name)
            (path / "efforts.yaml").write_text(
                "efforts:\n  - name: fixture\n"
                "    system_id: 11111111-1111-4111-8111-111111111111\n"
                "    framework_id: soc2\n    credential_ref: default\n"
                "    targets:\n      - name: fixture\n        url: https://example.com/fixture.git\n")
            (path / ".env").write_text("UNRELATED_SECRET=%s\n" % CANARY)
            return path

        def prepare(out, version, commit, digest):
            sbom = tmp / ("sbom-%s.spdx.json" % version)
            sbom.write_text(json.dumps({"spdxVersion": "SPDX-2.3", "packages": [{"name": "inert"}]}))
            p = run([sys.executable, str(HELPER), "prepare", "--version", version,
                     "--commit", commit, "--repository", "pretorin-ai/compliance-claw",
                     "--image-repository", REPO, "--digest", digest, "--sbom", str(sbom),
                     "--out", str(out)], tmp)
            assert p.returncode == 0, p.stderr
            p = run([sys.executable, str(HELPER), "finalize", "--dir", str(out)], tmp)
            assert p.returncode == 0, p.stderr
            return out

        def install(release, dest):
            for name in ("compose.release.yaml", "compliance-claw-release.json"):
                shutil.copyfile(release / name, dest / name)

        def check(cwd, compose_file):
            return run([sys.executable, str(HELPER), "check", "--compose"], cwd, compose_file)

        # 1. The old tag: the original fault, then the generated selection.
        old = project(tmp / "v0.5.2", [(OLD_TAG / n, n) for n in
                                        ("compose.yaml", "compose.secrets.yaml", "compose.efforts.yaml")])
        if (ROOT / ".git").exists():
            for n in ("compose.yaml", "compose.secrets.yaml", "compose.efforts.yaml"):
                p = subprocess.run(["git", "-C", str(ROOT), "show", "v0.5.2:" + n],
                                   capture_output=True)
                if p.returncode == 0:
                    ok(p.stdout == (OLD_TAG / n).read_bytes(), "fixture %s is the v0.5.2 tag's file" % n)
        old_sel = "compose.yaml:compose.secrets.yaml:compose.efforts.yaml"
        before = images(model(old, old_sel))
        want_old = REPO + ":0.5.1@" + V051_DIGEST
        ok(before == {"openclaw": want_old, "cli": want_old},
           "v0.5.2 source tag alone renders v0.5.1 for both services (the recorded fault)", str(before))
        rel052 = prepare(tmp / "rel-0.5.2", "0.5.2", V052_COMMIT, V052_DIGEST)
        install(rel052, old)
        old_rel_sel = "compose.yaml:compose.release.yaml:compose.secrets.yaml:compose.efforts.yaml"
        after = images(model(old, old_rel_sel))
        want = REPO + ":0.5.2@" + V052_DIGEST
        ok(after == {"openclaw": want, "cli": want},
           "v0.5.2 release overlay renders the v0.5.2 digest for both services", str(after))
        p = check(old, old_rel_sel)
        ok(p.returncode == 0, "check --compose accepts the v0.5.2 release selection", p.stderr)

        # 2. Current files, full ordered selection, plus customer overlays.
        cur = project(tmp / "current", [(ROOT / n, n) for n in
                                        ("compose.yaml", "compose.secrets.yaml", "compose.efforts.yaml")])
        (cur / "targets.yaml").write_text("")
        (cur / "deployment").mkdir()
        (cur / "deployment" / "restored.yaml").write_text(json.dumps({"volumes": {
            k: {"external": True, "name": "cc-release-restored-" + k}
            for k in ("openclaw-state", "pretorin-state")}}))
        (cur / "deployment" / "customer.yaml").write_text(
            "services:\n  openclaw:\n    environment:\n      CUSTOMER_SETTING: kept\n"
            "    ports:\n      - \"127.0.0.1:18790:18790\"\n")
        (cur / "deployment" / "pin-image.yaml").write_text(
            "services:\n  openclaw:\n    image: compliance-claw:local\n")
        rel = prepare(tmp / "rel-next", NEXT_VERSION, NEXT_COMMIT, NEXT_DIGEST)
        install(rel, cur)
        extra = {"COMPLIANCE_CLAW_SECRET_DIR": "./secrets/runtime"}
        customer = "compose.secrets.yaml:compose.efforts.yaml:deployment/customer.yaml:deployment/restored.yaml"
        without = model(cur, "compose.yaml:" + customer)
        with_rel = model(cur, "compose.yaml:compose.release.yaml:" + customer)
        want = REPO + ":" + NEXT_VERSION + "@" + NEXT_DIGEST
        ok(images(with_rel) == {"openclaw": want, "cli": want},
           "release overlay selects the release digest for both services", str(images(with_rel)))
        ok(images(without) == {"openclaw": REPO + ":0.5.2@" + V052_DIGEST, "cli": REPO + ":0.5.2@" + V052_DIGEST},
           "without the overlay, the base pin still applies (default pair unchanged)", str(images(without)))
        meta = with_rel.pop("x-compliance-claw-release", None)
        ok(meta == {"version": NEXT_VERSION, "source_commit": NEXT_COMMIT, "image": want},
           "the rendered model carries the release metadata field", str(meta))
        for name in ("openclaw", "cli"):
            without["services"][name].pop("image")
            with_rel["services"][name].pop("image")
        diff = sorted(k for k in set(without) | set(with_rel) if without.get(k) != with_rel.get(k))
        diff += sorted("services.%s.%s" % (n, k) for n in without["services"]
                       for k in set(without["services"][n]) | set(with_rel["services"][n])
                       if without["services"][n].get(k) != with_rel["services"][n].get(k))
        ok(without == with_rel, "the release overlay changes nothing except services.*.image", str(diff))
        svc = with_rel["services"]["openclaw"]
        targets = {(v.get("source", "").rsplit("/", 1)[-1] if v["type"] == "bind" else v["source"],
                    v["target"], bool(v.get("read_only"))) for v in svc["volumes"]}
        for want_mount in (("openclaw-state", "/home/node/.openclaw", False),
                           ("pretorin-state", "/home/node/.pretorin", False),
                           ("targets", "/workspace/targets", True),
                           ("targets", "/var/lib/compliance-claw/targets", False),
                           ("efforts.yaml", "/etc/compliance-claw/efforts.yaml", True),
                           ("pretorin", "/run/compliance-claw/credentials", True)):
            ok(want_mount in targets, "openclaw keeps mount %s -> %s" % want_mount[:2])
        vols = with_rel["volumes"]
        ok(all(vols[k].get("external") and vols[k]["name"] == "cc-release-restored-" + k
               for k in ("openclaw-state", "pretorin-state")),
           "the later restore overlay still selects the restored state volumes")
        ports = sorted("%s:%s:%s" % (p.get("host_ip"), p.get("published"), p.get("target"))
                       for p in svc["ports"])
        ok(ports == ["127.0.0.1:18789:18789", "127.0.0.1:18790:18790"],
           "ports stay loopback-only and keep the customer port", str(ports))
        ok(svc["environment"].get("CUSTOMER_SETTING") == "kept",
           "the customer overlay's environment is kept")
        secret_dir = str(cur / "secrets" / "runtime")
        ok(all(v["file"].startswith(secret_dir) for v in with_rel["secrets"].values()),
           "secret files still come from COMPLIANCE_CLAW_SECRET_DIR",
           str([v["file"] for v in with_rel["secrets"].values()][:2]))
        ok(svc.get("restart") == "unless-stopped" and not with_rel["services"]["cli"].get("restart"),
           "restart policy unchanged (gateway only)")

        # 3. check --compose on good, missing and overridden selections.
        p = run([sys.executable, str(HELPER), "check", "--compose", "--json"], cur,
                "compose.yaml:compose.release.yaml:" + customer, extra)
        ok(p.returncode == 0 and json.loads(p.stdout)["image_reference"] == want,
           "check --compose accepts the full customer selection", p.stderr)
        p = run([sys.executable, str(HELPER), "check", "--compose"], cur, "compose.yaml:" + customer, extra)
        ok(p.returncode == 4 and "compose.release.yaml" in p.stderr,
           "check --compose exits 4 when the overlay is not selected", p.stderr)
        p = run([sys.executable, str(HELPER), "check", "--compose"], cur,
                "compose.yaml:compose.release.yaml:" + customer + ":deployment/pin-image.yaml", extra)
        ok(p.returncode == 4 and "compliance-claw:local" in p.stderr and "openclaw" in p.stderr,
           "check --compose exits 4 and names a later image override", p.stderr)
        p = run([sys.executable, str(HELPER), "check", "--compose"], cur,
                "compose.yaml:compose.release.yaml:missing.yaml", extra)
        ok(p.returncode == 5, "check --compose exits 5 when Compose cannot render the selection", p.stderr)
        p = run([sys.executable, str(HELPER), "check", "--compose", "--json"], cur,
                "compose.yaml;compose.release.yaml;" + customer.replace(":", ";"),
                dict(extra, COMPOSE_PATH_SEPARATOR=";"))
        ok(p.returncode == 0, "check --compose honours COMPOSE_PATH_SEPARATOR", p.stderr)

        # 4. Nothing customer-specific or secret in the assets.
        for d in (rel, rel052):
            for f in d.iterdir():
                data = f.read_bytes()
                ok(CANARY.encode() not in data and b"efforts" not in data
                   and b"secrets/" not in data and b"11111111-1111" not in data,
                   "%s/%s holds no customer data or secret value" % (d.name, f.name))

    print("\nrelease render: %s" % ("all passed" if failures == 0 else "%d FAILED" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
