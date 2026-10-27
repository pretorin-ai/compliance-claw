#!/usr/bin/env python3
"""Run the real host updater with isolated Git and Docker command stubs.

Protects exit status, reports, and deployment selection. These tests do not
prove real Compose merging, container startup, or channel/MCP operation.
CC_TEST_UPDATE_SCRIPT can select the old script to prove the regression.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(os.environ.get("CC_TEST_UPDATE_SCRIPT", ROOT / "scripts/update.sh"))
IMAGE_ID = "sha256:" + "a" * 64
PROJECT = "cc-update-test"
IMAGE = "registry.example/customer-gateway:chosen"
WARNINGS = (
    "predates the image",
    "Slack credentials are supplied but NOT",
    "runs MCP from the image seed",
    "still loads the Pretorin skill",
)

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
root = pathlib.Path(os.environ["FIXTURE"])
settings = json.loads((root / "settings.json").read_text())
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"tool": pathlib.Path(sys.argv[0]).name, "args": a,
        "selection": {k: os.environ.get(k) for k in
            ("COMPOSE_PROJECT_NAME", "COMPOSE_FILE", "COMPOSE_PROFILES", "CUSTOM_IMAGE")}}) + "\n")
def out(value):
    print(value)
def fail(key):
    if settings.get(key):
        print("fixture: " + key, file=sys.stderr)
        sys.exit(settings[key])
if pathlib.Path(sys.argv[0]).name == "git":
    if a == ["rev-parse", "--git-dir"]: out(".git")
    elif a == ["status", "--porcelain"]: pass
    elif a == ["rev-parse", "--abbrev-ref", "HEAD"]: out("master")
    elif a == ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]: out("origin/master")
    elif a == ["fetch", "--quiet", "origin"]: fail("fetch_rc")
    elif a == ["rev-list", "--left-right", "--count", "origin/master...HEAD"]: out("0 0")
    else: sys.exit("unexpected git command: " + repr(a))
elif a == ["compose", "config", "--environment"]:
    fail("selection_rc")
    out(settings.get("selection", "\n".join(k + "=" + v for k, v in os.environ.items()
        if k in ("COMPOSE_FILE", "COMPOSE_PATH_SEPARATOR", "COMPOSE_PROJECT_NAME",
                 "COMPOSE_PROFILES", "COMPLIANCE_CLAW_SECRET_DIR"))))
elif a == ["compose", "up", "--help"]:
    fail("help_rc")
    out("--wait --wait-timeout" if not settings.get("unsupported_wait") else "--detach")
elif a == ["compose", "config", "--format", "json"]:
    fail("config_rc")
    out(settings.get("config_raw", json.dumps({"name": settings.get("project", "cc-update-test"),
        "services": {"openclaw": {"image": settings.get("image", "registry.example/customer-gateway:chosen")},
        "cli": {"image": "registry.example/different-cli:old", "environment": {"SECRET": "CANARY-DO-NOT-PRINT"}}}})))
elif a == ["compose", "pull", "--quiet"]: fail("quiet_pull_rc")
elif a == ["compose", "pull"]: fail("pull_rc")
elif a in (["compose", "up", "-d"], ["compose", "up", "-d", "--wait", "--wait-timeout", "720", "openclaw"]):
    fail("up_rc")
elif a[:3] == ["image", "inspect", "--format"]:
    assert a[-1] == settings.get("image", "registry.example/customer-gateway:chosen"), a
    fail("image_rc")
    out(settings.get("image_id", "sha256:" + "a" * 64))
elif a == ["compose", "ps", "--all", "--quiet", "openclaw"]:
    fail("ps_rc")
    counter = root / "ps-count"
    n = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(n))
    out(settings.get("final_cid" if n > 1 else "cid", settings.get("cid", "c" * 64)))
elif a[:2] == ["inspect", "--format"]:
    fail("inspect_rc")
    count = int((root / "ps-count").read_text())
    out(settings.get("final_state" if count > 1 else "state", settings.get("state",
        "sha256:" + "a" * 64 + " running healthy cc-update-test openclaw")))
elif a == ["compose", "run", "--rm", "-T", "cli", "true"]:
    text = settings.get("diagnostic", "")
    if text: print(text, file=sys.stderr)
    sys.exit(settings.get("diagnostic_rc", 0))
else: sys.exit("unexpected docker command: " + repr(a))
'''


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cc-update-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.root / "scripts/update.sh")
        shutil.copyfile(ROOT / "versions.env", self.root / "versions.env")
        shutil.copyfile(ROOT / "scripts/compose-selection.sh", self.root / "scripts/compose-selection.sh")
        for name in ("compose.yaml", "compose.build.yaml", "compose.secrets.yaml"):
            shutil.copyfile(ROOT / name, self.root / name)
        (self.root / "bin").mkdir()
        for tool in ("git", "docker"):
            p = self.root / "bin" / tool
            p.write_text(STUB)
            p.chmod(0o700)
        self.selection = {
            "COMPOSE_PROJECT_NAME": PROJECT,
            "COMPOSE_FILE": "compose.yaml:compose.customer.yaml:compose.credentials.yaml",
            "COMPOSE_PROFILES": "cli,customer",
            "CUSTOM_IMAGE": IMAGE,
        }

    def run_update(self, **settings):
        (self.root / "settings.json").write_text(json.dumps(settings))
        (self.root / "calls.jsonl").write_text("")
        (self.root / "ps-count").unlink(missing_ok=True)
        env = {"PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
               "HOME": str(self.root), "FIXTURE": str(self.root), **self.selection}
        p = subprocess.run(["bash", str(self.root / "scripts/update.sh")], env=env,
                           text=True, capture_output=True)
        self.output = p.stdout + p.stderr
        self.calls = [json.loads(s) for s in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertNotIn("unexpected", self.output, self.output)
        self.assertNotIn("CANARY-DO-NOT-PRINT", self.output)
        return p.returncode

    def assert_failure(self, **settings):
        self.assertNotEqual(self.run_update(**settings), 0, self.output)
        self.assertNotIn("update: done.", self.output)
        self.assertNotIn("config is current", self.output)

    def test_success_uses_effective_image_and_bounded_gateway_wait(self):
        self.assertEqual(self.run_update(), 0, self.output)
        self.assertIn("update: done.", self.output)
        self.assertIn("config is current", self.output)
        docker = [c for c in self.calls if c["tool"] == "docker"]
        self.assertIn(["compose", "up", "-d", "--wait", "--wait-timeout", "720", "openclaw"],
                      [c["args"] for c in docker])
        for call in docker:
            self.assertEqual(call["selection"], self.selection)
        self.assertEqual(sum(c["args"][0] == "inspect" for c in docker), 2)
        self.assertNotIn("--force-recreate", str(docker))
        self.assertNotIn("down", str(docker))

    def test_saved_build_selection_refuses_before_git_or_runtime(self):
        self.assert_failure(selection="COMPOSE_FILE=./compose.yaml:./compose.build.yaml")
        self.assertIn("local build overlay", self.output)
        self.assertEqual(len(self.calls), 1)

    def test_selection_failure_stops_before_git_or_runtime(self):
        self.assert_failure(selection_rc=19)
        self.assertIn("cannot resolve deployment settings", self.output)
        self.assertEqual(len(self.calls), 1)

    def test_missing_release_secret_file_is_created_before_pull(self):
        # A deployment from before this release has every secret file except the
        # new password file. The updater must create it, write-if-absent, before
        # `compose pull`/`up`, or `up` fails on the missing secret source.
        shutil.copyfile(ROOT / "scripts/init-file-secrets.sh", self.root / "scripts/init-file-secrets.sh")
        secrets = self.root / "secrets/runtime"
        secrets.mkdir(parents=True)
        for name in ("pretorin-api-key", "openclaw-gateway-token", "slack-app-token", "slack-bot-token",
                     "openai-api-key", "anthropic-api-key", "github-readonly-pat"):
            (secrets / name).write_text("")
        self.selection["COMPOSE_FILE"] = "compose.yaml:compose.secrets.yaml:compose.efforts.yaml"
        self.assertEqual(self.run_update(), 0, self.output)
        self.assertIn("openclaw-gateway-password", self.output)
        self.assertTrue((secrets / "openclaw-gateway-password").exists(), self.output)
        self.assertEqual((secrets / "openclaw-gateway-token").read_text(), "")
        pull_index = self.output.index("pulling") if "pulling" in self.output else len(self.output)
        self.assertLess(self.output.index("secret files are complete"), pull_index)

    def test_startup_or_compose_timeout_stops_before_diagnostics(self):
        for rc in (1, 17):
            with self.subTest(rc=rc):
                self.assert_failure(up_rc=rc)
                self.assertFalse(any(c["args"][:2] == ["compose", "run"] for c in self.calls))

    def test_unsupported_wait_stops_before_startup(self):
        self.assert_failure(unsupported_wait=True)
        self.assertIn("--wait-timeout", self.output)
        self.assertFalse(any(c["args"][:2] == ["compose", "pull"] for c in self.calls))

    def test_selection_or_inspection_failure_cannot_pass(self):
        for key in ("help_rc", "config_rc", "image_rc", "ps_rc", "inspect_rc"):
            with self.subTest(key=key):
                self.assert_failure(**{key: 7})

    def test_invalid_or_absent_selection_cannot_pass(self):
        for raw in ("invalid json", "{}", '{"name":"x","services":{"openclaw":{}}}'):
            with self.subTest(raw=raw):
                self.assert_failure(config_raw=raw)

    def test_absent_or_multiple_gateway_containers_cannot_pass(self):
        for cid in ("", "c" * 64 + "\n" + "d" * 64):
            with self.subTest(cid=cid):
                self.assert_failure(cid=cid)

    def test_running_healthy_and_actual_image_are_all_required(self):
        for state in ("running starting", "running unhealthy", "exited healthy", "restarting healthy", "running none"):
            with self.subTest(state=state):
                self.assert_failure(state=f"{IMAGE_ID} {state} {PROJECT} openclaw")
        self.assert_failure(state=f"sha256:{'b' * 64} running healthy {PROJECT} openclaw")
        self.assert_failure(image_id="")

    def test_another_project_or_service_cannot_satisfy_verification(self):
        for owner in ("other-project openclaw", f"{PROJECT} cli"):
            with self.subTest(owner=owner):
                self.assert_failure(state=f"{IMAGE_ID} running healthy {owner}")

    def test_final_check_rejects_replacement_or_health_image_change(self):
        self.assert_failure(final_cid="d" * 64)
        for state in (f"{IMAGE_ID} running unhealthy {PROJECT} openclaw",
                      f"sha256:{'b' * 64} running healthy {PROJECT} openclaw"):
            with self.subTest(state=state):
                self.assert_failure(final_state=state)

    def test_diagnostic_failures_are_unknown_even_with_warning_or_empty_output(self):
        for text in ("fixture: diagnostic failed", "", *WARNINGS):
            with self.subTest(text=text):
                self.assert_failure(diagnostic_rc=42, diagnostic=text)
                self.assertIn("exit 42", self.output)
                self.assertIn("configuration status is unknown", self.output)
                if text:
                    self.assertIn(text, self.output)

    def test_successful_diagnostics_keep_all_four_warnings(self):
        for warning in WARNINGS:
            with self.subTest(warning=warning):
                self.assertEqual(self.run_update(diagnostic=warning), 0, self.output)
                self.assertIn("WARNING", self.output)
                self.assertNotIn("config is current", self.output)

    def test_pull_retry_and_failure_keep_existing_results(self):
        self.assertEqual(self.run_update(quiet_pull_rc=8), 0, self.output)
        self.assert_failure(quiet_pull_rc=8, pull_rc=9)
        self.assertFalse(any(c["args"][:3] == ["compose", "up", "-d"] for c in self.calls))


if __name__ == "__main__":
    unittest.main()
