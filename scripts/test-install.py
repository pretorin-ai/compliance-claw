#!/usr/bin/env python3
"""Run the guided installer with isolated command stubs.

The real installer, init-file-secrets.sh, compose-selection.sh, parsers,
release-assets.py and `clawctl migrate` run against a temporary Git checkout
with a fixture release set made by the real helper. Docker, bootstrap.sh and
the other clawctl commands are stubs that record their calls. These tests prove
input handling, ordering, refusals and rerun preservation only. They do not
prove an image pull, a clone, Compose merging, gateway startup, a provider or
Pretorin call, a customer task, or release authenticity. Every release set is
unsigned today and the real helper refuses it (exit 6); one test runs the real
helper to prove the installer stops there. The other tests replace the helper
in the fixture checkout with HELPER_SHIM, which admits the unsigned fixture and
serves `fetch` from a local directory. CC_TEST_INSTALL_SCRIPT can select
another script to show that a test rejects a removed check.
"""
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(os.environ.get("CC_TEST_INSTALL_SCRIPT", ROOT / "scripts/install.sh"))
SYSTEM = "7b74d8f3-d77c-49e4-8792-c372dd154d38"
VERSION = "9.9.9"
IMAGE = "ghcr.io/pretorin-ai/compliance-claw:%s@sha256:%s" % (VERSION, "c" * 64)
DEFAULT_SELECTION = "compose.yaml:compose.release.yaml:compose.secrets.yaml:compose.efforts.yaml"
RELEASE_FILES = ("compliance-claw-release.json", "compose.release.yaml")
GIT = ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
       "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
CANARIES = {
    "pretorin": "CANARY-PRETORIN-DO-NOT-PRINT",
    "openai": "CANARY-OPENAI-DO-NOT-PRINT",
    "slack-app": "CANARY-XAPP-DO-NOT-PRINT",
    "slack-bot": "CANARY-XOXB-DO-NOT-PRINT",
}
SELECTION_KEYS = ("COMPOSE_FILE", "COMPOSE_PATH_SEPARATOR", "COMPOSE_PROJECT_NAME",
                  "COMPOSE_PROFILES", "COMPLIANCE_CLAW_SECRET_DIR")

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
tool = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
if tool == "stub.py":
    tool, a = a[0], a[1:]
fixture = pathlib.Path(os.environ["FIXTURE"])
settings = json.loads((fixture / "settings.json").read_text())
with (fixture / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"tool": tool, "args": a,
        "COMPOSE_FILE": os.environ.get("COMPOSE_FILE"),
        "placed": os.path.exists("compose.release.yaml")}) + "\n")
def fail(key):
    if settings.get(key) is not None:
        print("fixture: " + key, file=sys.stderr)
        sys.exit(settings[key])
def selection():
    values = {}
    if os.path.exists(".env"):
        for line in open(".env"):
            k, _, v = line.rstrip("\n").partition("=")
            if k in SELECTION_KEYS:
                values[k] = v.strip('"').strip("'")
    for k in SELECTION_KEYS:
        if k in os.environ:
            values[k] = os.environ[k]
    return values
SELECTION_KEYS = %s
if tool == "uname":
    print(settings.get("os", "Linux") if a == ["-s"] else settings.get("arch", "x86_64"))
elif tool == "findmnt":
    print(settings.get("fstype", "ext4"))
elif tool == "bootstrap":
    fail("bootstrap_rc")
    if not os.path.exists(".env"):
        shutil.copyfile(".env.example", ".env")
elif tool == "clawctl":
    fail(a[0] + "_rc")
    if a[0] == "plan":
        print("clawctl: fleet")
