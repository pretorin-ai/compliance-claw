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
        self.assertIn("created secrets/runtime/openclaw-gateway-password", self.output)
        self.assertTrue((secrets / "openclaw-gateway-password").exists(), self.output)
        self.assertEqual((secrets / "openclaw-gateway-token").read_text(), "")
        self.assertLess(self.output.index("openclaw-gateway-password"), self.output.index("pulling"))
        first_pull = next(i for i, c in enumerate(self.calls) if c["args"][:2] == ["compose", "pull"])
        self.assertTrue(all(c["args"][:3] != ["compose", "up", "-d"] for c in self.calls[:first_pull]))

    def prepare_secret_fixture(self):
        shutil.copyfile(ROOT / "scripts/init-file-secrets.sh", self.root / "scripts/init-file-secrets.sh")
        self.selection["COMPOSE_FILE"] = "compose.yaml:compose.secrets.yaml"
        secrets = self.root / "secrets/runtime"
        secrets.mkdir(parents=True)
        return secrets

    def test_secret_preparation_keeps_existing_bytes_and_modes(self):
        # 0604 is the local helper's mode. An existing file keeps its bytes and
        # mode, and the directory keeps its mode. (0400 owned by 1000:1000, the
        # VM mode, needs root to set up; the unreadable test covers no-chmod.)
        secrets = self.prepare_secret_fixture()
        existing = {"pretorin-api-key": (b"CANARY-KEEP-PRETORIN", 0o604),
                    "openclaw-gateway-token": (b"", 0o644),
                    "slack-app-token": (b"CANARY-KEEP-SLACK", 0o604),
                    "github-readonly-pat": (b"", 0o604)}
        for name, (value, mode) in existing.items():
            (secrets / name).write_bytes(value)
            (secrets / name).chmod(mode)
        secrets.chmod(0o750)
        self.assertEqual(self.run_update(), 0, self.output)
        for name, (value, mode) in existing.items():
            with self.subTest(name=name):
                self.assertEqual((secrets / name).read_bytes(), value)
                self.assertEqual((secrets / name).stat().st_mode & 0o777, mode)
        self.assertEqual(secrets.stat().st_mode & 0o777, 0o750)
        # The intentionally empty token stays empty; new optional files are empty.
        self.assertEqual((secrets / "openai-api-key").read_bytes(), b"")
        self.assertNotIn("CANARY-KEEP", self.output)

    def test_unreadable_existing_secret_stops_before_pull_without_chmod(self):
        secrets = self.prepare_secret_fixture()
        (secrets / "pretorin-api-key").write_bytes(b"CANARY-KEEP-PRETORIN")
        (secrets / "pretorin-api-key").chmod(0o000)
        self.addCleanup((secrets / "pretorin-api-key").chmod, 0o600)
        self.assert_failure()
        self.assertIn("cannot read", self.output)
        self.assertIn("sudo chown 1000:1000", self.output)
        self.assertIn("NOTHING WAS STOPPED", self.output)
        self.assertEqual((secrets / "pretorin-api-key").stat().st_mode & 0o777, 0)
        self.assertFalse(any(c["args"][:2] == ["compose", "pull"] or c["args"][:3] == ["compose", "up", "-d"]
                             for c in self.calls))

    def test_missing_token_is_generated_without_reaching_output_or_arguments(self):
        secrets = self.prepare_secret_fixture()
        self.assertEqual(self.run_update(), 0, self.output)
        token = (secrets / "openclaw-gateway-token").read_text()
        self.assertRegex(token, r"^[0-9a-f]{64}$")
        self.assertNotIn(token, self.output)
        self.assertNotIn(token, (self.root / "calls.jsonl").read_text())
        self.assertEqual((secrets / "openclaw-gateway-password").read_bytes(), b"")
        # A second run changes nothing: the token is now retained.
        self.assertEqual(self.run_update(), 0, self.output)
        self.assertEqual((secrets / "openclaw-gateway-token").read_text(), token)

    def test_empty_retained_token_is_not_regenerated(self):
        secrets = self.prepare_secret_fixture()
        (secrets / "openclaw-gateway-token").write_bytes(b"")
        openssl = self.root / "bin/openssl"
        openssl.write_text("#!/bin/sh\nexit 99\n")
        openssl.chmod(0o700)
        self.assertEqual(self.run_update(), 0, self.output)
        self.assertEqual((secrets / "openclaw-gateway-token").read_bytes(), b"")

    def test_legacy_selection_gets_no_secret_files(self):
        shutil.copyfile(ROOT / "scripts/init-file-secrets.sh", self.root / "scripts/init-file-secrets.sh")
        self.selection["COMPOSE_FILE"] = "compose.yaml"
        self.assertEqual(self.run_update(), 0, self.output)
        self.assertFalse((self.root / "secrets").exists())
        self.assertNotIn("preparing built-in secret files", self.output)

    def test_secret_preparation_failure_stops_before_pull_or_up(self):
        self.prepare_secret_fixture()
        shutil.rmtree(self.root / "secrets/runtime")
        (self.root / "secrets/runtime").write_text("not a directory")
        self.assert_failure()
        self.assertIn("NOTHING WAS STOPPED", self.output)
        self.assertFalse(any(c["args"][:2] == ["compose", "pull"] or c["args"][:3] == ["compose", "up", "-d"]
                             for c in self.calls))

    def test_missing_custom_secret_source_stops_before_pull_or_up(self):
        missing = str(self.root / "customer-secrets/absent")
        model = {"name": PROJECT, "services": {"openclaw": {"image": IMAGE}},
                 "secrets": {"customer_secret": {"file": missing}}}
        self.assert_failure(config_raw=json.dumps(model))
        self.assertIn(missing, self.output)
        self.assertFalse(any(c["args"][:2] == ["compose", "pull"] or c["args"][:3] == ["compose", "up", "-d"]
                             for c in self.calls))

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


