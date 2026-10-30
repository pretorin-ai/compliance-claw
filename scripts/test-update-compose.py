#!/usr/bin/env python3
"""Test host verification with real Compose and synthetic local containers.

Usage: python3 scripts/test-update-compose.py LOCAL_IMAGE OTHER_LOCAL_IMAGE
       python3 scripts/test-update-compose.py --selection-only (no daemon needed)
Uses no registry, credentials, ports, or OpenClaw runtime. Git and image pulls
are stubbed; Compose selection, startup, wait, and inspection are real.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import re
import time
import subprocess
import sys
import tempfile


def selection_regression(root, docker, docker_env):
    """Real Compose and callers; unreachable daemon, no credentials or services."""
    with tempfile.TemporaryDirectory(prefix="cc-selection-") as tmp:
        fixture = Path(tmp)
        shutil.copytree(root / "scripts", fixture / "scripts")
        for name in ("compose.yaml", "compose.secrets.yaml", "compose.efforts.yaml",
                     "compose.build.yaml", ".env.example", "versions.env"):
            shutil.copyfile(root / name, fixture / name)
        (fixture / "efforts.yaml").write_text('''efforts:
  - name: fixture
    system_id: 11111111-1111-4111-8111-111111111111
    framework_id: soc2
    credential_ref: default
    targets:
      - name: fixture
        url: https://example.com/fixture.git
''')
        (fixture / "deployment").mkdir()
        overlay = fixture / "deployment/recovered.yaml"
        overlay.write_text(json.dumps({"volumes": {
            k: {"external": True, "name": "cc-selection-restored-" + k}
            for k in ("openclaw-state", "pretorin-state")}}))
        saved = ("COMPOSE_FILE='./compose.yaml;" + str(fixture / "compose.secrets.yaml") +
                 ";./compose.efforts.yaml;deployment/recovered.yaml'\n"
                 "COMPOSE_PATH_SEPARATOR=;\nCOMPOSE_PROJECT_NAME=cc-selection-saved\nCOMPOSE_PROFILES=cli\n"
                 "COMPLIANCE_CLAW_SECRET_DIR='./saved secrets=literal'\n"
                 "UNRELATED_SECRET=CANARY-DO-NOT-PRINT\n")
        (fixture / ".env").write_text(saved)
        env = {**docker_env, "DOCKER_HOST": "unix:///nonexistent-cc-selection.sock"}
        env.pop("DOCKER_CONTEXT", None)

        def run(*args, extra=None, ok=True):
            p = subprocess.run(args, cwd=fixture, env={**env, **(extra or {})},
                               capture_output=True, text=True)
            output = p.stdout + p.stderr
            assert (p.returncode == 0) == ok, output
            assert "CANARY-DO-NOT-PRINT" not in output, output
            return p

        def model(extra=None):
            return json.loads(run(docker, "compose", "--profile", "*", "config",
                                  "--format", "json", extra=extra).stdout)

        run("bash", "-c", '. scripts/compose-selection.sh; compose_resolve_selection; '
            'test -z "${UNRELATED_SECRET+x}" && test "$COMPOSE_PROFILES" = cli')
        run("bash", "scripts/clawctl", "plan")
        run("bash", "scripts/init-file-secrets.sh")
        run("bash", "scripts/clawctl", "credential", "add", "fixture-key")
        secret = fixture / "saved secrets=literal"
        assert (secret / "pretorin/fixture-key").exists()
        assert not (fixture / "secrets").exists()
        before = (secret / "openclaw-gateway-token").read_bytes()
        run("bash", "scripts/init-file-secrets.sh")
        assert before == (secret / "openclaw-gateway-token").read_bytes()
        config = model()
        assert config["name"] == "cc-selection-saved"
        assert all(v["external"] for v in config["volumes"].values())
        assert all(v["name"].startswith("cc-selection-restored-") for v in config["volumes"].values())
        assert all(str(secret) in v["file"] for v in config["secrets"].values())
        assert config["services"]["openclaw"]["image"] == config["services"]["cli"]["image"]

        override = {"COMPLIANCE_CLAW_SECRET_DIR": "./override secrets", "COMPOSE_PROJECT_NAME": "cc-selection-override",
                    "COMPOSE_PATH_SEPARATOR": ":", "COMPOSE_FILE": "compose.yaml:compose.secrets.yaml:compose.efforts.yaml"}
        run("bash", "scripts/init-file-secrets.sh", extra=override)
        run("bash", "scripts/clawctl", "plan", extra=override)
        config = model(override)
        assert config["name"] == "cc-selection-override"
        assert all(str(fixture / "override secrets") in v["file"] for v in config["secrets"].values())
        literal = "./literal $(touch SHOULD_NOT_EXIST)"
        run("bash", "scripts/init-file-secrets.sh", extra={"COMPLIANCE_CLAW_SECRET_DIR": literal})
        assert (fixture / literal / "openclaw-gateway-token").exists()
        assert not (fixture / "SHOULD_NOT_EXIST").exists()
        # A customer overlay with the same basename is not the repository secret overlay.
        (fixture / "deployment/compose.secrets.yaml").write_text("services: {}\n")
        p = run("bash", "scripts/clawctl", "plan", extra={"COMPOSE_FILE": "compose.yaml;deployment/compose.secrets.yaml"}, ok=False)
        assert "not on the file-backed" in p.stderr
        # Saved build mode must refuse before Git fetch, daemon access or pull.
        (fixture / ".env").write_text(saved.replace(";deployment/recovered.yaml", ";./compose.build.yaml"))
        p = run("bash", "scripts/update.sh", ok=False)
        assert "local build overlay" in p.stderr
        # Missing saved overlay refuses all writers, without creating a fallback secret path.
        (fixture / ".env").write_text(saved)
        overlay.unlink()
        for command in (("scripts/clawctl", "credential", "add", "never"),
                        ("scripts/init-file-secrets.sh",), ("scripts/bootstrap.sh", "--targets-only"),
                        ("scripts/update.sh",)):
            p = run("bash", *command, ok=False)
            assert "cannot resolve deployment settings" in p.stderr
        assert not (secret / "pretorin/never").exists()
        assert not (fixture / "secrets").exists()
        # Data-only commands must still work when native Compose resolution cannot.
        run("bash", "scripts/clawctl", "--help")
        run("bash", "scripts/clawctl", "validate", "--schema-only")
        print("PASS: saved/explicit native selection, recovered volumes, secret initialization, caller refusals and schema-only independence")


def release_repo(base, root, docker_env, image, populate):
    """Build a Git checkout with a v0.6.0 tag on a local bare origin.

    The checkout stays one commit behind the tag. The release helper is the
    fixture from test-update.py: it stands in for the release-asset interface
    and does not prove the published release assets.
    """
    spec = importlib.util.spec_from_file_location("test_update", root / "scripts/test-update.py")
    fixture_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture_module)
    repo = base / "repo"
    repo.mkdir()
    populate(repo)
    (repo / ".gitignore").write_text(".env\nsecrets/\nefforts.yaml\ncompose.release.yaml*\ndeployment/\n")
    (repo / "scripts/release-assets.py").write_text(fixture_module.HELPER)
    git_env = {**docker_env, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}

    def git(*args, cwd=repo):
        return subprocess.run(["git", *args], cwd=cwd, env=git_env, check=True,
                              capture_output=True, text=True).stdout.strip()

    git("init", "-q", "-b", "master")
    git("add", "-A")
    git("commit", "-q", "-m", "current")
    old = git("rev-parse", "HEAD")
    (repo / "docs").mkdir(exist_ok=True)
    (repo / "docs/release-note.txt").write_text("release\n")
    git("add", "-A")
    git("commit", "-q", "-m", "release")
    new = git("rev-parse", "HEAD")
    git("tag", "v0.6.0")
    git("clone", "-q", "--bare", str(repo), str(base / "origin.git"), cwd=base)
    git("remote", "add", "origin", str(base / "origin.git"))
    git("tag", "-d", "v0.6.0")
    git("reset", "-q", "--hard", old)

    assets = base / "releases/v0.6.0"
    assets.mkdir(parents=True)
    overlay = ("x-compliance-claw-release: {version: 0.6.0}\n"
               f"services:\n  openclaw:\n    image: {image}\n  cli:\n    image: {image}\n")
    (assets / "compose.release.yaml").write_text(overlay)
    (assets / "compliance-claw-release.json").write_text(json.dumps({
        "version": "0.6.0", "source_commit": new, "image": image,
        "overlay_sha256": hashlib.sha256(overlay.encode()).hexdigest(),
        "signature": "unsigned", "final": True}))
    # Release-route files are deployment files; the release reserves their place.
    (repo / "compose.release.yaml").write_text("services: {}\n")
    env = {**git_env, "CC_FIXTURE_RELEASES": str(assets.parent), "TMPDIR": str(base)}
    return repo, git, old, new, env


def release_regression(root, docker, docker_env):
    """Real Compose renders the release route; real Git; unreachable daemon."""
    new_image = "ghcr.io/pretorin-ai/compliance-claw:0.6.0@sha256:" + "2" * 64

    def populate(repo):
        shutil.copytree(root / "scripts", repo / "scripts")
        for name in ("compose.yaml", "compose.secrets.yaml", "compose.efforts.yaml",
                     "compose.build.yaml", ".env.example", "versions.env"):
            shutil.copyfile(root / name, repo / name)

    with tempfile.TemporaryDirectory(prefix="cc-release-") as tmp:
        base = Path(tmp).resolve()
        repo, git, old, new, git_env = release_repo(base, root, docker_env, new_image, populate)

        # Saved selection: placeholder release overlay, separator ';', a secret
        # directory with spaces, and recovered external volumes last.
        (repo / "efforts.yaml").write_text((root / "efforts.example.yaml").read_text())
        (repo / "deployment").mkdir()
        recovered = repo / "deployment/recovered.yaml"
        recovered.write_text(json.dumps({"volumes": {
            k: {"external": True, "name": "cc-release-restored-" + k}
            for k in ("openclaw-state", "pretorin-state")}}))
        (repo / ".env").write_text(
            "COMPOSE_FILE='./compose.yaml;compose.release.yaml;./compose.secrets.yaml;"
            "./compose.efforts.yaml;deployment/recovered.yaml'\n"
            "COMPOSE_PATH_SEPARATOR=;\nCOMPOSE_PROJECT_NAME=cc-release-saved\n"
            "COMPLIANCE_CLAW_SECRET_DIR='./saved secrets'\nUNRELATED_SECRET=CANARY-DO-NOT-PRINT\n")
        env = {**git_env, "DOCKER_HOST": "unix:///nonexistent-cc-release.sock"}
        env.pop("DOCKER_CONTEXT", None)
        subprocess.run(["bash", "scripts/init-file-secrets.sh"], cwd=repo, env=env, check=True,
                       capture_output=True)

        def state():
            files = sorted((str(p.relative_to(repo)), p.read_bytes() if p.is_file() else b"")
                           for p in repo.rglob("*") if ".git" not in p.parts)
            return git("rev-parse", "HEAD"), git("for-each-ref"), files

        def update(*args, rc):
            p = subprocess.run(["bash", "scripts/update.sh", "--release", "v0.6.0", *args],
                               cwd=repo, env=env, capture_output=True, text=True)
            output = p.stdout + p.stderr
            assert p.returncode == rc, output
            assert "CANARY-DO-NOT-PRINT" not in output, output
            assert not list(base.glob("cc-release.*")), "temporary cache left behind"
            return output

        before = state()
        output = update("--preview", rc=0)
        for text in (new_image, "cc-release-restored-openclaw-state", "cc-release-saved",
                     "./compose.yaml;compose.release.yaml;./compose.secrets.yaml;./compose.efforts.yaml;"
                     "deployment/recovered.yaml", "no blockers"):
            assert text in output, (text, output)
        assert state() == before
        # Apply cannot pull without a daemon: it stops before any change.
        output = update(rc=1)
        assert "Nothing was changed" in output, output
        assert state() == before
        # A later customer image override is a custom selection.
        (repo / "deployment/custom.yaml").write_text(
            "services:\n  openclaw:\n    image: registry.example/custom:1\n")
        (repo / ".env").write_text((repo / ".env").read_text().replace(
            "deployment/recovered.yaml'", "deployment/recovered.yaml;deployment/custom.yaml'"))
        output = update("--preview", rc=2)
        assert "custom selection" in output, output
        print("PASS: release preview with real Compose keeps ordered overlays, recovered volumes,"
              " and the secret directory; changes nothing; refuses a custom image")


def release_apply_regression(root, docker, docker_env, images, image_ids):
    """Apply a release with real Compose, real Git and synthetic containers.

    The gateway uses restored external volumes, a customer overlay setting and a
    customer secret path. Pulls are stubbed; both images are already local.
    """
    def populate(repo):
        (repo / "scripts").mkdir()
        for name in ("update.sh", "compose-selection.sh", "init-file-secrets.sh"):
            shutil.copyfile(root / "scripts" / name, repo / "scripts" / name)
        shutil.copyfile(root / "versions.env", repo / "versions.env")
        service = {"image": images[1], "network_mode": "none", "user": "0:0", "entrypoint": ["sh", "-c"],
                   "volumes": ["openclaw-state:/fixture-openclaw", "pretorin-state:/fixture-pretorin"]}
        (repo / "compose.yaml").write_text(json.dumps({"services": {
            "openclaw": {**service, "command": ["touch /tmp/ready; exec sleep infinity"],
                         "healthcheck": {"test": ["CMD", "test", "-f", "/tmp/ready"],
                                         "interval": "1s", "timeout": "1s", "retries": 3}},
            "cli": {**service, "profiles": ["cli"], "entrypoint": [], "command": ["true"]},
        }, "volumes": {"openclaw-state": {}, "pretorin-state": {}}}))

    with tempfile.TemporaryDirectory(prefix="cc-release-apply-") as tmp:
        base = Path(tmp).resolve()
        repo, git, old, new, env = release_repo(base, root, docker_env, images[0], populate)
        project = "cc-release-" + base.name[len("cc-release-apply-"):].lower()
        restored = {k: project + "-restored-" + k for k in ("openclaw-state", "pretorin-state")}
        (repo / "deployment").mkdir()
        (repo / "custom secrets").mkdir()
        (repo / "custom secrets/token").write_text("CANARY-CUSTOM-SECRET")
        (repo / "deployment/customer.yaml").write_text(json.dumps({
            "services": {"openclaw": {"environment": {"CUSTOMER_SETTING": "kept"},
                                      "secrets": ["customer_token"]}},
            "secrets": {"customer_token": {"file": "./custom secrets/token"}},
            "volumes": {k: {"external": True, "name": v} for k, v in restored.items()}}))
        (repo / "bin").mkdir()
        (repo / "bin/docker").write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
# Both images are local; no registry call is part of this test.
if args[:1] == ["compose"] and "pull" in args:
    sys.exit(0)
if args[:3] == ["compose", "up", "-d"]:
    pos = args.index("--wait-timeout")
    assert args[pos + 1] == "720", args
    args[pos + 1] = "60"
os.execv(os.environ["FIXTURE_DOCKER"], [os.environ["FIXTURE_DOCKER"], *args])
''')
        (repo / "bin/docker").chmod(0o700)
        env = {**env, "COMPOSE_PROJECT_NAME": project, "COMPOSE_PROFILES": "cli",
               "COMPOSE_FILE": "compose.yaml:compose.release.yaml:deployment/customer.yaml",
               "PATH": str(repo / "bin") + os.pathsep + docker_env["PATH"], "FIXTURE_DOCKER": docker}

        def run(*args, check=True):
            p = subprocess.run(args, cwd=repo, env=env, capture_output=True, text=True)
            assert not check or p.returncode == 0, p.stdout + p.stderr
            return p

        def compose(*args):
            return run(docker, "compose", *args).stdout.strip()

        def update(*args, rc=0):
            p = run("bash", "scripts/update.sh", "--release", "v0.6.0", *args, check=False)
            output = p.stdout + p.stderr
            assert p.returncode == rc, output
            assert "CANARY-CUSTOM-SECRET" not in output, output
            return output

        try:
            for name in restored.values():
                run(docker, "volume", "create", name)
            compose("up", "-d", "--wait", "--wait-timeout", "60", "openclaw")
            compose("run", "--rm", "-T", "cli", "sh", "-c",
                    "printf config > /fixture-openclaw/config; printf memory > /fixture-openclaw/memory; "
                    "printf mcp > /fixture-openclaw/external-mcp; printf cli > /fixture-pretorin/active-cli")
            old_cid = compose("ps", "-q", "openclaw")
            containers = run(docker, "ps", "-aq", "--filter", "label=com.docker.compose.project=" + project).stdout

            output = update("--preview")
            assert compose("ps", "-q", "openclaw") == old_cid, output
            assert run(docker, "inspect", "--format", "{{.Image}}", old_cid).stdout.strip() == image_ids[1]
            assert run(docker, "ps", "-aq", "--filter", "label=com.docker.compose.project=" + project).stdout == containers
            assert git("rev-parse", "HEAD") == old
            print("PASS: release preview leaves the running gateway, checkout and containers unchanged")

            output = update()
            assert git("rev-parse", "HEAD") == new, output
            cid = compose("ps", "-q", "openclaw")
            assert cid != old_cid
            inspected = json.loads(run(docker, "inspect", cid).stdout)[0]
            assert inspected["Image"] == image_ids[0], output
            assert "CUSTOMER_SETTING=kept" in inspected["Config"]["Env"]
            assert sorted(m["Name"] for m in inspected["Mounts"] if m["Type"] == "volume") == sorted(restored.values())
            run(docker, "exec", cid, "sh", "-c", 'test "$(cat /run/secrets/customer_token)" = CANARY-CUSTOM-SECRET')
            state = compose("run", "--rm", "-T", "cli", "sh", "-c",
                            "cat /fixture-openclaw/config /fixture-openclaw/memory "
                            "/fixture-openclaw/external-mcp /fixture-pretorin/active-cli")
            assert state == "configmemorymcpcli", state
            print("PASS: release apply keeps restored volumes, overlay order, custom secret path and state")

            output = update()
            assert "already at v0.6.0" in output, output
            assert compose("ps", "-q", "openclaw") == cid
            print("PASS: applying the same release again does not replace the gateway")
        finally:
            run(docker, "compose", "down", "-v", check=False)
            for name in restored.values():
                run(docker, "volume", "rm", name, check=False)


def main():
    if len(sys.argv) != 3 and sys.argv[1:] != ["--selection-only"]:
        sys.exit(__doc__)
    root = Path(__file__).resolve().parent.parent
    docker = shutil.which("docker")
    if not docker:
        sys.exit("Docker is required")
    images = sys.argv[1:]
    # Honor the caller's explicitly selected Docker engine. Only new projects
    # and fixture files below are used; no existing container is addressed.
    docker_env = {k: v for k, v in os.environ.items()
                  if k in ("PATH", "HOME", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}

    selection_regression(root, docker, docker_env)
    release_regression(root, docker, docker_env)
    if sys.argv[1:] == ["--selection-only"]:
        return

    def docker_run(*args, **kwargs):
        return subprocess.run([docker, *args], env=docker_env, text=True,
                              capture_output=True, check=True, **kwargs)

    image_ids = [docker_run("image", "inspect", "--format", "{{.Id}}", image).stdout.strip()
                 for image in images]
    if image_ids[0] == image_ids[1]:
        sys.exit("The two fixture images must have different image IDs")
    release_apply_regression(root, docker, docker_env, images, image_ids)

    # Read the real service overrides, not a second production timing policy.
    rendered = json.loads(docker_run("compose", "--profile", "*", "config", "--format", "json", cwd=root).stdout)
    gateway = rendered["services"]["openclaw"]
    schedule = gateway["healthcheck"]
    def seconds(text):
        return sum(float(n) * {"h": 3600, "m": 60, "s": 1}[u]
                   for n, u in re.findall(r"([0-9.]+)([hms])", text))
    assert seconds(schedule["interval"]) == 15, schedule
    assert seconds(schedule["start_period"]) == 720, schedule
    assert set(schedule) == {"interval", "start_period"}, schedule
    assert seconds(gateway["stop_grace_period"]) == 330
    assert "healthcheck" not in rendered["services"]["cli"]
    with tempfile.TemporaryDirectory(prefix="cc-update-compose-") as tmp:
        fixture = Path(tmp)
        (fixture / "scripts").mkdir()
        (fixture / "bin").mkdir()
        (fixture / "targets").mkdir()
        (fixture / "targets/canary").write_text("retained target\n")
        (fixture / ".env").write_text("FIXTURE_ONLY=retained\n")
        shutil.copyfile(root / "scripts/update.sh", fixture / "scripts/update.sh")
        shutil.copyfile(root / "scripts/compose-selection.sh", fixture / "scripts/compose-selection.sh")
        shutil.copyfile(root / "versions.env", fixture / "versions.env")
        (fixture / "bin/git").write_text('''#!/bin/bash
case "$*" in
  'rev-parse --git-dir') echo .git ;;
  'status --porcelain'|'fetch --quiet origin') ;;
  'rev-parse --abbrev-ref HEAD') echo master ;;
  'rev-parse --abbrev-ref --symbolic-full-name @{upstream}') echo origin/master ;;
  'rev-list --left-right --count origin/master...HEAD') echo '0 0' ;;
  *) exit 91 ;;
esac
''')
        (fixture / "bin/docker").write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
# Scale only this synthetic fixture's wait; assert the real updater requested 720.
if args[:3] == ["compose", "up", "-d"]:
    pos = args.index("--wait-timeout")
    assert args[pos + 1] == "720", args
    args[pos + 1] = "15"
# Local fixture images are already present. No registry call is part of this test.
if sys.argv[1:] in (["compose", "pull", "--quiet"], ["compose", "pull"]):
    sys.exit(0)
os.execv(os.environ["FIXTURE_DOCKER"], [os.environ["FIXTURE_DOCKER"], *args])
''')
        for tool in ("git", "docker"):
            (fixture / "bin" / tool).chmod(0o700)
        (fixture / "compose.yaml").write_text(json.dumps({
            "services": {
                "openclaw": {
                    "image": images[1], "network_mode": "none", "user": "0:0",
                    "entrypoint": ["sh", "-c"],
                    "command": ["touch /tmp/ready; exec sleep infinity"],
                    "healthcheck": {"test": ["CMD", "test", "-f", "/tmp/ready"],
                                    "interval": "1s", "timeout": "1s", "retries": 3},
                    "volumes": ["openclaw-state:/fixture-openclaw", "pretorin-state:/fixture-pretorin",
                                "./targets:/fixture-targets:ro"],
                },
                "cli": {"image": images[1], "network_mode": "none", "user": "0:0", "profiles": ["cli"],
                        "entrypoint": [], "command": ["true"],
                        "volumes": ["openclaw-state:/fixture-openclaw", "pretorin-state:/fixture-pretorin"]},
            }, "volumes": {"openclaw-state": {}, "pretorin-state": {}}
        }))
        overlay = fixture / "compose.customer.yaml"
        base_env = {**docker_env, "COMPOSE_FILE": "compose.yaml:compose.customer.yaml",
                    "COMPOSE_PROFILES": "cli", "CUSTOM_IMAGE": images[0]}
        project = "cc-update-" + fixture.name[len("cc-update-compose-"):]

        def compose(name, *args):
            return subprocess.run([docker, "compose", *args], cwd=fixture,
                                  env={**base_env, "COMPOSE_PROJECT_NAME": name},
                                  text=True, capture_output=True, check=True)

        def configure(**service):
            overlay.write_text(json.dumps({"services": {"openclaw": {"image": "${CUSTOM_IMAGE}", **service}}}))

        def update(expected_success):
            result = subprocess.run(["bash", str(fixture / "scripts/update.sh")], cwd=fixture,
                                    env={**base_env, "COMPOSE_PROJECT_NAME": project,
                                         "PATH": str(fixture / "bin") + os.pathsep + docker_env["PATH"],
                                         "FIXTURE_DOCKER": docker}, text=True, capture_output=True)
            output = result.stdout + result.stderr
            assert (result.returncode == 0) == expected_success, output
            assert ("update: done." in output) == expected_success, output
            if not expected_success:
                assert "config is current" not in output, output
            print(output, end="")
            return result

        try:
            configure()
            compose(project + "-other", "up", "-d", "--wait", "--wait-timeout", "30", "openclaw")
            other_cid = compose(project + "-other", "ps", "-q", "openclaw").stdout.strip()
            compose(project, "run", "--rm", "-T", "cli", "sh", "-c",
                    "printf 'retained config' > /fixture-openclaw/config; "
                    "printf 'retained CLI' > /fixture-pretorin/active-cli")
            update(True)
            cid = compose(project, "ps", "-q", "openclaw").stdout.strip()
            expected = docker_run("image", "inspect", "--format", "{{.Id}}", images[0]).stdout.strip()
            actual = docker_run("inspect", "--format", "{{.Image}}", cid).stdout.strip()
            assert actual == expected
            update(True)
            assert compose(project, "ps", "-q", "openclaw").stdout.strip() == cid
            print("PASS: effective image override, healthy startup, and repeat without replacement")

            # Interval-only control: failed probes precede readiness, then Docker
            # rejects the service before its marker can be written.
            delayed = ["sleep 8; touch /tmp/ready; exec sleep infinity"]
            configure(command=delayed, healthcheck={"start_period": "1s"})
            update(False)
            failed = compose(project, "ps", "--all", "-q", "openclaw").stdout.strip()
            health = json.loads(docker_run("inspect", "--format", "{{json .State.Health}}", failed).stdout)
            assert health["Status"] == "unhealthy", health
            assert health["Log"] and all(p["ExitCode"] != 0 for p in health["Log"]), health
            print("PASS: short-grace control fails before delayed readiness")

            # Production grace scaled by 24; test interval and timeout are 1s.
            # This tests native scheduling, not the full 720-second duration.
            configure(command=delayed, healthcheck={
                "start_period": str(seconds(schedule["start_period"]) / 24) + "s"})
            update(True)
            print("PASS: delayed synthetic health survives startup grace")

            configure(command=["exit 17"])
            update(False)
            failed_cid = compose(project, "ps", "--all", "-q", "openclaw").stdout.strip()
            assert docker_run("inspect", "--format", "{{.State.Status}}", failed_cid).stdout.strip() == "exited"
            print("PASS: failed startup")

            configure(command=["exec sleep infinity"], healthcheck={"start_period": "30s"})
            started = time.monotonic()
            update(False)
            elapsed = time.monotonic() - started
            assert 12 <= elapsed < 30, elapsed
            print("PASS: never-ready service fails the scaled finite native wait", round(elapsed, 1))

            configure()
            state = compose(project, "run", "--rm", "-T", "cli", "sh", "-c",
                            "cat /fixture-openclaw/config; cat /fixture-pretorin/active-cli").stdout
            assert state == "retained configretained CLI", state
            assert (fixture / "targets/canary").read_text() == "retained target\n"
            assert (fixture / ".env").read_text() == "FIXTURE_ONLY=retained\n"
            assert compose(project + "-other", "ps", "-q", "openclaw").stdout.strip() == other_cid
            other = docker_run("inspect", "--format", "{{.State.Health.Status}}", other_cid).stdout.strip()
            assert other == "healthy", other
            print("PASS: retained synthetic state, target, environment file, and other project")
        finally:
            # Only these two newly created projects and their disposable volumes.
            for name in (project, project + "-other"):
                compose(name, "down", "-v")


if __name__ == "__main__":
    main()