elif tool == "docker":
    if a == ["info"]: fail("info_rc")
    elif a[:2] == ["info", "--format"]: print(settings.get("daemon_arch", "x86_64"))
    elif a == ["compose", "version", "--short"]: print(settings.get("compose", "2.27.2"))
    elif a == ["compose", "config", "--environment"]:
        for k, v in selection().items(): print(k + "=" + v)
    elif a in (["compose", "config", "--format", "json"],
               ["compose", "--profile", "cli", "config", "--format", "json"]):
        image = settings.get("image", %r)
        print(json.dumps({"services": {"openclaw": {"image": image},
            "cli": {"image": image, "environment": {"SECRET": "CANARY-CONFIG-DO-NOT-PRINT"}}}}))
    elif a[:2] == ["image", "inspect"]: fail("image_rc")
    elif a[:2] == ["manifest", "inspect"]: fail("manifest_rc")
    elif a == ["compose", "ps", "--quiet", "openclaw"]: print(settings.get("cid", "c" * 12))
    elif a[:2] == ["inspect", "--format"]: print(settings.get("health", "running healthy"))
    elif a[:4] == ["compose", "exec", "-T", "openclaw"]:
        assert a[5:] == ["openclaw", "models", "status", "--check"], a
        fail("model_rc")
    else: sys.exit("unexpected docker command: " + repr(a))
else:
    sys.exit("unexpected tool: " + tool)
''' % (repr(SELECTION_KEYS), IMAGE)

CLAWCTL = '''#!/usr/bin/env bash
python3 "$FIXTURE/stub.py" clawctl "$@" || exit $?
[ "$1" != migrate ] || exec bash "$(dirname "$0")/clawctl.real" "$@"
'''
# TEST ONLY. Stands in for the signature gate, which no release can pass yet,
# and records each call so a test can show the installer never relaxes it.
HELPER_SHIM = '''#!/usr/bin/env python3
import json, os, shutil, sys
a = sys.argv[1:]
with open(os.path.join(os.environ["FIXTURE"], "helper.jsonl"), "a") as f:
    f.write(json.dumps(a) + "\\n")
if a[:1] == ["fetch"]:
    shutil.copytree(os.environ["CC_TEST_FETCH_FROM"], a[a.index("--dir") + 1])
    sys.exit(0)
if a[:1] == ["check"]:
    a = ["check", "--allow-unsigned"] + a[1:]