# ---------------------------------------------------------------------------
# Release route. Real Git repositories (a local bare origin with tags) and a
# fixture of the release-asset helper interface. Docker stays a stub that reads
# a small line format instead of YAML, so these tests prove the updater's order,
# refusals and file effects, not Compose merging (see test-update-compose.py).
# ---------------------------------------------------------------------------
IMAGE_REPOSITORY = "ghcr.io/pretorin-ai/compliance-claw"
OLD_IMAGE = IMAGE_REPOSITORY + ":0.5.2@sha256:" + "1" * 64
NEW_DIGEST = "sha256:" + "2" * 64
NEW_IMAGE = IMAGE_REPOSITORY + ":0.6.0@" + NEW_DIGEST
IMAGE_IDS = {OLD_IMAGE: "sha256:" + "3" * 64, NEW_IMAGE: "sha256:" + "4" * 64,
             IMAGE_REPOSITORY + ":0.7.0@" + NEW_DIGEST: "sha256:" + "6" * 64,
             "registry.example/custom:1": "sha256:" + "5" * 64}
PLACEHOLDER = "services: {}\n"
HELPER = ROOT / "scripts/release-assets.py"
DOWNLOAD_LINE = 'RELEASE_DOWNLOAD = "https://github.com/%s/releases/download" % RELEASE_REPOSITORY'


SIGNATURE_SHIM = r"""#!/usr/bin/env python3
# TEST SHIM, only in a test's temporary repository. The real helper refuses
# every release set today (unsigned, exit 6). With CC_TEST_RELEASE_SIGNED=1
# this shim stands in for a later verified signature so that the apply path
# can be tested: it admits the unsigned set and reports it as verified.
# Without the variable it passes everything to the real helper unchanged.
import json, os, subprocess, sys
real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "release-assets-real.py")
args = sys.argv[1:]
signed = os.environ.get("CC_TEST_RELEASE_SIGNED") == "1"
if signed and args[:1] == ["check"] and "--allow-unsigned" not in args:
    args.append("--allow-unsigned")
p = subprocess.run([sys.executable, real] + args, capture_output=True, text=True)
out = p.stdout
if signed and p.returncode == 0 and args[:1] in (["fetch"], ["check"]) and "--json" in args:
    out = "".join(json.dumps({**json.loads(line), "signature_status": "fixture-verified"},
                             sort_keys=True) + "\n" for line in out.splitlines() if line.strip())
sys.stdout.write(out)
sys.stderr.write(p.stderr)
sys.exit(p.returncode)
"""


def install_release_helper(repo, releases, shim=True):
    """Install the real release helper, behind the test shim unless shim=False.

    Only the helper's download base changes, to local files.
    """
    text = HELPER.read_text()
    assert text.count(DOWNLOAD_LINE) == 1, "the helper download base changed"
    text = text.replace(DOWNLOAD_LINE, "RELEASE_DOWNLOAD = %r" % releases.resolve().as_uri())
    if shim:
        (repo / "scripts/release-assets-real.py").write_text(text)
        (repo / "scripts/release-assets.py").write_text(SIGNATURE_SHIM)
    else:
        (repo / "scripts/release-assets.py").write_text(text)


def make_release_set(out, version, commit, digest=NEW_DIGEST, final=True,
                     image_repository=IMAGE_REPOSITORY):
    """Prepare (and finalize) a release set with the real publisher commands."""
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    sbom = out.parent / ("sbom-input-" + version) / ("sbom-" + version + ".spdx.json")
    sbom.parent.mkdir(exist_ok=True)
    sbom.write_text(json.dumps({"spdxVersion": "SPDX-2.3", "packages": [{"name": "fixture"}]}))
    subprocess.run(["python3", str(HELPER), "prepare", "--version", version, "--commit", commit,
                    "--repository", "pretorin-ai/compliance-claw", "--image-repository",
                    image_repository, "--digest", digest, "--sbom", str(sbom), "--out", str(out)],
                   check=True, capture_output=True)
    if final:
        subprocess.run(["python3", str(HELPER), "finalize", "--dir", str(out)],
                       check=True, capture_output=True)
    return image_repository + ":" + version + "@" + digest


