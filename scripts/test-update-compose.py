#!/usr/bin/env python3
"""Test host verification with real Compose and synthetic local containers.

Usage: python3 scripts/test-update-compose.py LOCAL_IMAGE OTHER_LOCAL_IMAGE
Uses no registry, credentials, ports, or OpenClaw runtime. Git and image pulls
are stubbed; Compose selection, startup, wait, and inspection are real.
The timeout case uses the updater's full 360-second wait.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def main():
    if len(sys.argv) != 3:
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

    def docker_run(*args, **kwargs):
        return subprocess.run([docker, *args], env=docker_env, text=True,
                              capture_output=True, check=True, **kwargs)

    image_ids = [docker_run("image", "inspect", "--format", "{{.Id}}", image).stdout.strip()
                 for image in images]
    if image_ids[0] == image_ids[1]:
        sys.exit("The two fixture images must have different image IDs")
    with tempfile.TemporaryDirectory(prefix="cc-update-compose-") as tmp:
        fixture = Path(tmp)
        (fixture / "scripts").mkdir()
        (fixture / "bin").mkdir()
        (fixture / "targets").mkdir()
        (fixture / "targets/canary").write_text("retained target\n")
        (fixture / ".env").write_text("FIXTURE_ONLY=retained\n")
        shutil.copyfile(root / "scripts/update.sh", fixture / "scripts/update.sh")
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
# Local fixture images are already present. No registry call is part of this test.
if sys.argv[1:] in (["compose", "pull", "--quiet"], ["compose", "pull"]):
    sys.exit(0)
os.execv(os.environ["FIXTURE_DOCKER"], [os.environ["FIXTURE_DOCKER"], *sys.argv[1:]])
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

            configure(command=["sleep 3; touch /tmp/ready; exec sleep infinity"])
            update(True)
            print("PASS: delayed synthetic health")

            configure(command=["exit 17"])
            update(False)
            failed_cid = compose(project, "ps", "--all", "-q", "openclaw").stdout.strip()
            assert docker_run("inspect", "--format", "{{.State.Status}}", failed_cid).stdout.strip() == "exited"
            print("PASS: failed startup")

            configure(command=["exec sleep infinity"])
            update(False)
            unhealthy_cid = compose(project, "ps", "--all", "-q", "openclaw").stdout.strip()
            assert docker_run("inspect", "--format", "{{.State.Health.Status}}", unhealthy_cid).stdout.strip() == "unhealthy"
            print("PASS: unhealthy startup")

            configure(command=["exec sleep infinity"], healthcheck={"start_period": "600s"})
            started = time.monotonic()
            update(False)
            elapsed = time.monotonic() - started
            # gstack-timing-ok: Verify the full Compose timeout, not a performance threshold.
            assert elapsed >= 360, f"Compose returned before its wait limit: {elapsed}s"
            timeout_cid = compose(project, "ps", "--all", "-q", "openclaw").stdout.strip()
            assert docker_run("inspect", "--format", "{{.State.Health.Status}}", timeout_cid).stdout.strip() == "starting"
            print("PASS: Compose timeout at the unchanged 360-second limit")

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