real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "release-assets.real.py")
os.execv(sys.executable, [sys.executable, real] + a)
'''
BOOTSTRAP = '''#!/usr/bin/env bash
exec python3 "$FIXTURE/stub.py" bootstrap "$@"
'''


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cc-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "checkout"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.root / "scripts/install.sh")
        for name in ("compose-selection.sh", "init-file-secrets.sh",
                     "parse-efforts.py", "parse-targets.py", "onboard-lib.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        shutil.copyfile(ROOT / "scripts/release-assets.py", self.root / "scripts/release-assets.real.py")
        (self.root / "scripts/release-assets.py").write_text(HELPER_SHIM)
        shutil.copyfile(ROOT / "scripts/clawctl", self.root / "scripts/clawctl.real")
        (self.root / "scripts/clawctl").write_text(CLAWCTL)
        (self.root / "scripts/bootstrap.sh").write_text(BOOTSTRAP)
        for name in ("compose.yaml", "compose.secrets.yaml", "compose.efforts.yaml",
                     "compose.build.yaml", ".env.example"):
            shutil.copyfile(ROOT / name, self.root / name)
        (self.base / "stub.py").write_text(STUB)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for tool in ("docker", "uname", "findmnt"):
            (self.bin / tool).symlink_to(self.base / "stub.py")
        (self.base / "stub.py").chmod(0o700)
        self.keys = self.base / "keys"
        self.keys.mkdir(mode=0o700)
        for name, value in CANARIES.items():
            path = self.keys / name
            path.write_text(value + "\n")
            path.chmod(0o600)
        self.env = {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                    "HOME": str(self.base), "FIXTURE": str(self.base),
                    "TMPDIR": str(self.base), "CC_INSTALL_HEALTH_TIMEOUT": "0"}
        self.release = self.make_release(self.base / "release")

    def git(self, *args):
        return subprocess.run([*GIT, "-C", str(self.root), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def make_release(self, out, final=True, version=VERSION, digest="c" * 64):
        """A release set from the real helper, for the checkout's tagged commit."""
        if not (self.root / ".git").exists():
            self.git("init", "-q")
            self.git("add", "-A")
            self.git("commit", "-q", "-m", "fixture")
            self.git("tag", "v" + VERSION)
        sbom = self.base / f"sbom-{version}.spdx.json"
        sbom.write_text(json.dumps({"spdxVersion": "SPDX-2.3", "packages": [{"name": "x"}]}))
        helper = [sys.executable, str(self.root / "scripts/release-assets.real.py")]
        subprocess.run([*helper, "prepare", "--version", version, "--commit", self.git("rev-parse", "HEAD"),
                        "--repository", "pretorin-ai/compliance-claw",
                        "--image-repository", "ghcr.io/pretorin-ai/compliance-claw",
                        "--digest", "sha256:" + digest, "--sbom", str(sbom), "--out", str(out)],
                       check=True, capture_output=True)
        if final:
            subprocess.run([*helper, "finalize", "--dir", str(out)], check=True, capture_output=True)
        return out

    def rel(self, directory=None, version=VERSION):
        return ["--release", version, "--release-dir", str(directory or self.release)]

    # -- helpers -----------------------------------------------------------
    def declaration(self, channel=None, system=SYSTEM):
        args = ["--effort", "crm-soc2", "--system-id", system, "--framework-id", "soc2",
                "--target", "simple-crm=https://github.com/pretorin-ai/simple-crm.git#main"]
        return args + (["--slack-channel-id", channel] if channel else [])

    def keyfiles(self, *names):
        option = {"pretorin": "--pretorin-key-file", "openai": "--openai-key-file",
                  "slack-app": "--slack-app-token-file", "slack-bot": "--slack-bot-token-file"}
        return [x for n in names for x in (option[n], str(self.keys / n))]

    def full_args(self, *extra):
        return [*self.rel(), *self.declaration(), *self.keyfiles("pretorin", "openai"), "--yes", *extra]

    def run_install(self, args, env=None, **settings):
        (self.base / "settings.json").write_text(json.dumps(settings))
        (self.base / "calls.jsonl").write_text("")
        (self.base / "helper.jsonl").write_text("")
        p = subprocess.run(["bash", str(self.root / "scripts/install.sh"), *args],
                           env={**self.env, **(env or {})}, cwd=self.base,
                           text=True, capture_output=True, stdin=subprocess.DEVNULL)
        self.output = p.stdout + p.stderr
        self.calls = [json.loads(s) for s in (self.base / "calls.jsonl").read_text().splitlines()]
        self.check_no_secret()
        return p.returncode

    def helper_calls(self):
        return [json.loads(s) for s in (self.base / "helper.jsonl").read_text().splitlines()]

    def check_no_secret(self):
        self.assertNotIn("unexpected docker command", self.output, self.output)
        self.assertNotIn("unexpected tool", self.output, self.output)
        logged = json.dumps(self.calls)
        for value in (*CANARIES.values(), "CANARY-CONFIG-DO-NOT-PRINT"):
            self.assertNotIn(value, self.output)
            self.assertNotIn(value, logged)

    def order(self):
        return [c["tool"] + ":" + (c["args"] or [""])[0] for c in self.calls
                if c["tool"] in ("bootstrap", "clawctl")]

    def snapshot(self):
        return {str(p.relative_to(self.root)): (p.read_bytes() if p.is_file() else None, p.stat().st_mode)
                for p in sorted(self.root.rglob("*")) if ".git" not in p.relative_to(self.root).parts}

    def secret(self, name):
        return (self.root / "secrets/runtime" / name).read_text()

    def assert_refused_without_change(self, args, text, env=None, **settings):
        before = self.snapshot()
        self.assertNotEqual(self.run_install(args, env=env, **settings), 0, self.output)
        self.assertIn(text, self.output)
        self.assertIn("Nothing was changed", self.output)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(any(c["tool"] in ("bootstrap",) or
                             (c["tool"] == "clawctl" and c["args"][0] != "migrate") for c in self.calls))

    # -- success and rerun ---------------------------------------------------
    def test_fresh_install_delegates_in_order_and_reports_distinct_readiness(self):
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        self.assertEqual(self.order(), ["clawctl:migrate", "bootstrap:", "clawctl:validate",
                                        "clawctl:plan", "clawctl:apply"])
        for call in self.calls:
            if call["tool"] in ("bootstrap", "clawctl") and call["args"][:1] != ["migrate"]:
                self.assertEqual(call["COMPOSE_FILE"], DEFAULT_SELECTION)
                self.assertTrue(call["placed"], call)
        for name in RELEASE_FILES:
            self.assertEqual((self.root / name).read_bytes(), (self.release / name).read_bytes())
        self.assertIn("release set             ok", self.output)
        # The installer itself never relaxes the signature gate.
        self.assertTrue(self.helper_calls())
        self.assertFalse(any("--allow-unsigned" in c for c in self.helper_calls()))
        efforts = (self.root / "efforts.yaml").read_text()
        self.assertIn("name: crm-soc2", efforts)
        self.assertIn(f"system_id: {SYSTEM}", efforts)
        self.assertNotIn(str(self.base), efforts)
        self.assertNotIn("slack_channel_id", efforts)
        self.assertIn(f"COMPOSE_FILE={DEFAULT_SELECTION}\n", (self.root / ".env").read_text())
        self.assertEqual(self.secret("pretorin-api-key"), CANARIES["pretorin"] + "\n")
        self.assertEqual(self.secret("openai-api-key"), CANARIES["openai"] + "\n")
        for name in ("anthropic-api-key", "slack-app-token", "slack-bot-token", "github-readonly-pat"):
            self.assertEqual(self.secret(name), "")
        for text in ("gateway health          ok", "model configuration     ok",
                     "provider was not contacted", "writes not tested",
                     "first useful task       NOT VERIFIED", "effort agent: crm-soc2"):
            self.assertIn(text, self.output)

    def test_rerun_preserves_declaration_selection_and_credentials(self):
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        (self.root / "secrets/runtime/anthropic-api-key").write_text("")  # intentionally empty
        before = self.snapshot()
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        self.assertIn("already matches the given declaration", self.output)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(re.findall(r"(?m)^COMPOSE_FILE=", (self.root / ".env").read_text()), ["COMPOSE_FILE="])
        # A rerun with no declaration and no key files reuses everything too.
        self.assertEqual(self.run_install(["--yes"]), 0, self.output)
        self.assertEqual(self.snapshot(), before)
        # Without --release-dir, an incomplete placed set is refused, not guessed.
        (self.root / "compliance-claw-release.json").unlink()
        self.assertNotEqual(self.run_install(["--yes"]), 0, self.output)
        self.assertIn("failed its check", self.output)
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        self.assertEqual(self.snapshot(), before)

    def test_saved_custom_overlay_order_is_kept_and_not_saved_again(self):
        custom = DEFAULT_SELECTION + ":compose.customer.yaml"
        (self.root / ".env").write_text(f"COMPOSE_PROJECT_NAME=claw\nCOMPOSE_FILE={custom}")
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        self.assertEqual((self.root / ".env").read_text(), f"COMPOSE_PROJECT_NAME=claw\nCOMPOSE_FILE={custom}")
        for call in self.calls:
            if call["tool"] == "clawctl" and call["args"][0] == "apply":
                self.assertEqual(call["COMPOSE_FILE"], custom)

    def test_shell_selection_is_saved_once(self):
        custom = DEFAULT_SELECTION + ":compose.customer.yaml"
        env = {"COMPOSE_FILE": custom, "COMPOSE_PROJECT_NAME": "claw"}
        self.assertEqual(self.run_install(self.full_args(), env=env), 0, self.output)
        saved = (self.root / ".env").read_text()
        self.assertIn(f"\nCOMPOSE_FILE={custom}\n", saved)
        self.assertIn("\nCOMPOSE_PROJECT_NAME=claw\n", saved)
        self.assertEqual(self.run_install(self.full_args(), env=env), 0, self.output)
        self.assertEqual((self.root / ".env").read_text(), saved)

    def test_interrupted_bootstrap_keeps_inputs_and_rerun_completes(self):
        self.assertNotEqual(self.run_install(self.full_args(), bootstrap_rc=7), 0, self.output)
        self.assertIn("bootstrap.sh stopped", self.output)
        self.assertNotIn("clawctl:validate", self.order())
        self.assertNotIn("clawctl:apply", self.order())
        self.assertTrue((self.root / "efforts.yaml").exists())
        self.assertEqual(self.secret("pretorin-api-key"), CANARIES["pretorin"] + "\n")
        efforts = (self.root / "efforts.yaml").read_bytes()
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        self.assertEqual((self.root / "efforts.yaml").read_bytes(), efforts)

    def test_failed_validate_or_plan_never_applies(self):
        for key in ("validate_rc", "plan_rc"):
            with self.subTest(key=key):
                self.assertNotEqual(self.run_install(self.full_args(), **{key: 1}), 0, self.output)
                self.assertNotIn("clawctl:apply", self.order())

    def test_plan_without_yes_is_shown_but_not_applied(self):
        args = [a for a in self.full_args() if a != "--yes"]
        self.assertNotEqual(self.run_install(args), 0, self.output)
        self.assertIn("clawctl: fleet", self.output)
        self.assertIn("re-run with --yes", self.output)
        self.assertNotIn("clawctl:apply", self.order())

    def test_check_mode_validates_without_any_write(self):
        before = self.snapshot()
        self.assertEqual(self.run_install(["--check", *self.full_args()]), 0, self.output)
        self.assertIn("No file, container or volume was changed", self.output)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual([c["args"][0] for c in self.calls if c["tool"] == "clawctl"], ["migrate"])
        self.assertFalse(any(c["tool"] == "bootstrap" for c in self.calls))

    # -- Slack follows the declaration -------------------------------------
    def test_declared_slack_channel_needs_both_tokens_before_first_start(self):
        args = [*self.rel(), *self.declaration("C0123ABCDEF"), *self.keyfiles("pretorin", "openai"), "--yes"]
        self.assertNotEqual(self.run_install(args), 0, self.output)
        self.assertIn("routes Slack channels", self.output)
        self.assertFalse(any(c["tool"] == "bootstrap" for c in self.calls))
        self.assertEqual(self.run_install(args + self.keyfiles("slack-app", "slack-bot")), 0, self.output)
        self.assertIn("Slack: both tokens set", self.output)
        self.assertIn("slack_channel_id: C0123ABCDEF", (self.root / "efforts.yaml").read_text())

    # -- refusals before the first write ---------------------------------
    def test_host_refusals_stop_before_any_write(self):
        cases = (
            ({"os": "Darwin"}, "supports Linux amd64"),
            ({"arch": "aarch64"}, "supports Linux amd64"),
            ({"daemon_arch": "aarch64"}, "not x86_64"),
            ({"info_rc": 1}, "Docker daemon is not reachable"),
            ({"compose": "2.27.1"}, "too old or absent"),
            ({"compose": ""}, "too old or absent"),
            ({"fstype": "tmpfs"}, "does not persist"),
            ({"image_rc": 1, "manifest_rc": 1}, "docker login ghcr.io"),
        )
        for settings, text in cases:
            with self.subTest(settings=settings):
                self.assert_refused_without_change(self.full_args(), text, **settings)

    def test_newer_compose_versions_pass(self):
        for version in ("v2.27.2", "2.40.0-desktop.1", "5.1.3"):
            with self.subTest(version=version):
                self.assertEqual(self.run_install(["--check", *self.full_args()], compose=version), 0, self.output)

    def test_missing_host_tool_stops_before_any_write(self):
        farm = self.base / "farm"
        farm.mkdir()
        for tool in ("bash", "python3", "git", "docker", "uname", "findmnt", "grep", "sed",
                     "awk", "cut", "tr", "tail", "cat", "mktemp", "rm", "dirname", "stat", "env"):
            found = shutil.which(tool, path=self.env["PATH"])
            if found:
                (farm / tool).symlink_to(found)
        self.assert_refused_without_change(self.full_args(), "openssl", env={"PATH": str(farm)})

    def test_declaration_and_file_conflicts_stop_before_any_write(self):
        self.assert_refused_without_change(
            [*self.rel(), *self.declaration(system="crm-system"), "--yes"], "not a UUID")
        self.assert_refused_without_change([*self.rel(), "--yes"], "no declaration was given")
        self.assert_refused_without_change(
            [*self.rel(), *self.declaration("D0123ABCDEF"), "--yes"], "not valid")
        (self.root / "efforts.yaml").write_text(
            "efforts:\n  - name: crm-soc2\n    system_id: %s\n    framework_id: hipaa\n"
            "    credential_ref: default\n    targets:\n      - name: simple-crm\n"
            "        url: https://github.com/pretorin-ai/simple-crm.git\n        ref: main\n" % SYSTEM)
        self.assert_refused_without_change(self.full_args(), "with other values")
        (self.root / "efforts.yaml").write_text("efforts: [broken\n")
        self.assert_refused_without_change([*self.rel(), "--yes"], "is not valid")

    def test_selection_conflicts_stop_before_any_write(self):
        cases = (
            ({"COMPOSE_FILE": "compose.yaml:compose.release.yaml:compose.efforts.yaml"}, "does not select compose.secrets.yaml"),
            ({"COMPOSE_FILE": "compose.yaml:compose.release.yaml:compose.secrets.yaml"}, "does not select compose.efforts.yaml"),
            ({"COMPOSE_FILE": DEFAULT_SELECTION + ":compose.build.yaml"}, "local build overlay"),
            ({"COMPOSE_FILE": "compose.secrets.yaml:compose.yaml:compose.efforts.yaml"}, "does not start with compose.yaml"),
            ({"COMPOSE_FILE": "compose.yaml:compose.secrets.yaml:compose.efforts.yaml"}, "directly\n    after compose.yaml"),
            ({"COMPOSE_FILE": "compose.yaml:compose.secrets.yaml:compose.release.yaml:compose.efforts.yaml"}, "directly\n    after compose.yaml"),
        )
        for env, text in cases:
            with self.subTest(env=env):
                self.assert_refused_without_change(self.full_args(), text, env=env)
        (self.root / ".env").write_text(f"COMPOSE_FILE={DEFAULT_SELECTION}\n")
        self.assert_refused_without_change(
            self.full_args(), "this shell exports COMPOSE_FILE",
            env={"COMPOSE_FILE": DEFAULT_SELECTION + ":compose.customer.yaml"})

    def test_credential_source_conflicts_never_overwrite(self):
        (self.keys / "pretorin").chmod(0o644)
        self.assert_refused_without_change(self.full_args(), "can be read by other users")
        (self.keys / "pretorin").chmod(0o600)
        secrets = self.root / "secrets/runtime"
        secrets.mkdir(parents=True)
        (secrets / "pretorin-api-key").write_text("CANARY-EXISTING-KEY")
        self.assert_refused_without_change(self.full_args(), "already holds a different value")
        self.assertNotIn("CANARY-EXISTING-KEY", self.output)
        self.assertEqual(self.secret("pretorin-api-key"), "CANARY-EXISTING-KEY")
        empty = self.keys / "empty"
        empty.write_text("")
        empty.chmod(0o600)
        self.assert_refused_without_change(
            [*self.rel(), *self.declaration(), "--pretorin-key-file", str(empty)], "not a readable, nonempty file")

    def test_secret_values_are_not_accepted_or_echoed_as_arguments(self):
        for arg in ("--pretorin-key=" + CANARIES["pretorin"], CANARIES["pretorin"]):
            with self.subTest(arg=arg[:14]):
                self.assertNotEqual(self.run_install([arg]), 0)
                self.assertIn("never arguments", self.output)
                self.assertFalse(self.calls)
        self.assertNotEqual(self.run_install(["--openai-key-file", "a", "--anthropic-key-file", "b"]), 0)

    # -- release set: refusals before any write or delegated script ---------
    def test_release_set_refusals_stop_before_any_write(self):
        self.assert_refused_without_change(self.full_args()[4:], "no release set was given")
        self.assert_refused_without_change(self.rel(version="9.9.8") + self.full_args()[4:], "expected 9.9.8")
        candidate = self.make_release(self.base / "candidate", final=False)
        self.assert_refused_without_change(self.rel(candidate) + self.full_args()[4:], "is a candidate")
        tampered = self.base / "tampered"
        shutil.copytree(self.release, tampered)
        overlay = tampered / "compose.release.yaml"
        overlay.write_text(overlay.read_text().replace("c" * 64, "d" * 64))
        self.assert_refused_without_change(self.rel(tampered) + self.full_args()[4:], "sha256")
        colon = self.base / "rel:x"
        shutil.copytree(self.release, colon)
        self.assert_refused_without_change(self.rel(colon) + self.full_args()[4:], "Compose path separator")
        self.assert_refused_without_change(self.full_args(), "would not run the release image",
                                           image="ghcr.io/example/other:1@sha256:" + "e" * 64)

    def test_real_helper_refuses_every_unsigned_release_before_any_write(self):
        shutil.copyfile(ROOT / "scripts/release-assets.py", self.root / "scripts/release-assets.py")
        self.assert_refused_without_change(self.full_args(), "is refused: it is not signed")
        self.assertIn("manual installation", self.output)
        self.assertNotIn("UNVERIFIED", self.output)

    def test_release_is_fetched_by_the_helper_when_no_directory_is_given(self):
        args = ["--release", VERSION, *self.full_args()[4:]]
        self.assertEqual(self.run_install(args, env={"CC_TEST_FETCH_FROM": str(self.release)}), 0, self.output)
        fetch = [c for c in self.helper_calls() if c[:1] == ["fetch"]]
        self.assertEqual(len(fetch), 1)
        self.assertNotIn(str(self.root), fetch[0][fetch[0].index("--dir") + 1])
        for name in RELEASE_FILES:
            self.assertEqual((self.root / name).read_bytes(), (self.release / name).read_bytes())

    def test_checkout_not_at_the_release_commit_is_refused(self):
        (self.root / "NOTE").write_text("later\n")
        self.git("add", "NOTE")
        self.git("commit", "-q", "-m", "later")
        self.assert_refused_without_change(self.full_args(), "not the source of the release")
        self.assertIn("Check out the release tag", self.output)

    def test_placed_set_from_another_release_is_not_replaced(self):
        self.assertEqual(self.run_install(self.full_args()), 0, self.output)
        # A valid set for the same tag that selects another digest.
        other = self.make_release(self.base / "other", digest="f" * 64)
        before = self.snapshot()
        self.assertNotEqual(self.run_install(self.rel(other) + self.full_args()[4:],
                                             image=IMAGE.replace("c" * 64, "f" * 64)), 0, self.output)
        self.assertIn("from another release", self.output)
        self.assertIn("Nothing was changed", self.output)
        self.assertEqual(self.snapshot(), before)

    # -- readiness ---------------------------------------------------------
    def test_readiness_failures_are_reported_and_not_called_success(self):
        cases = (
            ({"health": "running unhealthy"}, "gateway health          FAIL"),
            ({"health": "running starting"}, "gateway health          FAIL"),
            ({"cid": ""}, "gateway health          FAIL"),
            ({"model_rc": 1}, "model configuration     NOT READY"),
        )
        for settings, text in cases:
            with self.subTest(settings=settings):
                self.assertNotEqual(self.run_install(self.full_args(), **settings), 0, self.output)
                self.assertIn(text, self.output)
                self.assertIn("a local readiness check failed", self.output)
                self.assertIn("NOT VERIFIED", self.output)
                self.assertNotIn("install: done.", self.output)

    def test_expiring_model_auth_is_reported_but_not_a_failure(self):
        self.assertEqual(self.run_install(self.full_args(), model_rc=2), 0, self.output)
        self.assertIn("model configuration     EXPIRING", self.output)

    # -- hidden input --------------------------------------------------------
    def test_terminal_prompt_reads_keys_without_echo(self):
        (self.base / "settings.json").write_text("{}")
        (self.base / "calls.jsonl").write_text("")
        (self.base / "helper.jsonl").write_text("")
        master, slave = pty.openpty()
        proc = subprocess.Popen(["bash", str(self.root / "scripts/install.sh"), *self.rel(), *self.declaration()],
                                env=self.env, cwd=self.base, stdin=slave, stdout=slave,
                                stderr=slave, close_fds=True)
        os.close(slave)
        answers = [("Pretorin API key", CANARIES["pretorin"]), ("OpenAI API key", ""),
                   ("apply this plan", "y")]
        # Answer each prompt only after it appears, so the terminal never echoes
        # input that was typed before the installer turned echo off.
        output, seen, deadline = b"", 0, time.time() + 60
        while time.time() < deadline:
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            if answers and answers[0][0].encode() in output[seen:]:
                seen = len(output)
                os.write(master, answers.pop(0)[1].encode() + b"\n")
            if proc.poll() is not None and not ready:
                break
        proc.wait(timeout=10)
        os.close(master)
        self.output = output.decode(errors="replace")
        self.calls = [json.loads(s) for s in (self.base / "calls.jsonl").read_text().splitlines()]
        self.check_no_secret()
        self.assertFalse(answers, self.output)
        self.assertEqual(self.secret("pretorin-api-key"), CANARIES["pretorin"])
        self.assertEqual(self.secret("openai-api-key"), "")
        self.assertIn("clawctl:apply", self.order())


if __name__ == "__main__":
    unittest.main()