RELEASE_STUB = r"""#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
a = sys.argv[1:]
fixture = pathlib.Path(os.environ["FIXTURE"])
repo = os.environ["REPO"]
settings = json.loads((fixture / "settings.json").read_text())
def fail(key):
    if settings.get(key):
        print("fixture: " + key, file=sys.stderr)
        sys.exit(settings[key])
project_dir = repo
if a[1:2] == ["--project-directory"]:
    project_dir = a[2]
    a = a[:1] + a[3:]
if a[1:2] == ["--profile"] and a[2] in ("*", "cli"):
    a = a[:1] + a[3:]
# Log the normalized command, so a pull with --project-directory still counts.
head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
with (fixture / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"args": a, "head": head, "compose_file": os.environ.get("COMPOSE_FILE"),
                        "project_dir": project_dir}) + "\n")
def selection():
    # Native precedence: the process environment wins over the project .env.
    values = {}
    dotenv = pathlib.Path(project_dir, ".env")
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and key in KEYS:
                values[key] = value[1:-1] if value[:1] in "'\"" and value[-1:] == value[:1] else value
    values.update({k: v for k, v in os.environ.items() if k in KEYS})
    return values
KEYS = ("COMPOSE_FILE", "COMPOSE_PATH_SEPARATOR", "COMPOSE_PROJECT_NAME", "COMPOSE_PROFILES",
        "COMPLIANCE_CLAW_SECRET_DIR")
def render():
    env = selection()
    sep = env.get("COMPOSE_PATH_SEPARATOR", ":")
    image, mounts, secrets = None, {}, {}
    for entry in env.get("COMPOSE_FILE", "compose.yaml").split(sep):
        path = pathlib.Path(project_dir, entry)
        if not path.is_file():
            sys.exit("fixture compose: missing file " + str(path))
        for line in path.read_text().splitlines():
            key, _, value = line.partition(": ")
            key, value = key.strip(), value.strip().strip('"')
            if key == "image": image = value
            elif key == "volume": target, name = value.split("="); mounts[target] = name
            elif key == "secret": secrets[pathlib.Path(value).name] = {"file": str(pathlib.Path(project_dir, value))}
    vols = [{"type": "volume", "source": "v" + str(i), "target": t} for i, t in enumerate(sorted(mounts))]
    return {"name": env["COMPOSE_PROJECT_NAME"],
            "services": {s: {"image": image, "volumes": vols} for s in ("openclaw", "cli")},
            "volumes": {"v" + str(i): {"name": mounts[t]} for i, t in enumerate(sorted(mounts))},
            "secrets": secrets}
state = fixture / "running-image"
if a == ["compose", "config", "--environment"]:
    print("\n".join(k + "=" + v for k, v in selection().items()))
elif a == ["compose", "config", "--format", "json"]:
    print(json.dumps(render()))
elif a == ["compose", "up", "--help"]:
    print("--wait --wait-timeout")
elif a in (["compose", "pull", "--quiet"], ["compose", "pull"]):
    fail("pull_rc")
elif a == ["compose", "up", "-d", "--wait", "--wait-timeout", "720", "openclaw"]:
    state.write_text(render()["services"]["openclaw"]["image"])
    fail("up_rc")
elif a[:3] == ["image", "inspect", "--format"]:
    if a[-1] not in settings["ids"]:
        sys.exit("fixture: no such image " + a[-1])
    print(settings["ids"][a[-1]])
elif a in (["compose", "ps", "--quiet", "openclaw"], ["compose", "ps", "--all", "--quiet", "openclaw"]):
    print("c" * 64)
elif a[:2] == ["inspect", "--format"]:
    running = settings["ids"][state.read_text()]
    if a[2] == "{{.Image}}":
        print(running)
    else:
        print(running + " running healthy " + selection()["COMPOSE_PROJECT_NAME"] + " openclaw")
elif a == ["compose", "run", "--rm", "-T", "cli", "true"]:
    pass
else:
    sys.exit("unexpected docker command: " + repr(a))
"""


class ReleaseTest(unittest.TestCase):
    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.repo, check=True,
                              capture_output=True, text=True, env=self.git_env).stdout.strip()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cc-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.fixture = Path(self.temp.name).resolve()
        self.repo = self.fixture / "repo"
        # Never inherit a deployment selection (CI exports COMPOSE_FILE).
        inherited = {k: v for k, v in os.environ.items()
                     if not k.startswith(("COMPOSE_", "COMPLIANCE_CLAW_", "CC_"))}
        self.git_env = {**inherited, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        (self.repo / "scripts").mkdir(parents=True)
        # The transition constant names a real commit in production. Here it names
        # a fixture tag that a test creates only when it needs the transition.
        text = SCRIPT.read_text()
        self.assertEqual(text.count("EFFORT_RECORD_TRANSITION=770969c5348a17d7c120c70c23927b0f978be5a0"), 1)
        (self.repo / "scripts/update.sh").write_text(text.replace(
            "EFFORT_RECORD_TRANSITION=770969c5348a17d7c120c70c23927b0f978be5a0",
            "EFFORT_RECORD_TRANSITION=refs/tags/fixture-transition"))
        for name in ("compose-selection.sh", "init-file-secrets.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.repo / "scripts" / name)
        install_release_helper(self.repo, self.fixture / "releases",
                               shim=not self._testMethodName.endswith("_real_helper"))
        # The repository's own ignore rules, so generated files behave as on a host.
        shutil.copyfile(ROOT / ".gitignore", self.repo / ".gitignore")
        (self.repo / "versions.env").write_text(
            "OPENCLAW_VERSION=2026.10.5\nSLACK_PLUGIN_VERSION=2026.10.5\n"
            "IMAGE_REPO=ghcr.io/example/cc\nIMAGE_VERSION=0.5.2\n")
        (self.repo / "compose.yaml").write_text(
            f"image: {OLD_IMAGE}\nvolume: /home/node/.openclaw=cc-release-test_openclaw-state\n"
            "volume: /home/node/.pretorin=cc-release-test_pretorin-state\n")
        secrets = "".join(f"secret: secrets/runtime/{n}\n" for n in (
            "pretorin-api-key", "openclaw-gateway-token", "slack-app-token", "slack-bot-token",
            "openai-api-key", "anthropic-api-key", "github-readonly-pat"))
        (self.repo / "compose.secrets.yaml").write_text(secrets)
        (self.repo / "old-notes.txt").write_text("notes\n")
        self.git("init", "-q", "-b", "master")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "0.5.2")
        self.old = self.git("rev-parse", "HEAD")
        self.git("tag", "v0.5.2")
        # v0.6.0 adds a secret file, a document, and an OpenClaw version change.
        (self.repo / "compose.secrets.yaml").write_text(secrets + "secret: secrets/runtime/openclaw-gateway-password\n")
        (self.repo / "versions.env").write_text(
            (self.repo / "versions.env").read_text().replace("OPENCLAW_VERSION=2026.10.5", "OPENCLAW_VERSION=2026.11.1"))
        (self.repo / "docs").mkdir()
        (self.repo / "docs/new.txt").write_text("new\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "0.6.0")
        self.new = self.git("rev-parse", "HEAD")
        self.git("tag", "v0.6.0")
        self.git("clone", "-q", "--bare", str(self.repo), str(self.fixture / "origin.git"), cwd=self.fixture)
        self.git("remote", "add", "origin", str(self.fixture / "origin.git"))
        self.git("tag", "-d", "v0.6.0")
        self.git("reset", "-q", "--hard", self.old)
        self.write_release("v0.6.0", self.new)

        # Deployment state: placeholder overlay selected, a customer overlay, the
        # v0.5.2 secret files with canary values.
        (self.repo / "compose.release.yaml").write_text(PLACEHOLDER)
        (self.repo / "deployment").mkdir()
        (self.repo / "deployment/customer.yaml").write_text("# customer settings\n")
        runtime = self.repo / "secrets/runtime"
        runtime.mkdir(parents=True)
        for line in secrets.splitlines():
            (runtime / Path(line).name).write_text("")
        (runtime / "pretorin-api-key").write_text("CANARY-RELEASE-KEY")
        (self.fixture / "bin").mkdir()
        (self.fixture / "bin/docker").write_text(RELEASE_STUB)
        (self.fixture / "bin/docker").chmod(0o700)
        (self.fixture / "running-image").write_text(OLD_IMAGE)
        self.signed = "1"
        self.selection = {
            "COMPOSE_PROJECT_NAME": "cc-release-test",
            "COMPOSE_FILE": "compose.yaml:compose.release.yaml:compose.secrets.yaml:deployment/customer.yaml",
        }

    def write_release(self, tag, commit, **kwargs):
        return make_release_set(self.fixture / "releases" / tag, tag[1:], commit, **kwargs)

    def run_update(self, *args, **settings):
        (self.fixture / "settings.json").write_text(json.dumps({"ids": IMAGE_IDS, **settings}))
        (self.fixture / "calls.jsonl").write_text("")
        env = {**self.git_env, "PATH": str(self.fixture / "bin") + os.pathsep + os.environ["PATH"],
               "HOME": str(self.fixture), "FIXTURE": str(self.fixture), "REPO": str(self.repo),
               "TMPDIR": str(self.fixture), "CC_TEST_RELEASE_SIGNED": self.signed,
               **self.selection}
        p = subprocess.run(["bash", str(self.repo / "scripts/update.sh"), *args], env=env,
                           cwd=self.repo, text=True, capture_output=True)
        self.output = p.stdout + p.stderr
        self.calls = [json.loads(s) for s in (self.fixture / "calls.jsonl").read_text().splitlines()]
        self.assertNotIn("unexpected", self.output, self.output)
        self.assertNotIn("Traceback", self.output, self.output)
        self.assertNotIn("CANARY-RELEASE-KEY", self.output)
        self.assertEqual(list(self.fixture.glob("cc-release.*")), [], "temporary cache left behind")
        return p.returncode

    def snapshot(self):
        tree = sorted((str(p.relative_to(self.repo)), p.read_bytes() if p.is_file() else b"", p.stat().st_mode)
                      for p in self.repo.rglob("*") if ".git" not in p.parts)
        return (self.git("rev-parse", "HEAD"), self.git("for-each-ref"),
                self.git("status", "--porcelain", "--ignored"), tree)

    def changed(self):
        return [c["args"] for c in self.calls
                if c["args"][:2] in (["compose", "pull"], ["compose", "run"])
                or c["args"][:3] == ["compose", "up", "-d"]]

    def test_preview_reports_changes_without_any_change_real_helper(self):
        before = self.snapshot()
        self.assertEqual(self.run_update("--release", "v0.6.0", "--preview"), 2, self.output)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.changed(), [])
        blockers = self.output.split("BLOCKERS")[1].split("update: preview")[0]
        self.assertEqual(blockers.count("\n    - "), 1, blockers)
        self.assertIn("UNVERIFIED: publisher authenticity not checked", blockers)
        for text in ("0.5.2 -> 0.6.0", NEW_IMAGE, OLD_IMAGE, self.old, self.new, "unsigned",
                     "checked:       tag commit, asset checksums, image digest, effective image",
                     "branch master -> detached tag v0.6.0 (release mode",
                     "recovery set", "openclaw-gateway-password", "OpenClaw changes 2026.10.5 -> 2026.11.1",
                     "compose.yaml:compose.release.yaml:compose.secrets.yaml:deployment/customer.yaml",
                     "Pretorin CLI:  not changed", "UNVERIFIED: not signed"):
            self.assertIn(text, self.output)
        self.assertFalse((self.repo / "secrets/runtime/openclaw-gateway-password").exists())

    def test_apply_pulls_before_checkout_then_installs_and_starts(self):
        self.assertEqual(self.run_update("--release", "v0.6.0"), 0, self.output)
        self.assertIn("update: done.", self.output)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.new)
        for name in ("compose.release.yaml", "compliance-claw-release.json"):
            self.assertEqual((self.repo / name).read_bytes(),
                             (self.fixture / "releases/v0.6.0" / name).read_bytes())
        self.assertEqual(self.git("rev-parse", "refs/tags/v0.6.0^{commit}"), self.new)
        self.assertEqual(sorted(p.name for p in self.repo.glob("compose.release.yaml*")),
                         ["compose.release.yaml"])
        pulls = [c for c in self.calls if c["args"][:2] == ["compose", "pull"]]
        self.assertEqual(pulls[0]["head"], self.old, "the image must be pulled before checkout")
        self.assertIn("/assets/compose.release.yaml", pulls[0]["compose_file"])
        self.assertTrue(pulls[0]["compose_file"].endswith("deployment/customer.yaml"))
        up = [c for c in self.calls if c["args"][:3] == ["compose", "up", "-d"]]
        self.assertEqual(len(up), 1)
        self.assertEqual(up[0]["head"], self.new)
        self.assertEqual((self.fixture / "running-image").read_text(), NEW_IMAGE)
        runtime = self.repo / "secrets/runtime"
        self.assertEqual((runtime / "pretorin-api-key").read_text(), "CANARY-RELEASE-KEY")
        self.assertEqual((runtime / "openclaw-gateway-password").read_bytes(), b"")
        self.assertEqual((self.repo / "deployment/customer.yaml").read_text(), "# customer settings\n")
        self.assertFalse(self.git("status", "--porcelain", "--untracked-files=no"))

        # The same release again: no checkout, no release-set replacement.
        installed = (self.repo / "compose.release.yaml").stat().st_mtime_ns
        self.assertEqual(self.run_update("--release", "v0.6.0"), 0, self.output)
        self.assertIn("already at v0.6.0", self.output)
        self.assertIn("release set is already installed", self.output)
        self.assertEqual((self.repo / "compose.release.yaml").stat().st_mtime_ns, installed)
        # The installed release set is now the current version.
        self.assertEqual(self.run_update("--release", "v0.6.0", "--preview"), 0, self.output)
        self.assertIn("0.6.0 -> 0.6.0", self.output)

        # A release checkout must not take the branch route.
        self.assertNotEqual(self.run_update(), 0, self.output)
        self.assertIn("follows a release", self.output)
        self.assertEqual(self.changed(), [])

        # The next release keeps the previous record and overlay together.
        previous = {n: (self.repo / n).read_bytes()
                    for n in ("compose.release.yaml", "compliance-claw-release.json")}
        self.publish_v070((self.repo / "compose.yaml").read_text())
        self.assertEqual(self.run_update("--release", "v0.7.0"), 0, self.output)
        for name, data in previous.items():
            self.assertEqual((self.repo / (name + ".previous")).read_bytes(), data)
        self.assertIn("0.6.0 -> 0.7.0", self.output)

    def assert_blocked(self, text, *args, preview_rc=2):
        before = self.snapshot()
        if preview_rc is not None:
            self.assertEqual(self.run_update("--release", "v0.6.0", "--preview", *args), preview_rc, self.output)
            self.assertIn(text, self.output)
        self.assertNotEqual(self.run_update("--release", "v0.6.0", *args), 0, self.output)
        self.assertIn(text, self.output)
        self.assertNotIn("update: done.", self.output)
        self.assertEqual(self.changed(), [])
        self.assertEqual(self.snapshot(), before)

    def test_unsigned_release_is_shown_but_apply_refuses_real_helper(self):
        self.signed = "0"
        self.assert_blocked("UNVERIFIED: publisher authenticity not checked")
        self.assertIn("apply will refuse this release until signing/verification exists", self.output)
        self.assertIn("signature unsigned", self.output)

    def test_test_signature_variable_cannot_pass_the_real_helper_real_helper(self):
        # The variable exists only in the test shim; update.sh and the real
        # helper never read it, so apply still refuses (exit 6 path).
        self.signed = "1"
        self.assert_blocked("UNVERIFIED: publisher authenticity not checked")
        self.assertNotIn("fixture-verified", self.output)

    def test_matching_local_tag_is_kept(self):
        # A local annotated tag that names the release commit is a different tag
        # object than the remote lightweight tag; apply must not try to replace it.
        self.git("tag", "-a", "v0.6.0", "-m", "local", self.new)
        local = self.git("rev-parse", "refs/tags/v0.6.0")
        self.assertEqual(self.run_update("--release", "v0.6.0"), 0, self.output)
        self.assertEqual(self.git("rev-parse", "refs/tags/v0.6.0"), local)

    def test_dirty_tracked_source_blocks(self):
        (self.repo / "versions.env").write_text("changed\n")
        self.assert_blocked("tracked files have local changes")

    def test_file_added_by_release_over_a_local_file_blocks(self):
        (self.repo / "docs").mkdir()
        (self.repo / "docs/new.txt").write_text("customer file\n")
        self.assert_blocked("adds docs/new.txt")

    def test_file_added_under_a_local_file_parent_blocks(self):
        (self.repo / "docs").write_text("customer file named like the release directory\n")
        self.assert_blocked("local file exists at its parent path docs")

    def test_file_renamed_onto_a_local_file_blocks(self):
        # Rename detection would show this as R, not A, and git checkout would
        # replace the ignored local file without a warning.
        self.publish_v070((self.repo / "compose.yaml").read_text(),
                          change=lambda clone: (clone / "old-notes.txt").rename(clone / "secrets-notes.txt"))
        (self.repo / ".git/info/exclude").write_text("secrets-notes.txt\n")
        (self.repo / "secrets-notes.txt").write_text("customer notes\n")
        before = self.snapshot()
        self.assertNotEqual(self.run_update("--release", "v0.7.0"), 0, self.output)
        self.assertIn("adds secrets-notes.txt", self.output)
        self.assertEqual(self.snapshot(), before)

    def test_custom_secret_in_the_secret_directory_blocks(self):
        (self.repo / "deployment/customer.yaml").write_text("secret: secrets/runtime/customer-extra\n")
        self.assert_blocked("secrets/runtime/customer-extra does not exist")
        self.assertNotIn("apply creates these empty: openclaw-gateway-password customer-extra", self.output)

    def test_preview_changes_no_local_tag_with_a_tag_refspec(self):
        self.git("config", "remote.origin.fetch", "+refs/tags/*:refs/tags/*")
        self.git("tag", "v0.6.0", self.old)
        self.assert_blocked("the local tag v0.6.0 names " + self.old)

    def test_release_may_add_a_volume_mount(self):
        self.publish_v070((self.repo / "compose.yaml").read_text() + "volume: /var/cache/release=release-cache\n")
        self.assertEqual(self.run_update("--release", "v0.7.0", "--preview"), 0, self.output)
        self.assertNotIn("state-volume selection would change", self.output)

    def test_generated_bytecode_does_not_block_the_branch_route(self):
        # A normal parse-efforts.py run on Linux writes scripts/__pycache__/.
        shutil.rmtree(self.repo / "deployment")
        self.selection["COMPOSE_FILE"] = "compose.yaml:compose.release.yaml:compose.secrets.yaml"
        (self.repo / "scripts/__pycache__").mkdir()
        (self.repo / "scripts/__pycache__/parse-targets.cpython-311.pyc").write_bytes(b"\x00")
        self.assertNotEqual(self.run_update(), 0, self.output)
        self.assertNotIn("uncommitted changes", self.output)
        self.assertIn("has no upstream", self.output)
        # A real untracked customer file still stops it.
        (self.repo / "local-notes.txt").write_text("customer file\n")
        self.assertNotEqual(self.run_update(), 0, self.output)
        self.assertIn("uncommitted changes", self.output)

    def test_local_commit_not_in_release_blocks(self):
        (self.repo / "local.txt").write_text("customer commit\n")
        self.git("add", "local.txt")
        self.git("commit", "-q", "-m", "local")
        self.assert_blocked("has commits that v0.6.0 does not")

    def test_later_overlay_that_overrides_the_image_blocks(self):
        (self.repo / "deployment/customer.yaml").write_text(
            "image: registry.example/custom:1\nvolume: /home/node/.openclaw=restored-openclaw\n")
        self.assert_blocked("custom selection")
        self.assertIn("remove only the two image lines from that overlay and keep its volume lines", self.output)
        self.assertEqual((self.repo / "deployment/customer.yaml").read_text(),
                         "image: registry.example/custom:1\nvolume: /home/node/.openclaw=restored-openclaw\n")

    def publish_v070(self, compose_text, change=None):
        """Push a v0.7.0 tag on top of v0.6.0 to the origin, with its release set."""
        clone = self.fixture / "publisher"
        self.git("clone", "-q", str(self.fixture / "origin.git"), str(clone), cwd=self.fixture)
        self.git("checkout", "-q", "v0.6.0", cwd=clone)
        (clone / "compose.yaml").write_text(compose_text)
        if change:
            change(clone)
        self.git("add", "-A", cwd=clone)
        self.git("commit", "-q", "--allow-empty", "-m", "0.7.0", cwd=clone)
        self.git("tag", "v0.7.0", cwd=clone)
        self.git("push", "-q", "origin", "v0.7.0", cwd=clone)
        self.write_release("v0.7.0", self.git("rev-parse", "HEAD", cwd=clone))

    def test_release_that_changes_state_volumes_blocks(self):
        self.publish_v070((self.repo / "compose.yaml").read_text().replace(
            "cc-release-test_openclaw-state", "other-volume"))
        before = self.snapshot()
        self.assertEqual(self.run_update("--release", "v0.7.0", "--preview"), 2, self.output)
        self.assertIn("state-volume selection would change", self.output)
        self.assertNotEqual(self.run_update("--release", "v0.7.0"), 0, self.output)
        self.assertIn("state-volume selection would change", self.output)
        self.assertEqual(self.changed(), [])
        self.assertEqual(self.snapshot(), before)

    def test_recovered_volume_selection_is_kept(self):
        (self.repo / "deployment/customer.yaml").write_text(
            "volume: /home/node/.openclaw=restored-openclaw\nvolume: /home/node/.pretorin=restored-pretorin\n")
        self.assertEqual(self.run_update("--release", "v0.6.0"), 0, self.output)
        self.assertIn("restored-openclaw", self.output)

    def test_candidate_release_set_stops(self):
        # A candidate lives on a draft release; the helper fetches final sets only.
        self.write_release("v0.6.0", self.new, final=False)
        self.assert_blocked("no valid final release set", preview_rc=1)

    def test_downgrade_blocks(self):
        installed = self.fixture / "installed"
        make_release_set(installed, "0.7.0", self.new)
        for name in ("compose.release.yaml", "compliance-claw-release.json"):
            shutil.copyfile(installed / name, self.repo / name)
        self.assert_blocked("older than the current release 0.7.0")

    def test_effort_record_transition_needs_confirmation(self):
        self.git("tag", "fixture-transition", self.new)
        self.assert_blocked("transfer-existing-effort-records")
        self.assertEqual(self.run_update("--release", "v0.6.0", "--preview", "--effort-records-ready"), 0, self.output)
        self.assertIn("confirmed complete", self.output)

    def test_verification_failures_stop_before_any_change(self):
        with self.subTest(text="another source commit"):
            self.write_release("v0.6.0", self.old)
            self.assert_blocked("names another source than tag v0.6.0", preview_rc=1)
        assets = self.fixture / "releases/v0.6.0"
        for name, text in (("compose.release.yaml", "does not match its recorded sha256"),
                           ("compliance-claw-release.json", "not in canonical form"),
                           ("sbom-0.6.0.spdx.json", "does not match its recorded sha256")):
            with self.subTest(name=name):
                self.write_release("v0.6.0", self.new)
                if name == "compliance-claw-release.json":
                    record = json.loads((assets / name).read_text())
                    (assets / name).write_text(json.dumps(record))
                else:
                    (assets / name).write_bytes((assets / name).read_bytes() + b"\n")
                self.assert_blocked(text, preview_rc=1)
        with self.subTest(text="no assets"):
            shutil.rmtree(self.fixture / "releases/v0.6.0")
            self.assert_blocked("could not download the release set", preview_rc=1)

    def test_unknown_tag_and_bad_arguments_stop(self):
        before = self.snapshot()
        for args in (("--release", "v0.9.9"), ("--release", "latest"), ("--release=",), ("--release",),
                     ("--preview",), ("--effort-records-ready",)):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_update(*args), 0, self.output)
                self.assertEqual(self.changed(), [])
        self.assertEqual(self.snapshot(), before)

    def save_selection_in_env(self, compose_file):
        """Move the selection from the shell to a .env with other settings."""
        env = self.repo / ".env"
        env.write_text("# deployment settings\nCOMPOSE_PROJECT_NAME=cc-release-test\n"
                       f"COMPOSE_FILE={compose_file}\nLEGACY_SECRET=CANARY-ENV-SECRET\n")
        env.chmod(0o640)
        self.selection = {}
        return env

    def test_first_adoption_saves_only_the_compose_file_line(self):
        (self.repo / "compose.release.yaml").unlink()
        env = self.save_selection_in_env("compose.yaml:compose.secrets.yaml:deployment/customer.yaml")
        before = env.read_bytes()
        new = "compose.yaml:compose.release.yaml:compose.secrets.yaml:deployment/customer.yaml"
        self.assert_blocked("--save-selection")
        self.assertIn("->   " + new, self.output)
        self.assertEqual(env.read_bytes(), before)
        self.assertEqual(self.run_update("--release", "v0.6.0", "--preview", "--save-selection"), 0, self.output)
        self.assertIn("apply saves the release overlay in .env", self.output)
        self.assertIn("--release v0.6.0 --save-selection", self.output)
        self.assertEqual(env.read_bytes(), before)

        self.assertEqual(self.run_update("--release", "v0.6.0", "--save-selection"), 0, self.output)
        self.assertIn("previous line: COMPOSE_FILE=compose.yaml:compose.secrets.yaml", self.output)
        self.assertEqual(env.read_text(), before.decode().replace(
            "COMPOSE_FILE=compose.yaml:compose.secrets.yaml:deployment/customer.yaml",
            "COMPOSE_FILE=" + new))
        self.assertEqual(env.stat().st_mode & 0o777, 0o640)
        self.assertNotIn("CANARY-ENV-SECRET", self.output)
        up = [c for c in self.calls if c["args"][:3] == ["compose", "up", "-d"]]
        self.assertEqual(len(up), 1)
        self.assertEqual((self.fixture / "running-image").read_text(), NEW_IMAGE)
        # Saved: the next run needs no confirmation.
        self.assertEqual(self.run_update("--release", "v0.6.0"), 0, self.output)

    def test_shell_compose_file_without_overlay_blocks(self):
        self.selection["COMPOSE_FILE"] = "compose.yaml:compose.secrets.yaml:deployment/customer.yaml"
        self.assert_blocked("this shell exports COMPOSE_FILE", "--save-selection")

    def test_failure_before_downtime_restores_the_compose_file_line(self):
        (self.repo / "compose.release.yaml").unlink()
        env = self.save_selection_in_env("compose.yaml:compose.secrets.yaml:deployment/customer.yaml")
        before = env.read_bytes()
        runtime = self.repo / "secrets/runtime"
        runtime.chmod(0o500)
        self.addCleanup(runtime.chmod, 0o700)
        self.assertNotEqual(self.run_update("--release", "v0.6.0", "--save-selection"), 0, self.output)
        self.assertIn("restored the previous COMPOSE_FILE line", self.output)
        self.assertEqual(env.read_bytes(), before)
        self.assertEqual(env.stat().st_mode & 0o777, 0o640)
        self.assertFalse(any(c["args"][:3] == ["compose", "up", "-d"] for c in self.calls))

    def test_pull_failure_changes_nothing(self):
        before = self.snapshot()
        self.assertNotEqual(self.run_update("--release", "v0.6.0", pull_rc=5), 0, self.output)
        self.assertIn("Nothing was changed", self.output)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(any(c["args"][:3] == ["compose", "up", "-d"] for c in self.calls))

    def test_failures_after_checkout_name_recovery_without_recovering(self):
        self.assertNotEqual(self.run_update("--release", "v0.6.0", up_rc=17), 0, self.output)
        for text in ("RECOVERY", "no automatic recovery", "git checkout master     # the branch at " + self.old,
                     "no release set was installed before", "openclaw-image-upgrade-and-state-backup"):
            self.assertIn(text, self.output)
        self.assertNotIn("update: done.", self.output)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.new)

    def test_secret_failure_after_checkout_keeps_gateway_running(self):
        # v0.6.0 adds the password file. A directory that cannot be written
        # passes preflight and fails preparation after the checkout.
        runtime = self.repo / "secrets/runtime"
        runtime.chmod(0o500)
        self.addCleanup(runtime.chmod, 0o700)
        self.assertNotEqual(self.run_update("--release", "v0.6.0"), 0, self.output)
        self.assertIn("could not prepare the secret files", self.output)
        self.assertIn("NOTHING WAS STOPPED", self.output)
        self.assertIn("git checkout master     # the branch at " + self.old, self.output)
        self.assertFalse(any(c["args"][:3] == ["compose", "up", "-d"] for c in self.calls))
        self.assertEqual((self.fixture / "running-image").read_text(), OLD_IMAGE)



if __name__ == "__main__":
    unittest.main()
