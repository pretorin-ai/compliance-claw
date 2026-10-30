# Contributing to Compliance Claw

Use this guide to change the repository. For customer setup and use, start with
the [README](README.md). Coding agents must also read [AGENTS.md](AGENTS.md).

Do not report vulnerabilities in public issues. Use the private contact in
[SECURITY.md](SECURITY.md). Remove secrets, customer data, and sensitive runtime
logs from public reports and PRs.

## Development setup

The repository uses Bash, Python standard-library scripts, and JavaScript
plugins. There is no root package install or `make check` command.

- Install Git, Bash, Python 3, and OpenSSL for host scripts.
- Container checks need Docker with `linux/amd64` support. On Apple Silicon,
  enable amd64 emulation. Use Compose 2.27.2 or newer: the host selection
  helper needs `docker compose config --environment` (v2.27.2), and the test
  overlays need the
  [`!override` tag](https://docs.docker.com/reference/compose-file/merge/#replace-value) (v2.24.4).
- Node tests can use the runtime image. A separate host Node installation is
  not required for those commands.
- Image builds need network access to pinned base images, release assets, and
  packages. Offline tests need those images to exist first.

Fork the public repository if you need a place to push. Clone your fork or the
upstream repository, then create a branch from current `master`:

```sh
git clone https://github.com/pretorin-ai/compliance-claw.git
cd compliance-claw
git switch -c codex/your-change
```

Read the issue, current files, and working diff before editing. Preserve local
work. Keep `.env`, `efforts.yaml`, `secrets/`, and `workspace/` out of commits.
Do not copy customer state into a test checkout.

## How to build a candidate image

Build from the repository root. This does not start a gateway:

```sh
docker compose -f compose.yaml -f compose.build.yaml build
```

The build overlay uses `compliance-claw:local` and a development image version.
The default `compose.yaml` pulls a released digest; it does not build local code.
Check the selected files before a test. A test of the published image does not
verify your change.

For an isolated bootstrap path, follow the next section and run
`bash scripts/bootstrap.sh --build` there. If a build fails, inspect its failed
step and the pins in `versions.env`; do not bypass checksum or signature checks.
If Docker cannot run amd64, use a host with that support.

## Isolated container testing

A Compose project name isolates named volumes and containers. It does not
isolate host bind mounts, `.env`, secret files, or target repositories.

Use a disposable worktree or clone with no customer files. From your development
checkout, make a worktree at a new path, then prepare test-only files there:

Commit your candidate first if it must be present in this detached worktree.
Clear inherited path overrides such as `CC_EFFORTS_FILE`, `CC_TARGETS_DIR`, and
`COMPLIANCE_CLAW_SECRET_DIR`. Check shell settings for real credentials before
using this example.

```sh
git worktree add --detach ../compliance-claw-test HEAD
cd ../compliance-claw-test
export COMPOSE_PROJECT_NAME=cc-contributor-test
export CC_TEST_PORT=18990
export COMPOSE_FILE=compose.yaml:compose.build.yaml:compose.efforts.yaml:compose.test.yaml:compose.test-env.yaml
scripts/clawctl migrate --name ci-effort --slack-channel-id C0000000CI
mkdir -p secrets/runtime/pretorin workspace/targets
printf '%s\n' 'OPENCLAW_GATEWAY_TOKEN=canary-contributor-test-only' > .env.test
```

Choose a unique project name and an unused port for concurrent tests. Clear any
real credentials from the test environment. The fixture has no Pretorin, model,
GitHub, or Slack key.

Before starting containers, inspect the rendered mounts, port, image, and
environment with `docker compose config`. They must refer only to this checkout
and its test fixtures. Then, when the change needs image/runtime checks:

```sh
bash scripts/bootstrap.sh --build
bash scripts/smoke.sh --no-creds
```

`compose.test.yaml` replaces the published port. Setting `CC_TEST_PORT` without
that overlay does not change the base port. `compose.test-env.yaml` replaces the
legacy `.env` input with `.env.test`. Never combine the test-env overlay with
`compose.secrets.yaml`: the file-secret overlay removes the legacy env file.

For file-secret tests, use temporary canary files and the dedicated scripts
below. They prepare their own fixtures. Do not copy deployment credentials.
Builds and managed Slack package installation can need network access even
when no real service credential is used. `--no-creds` does not mean offline.

After testing, keep the same checkout, project, and overlay selection and run:

```sh
docker compose down -v
```

This deletes only that disposable project's named volumes. Do not use it against
a customer deployment. Keep failed-test logs for diagnosis, with secrets removed.
Remove the test worktree only after checking that it has no work you need.

## Test selection

Choose checks for the affected behavior. The
[build workflow](.github/workflows/build.yml) is the CI command authority.
Use the current branch's scripts; do not assume a test from another branch exists.

| Change | Relevant existing checks | Requirements and limits |
| --- | --- | --- |
| Target declaration | `python3 scripts/parse-targets.py --self-test` | Python 3; no container or network. |
| Effort schema/credentials | `python3 scripts/parse-efforts.py --self-test` | Python 3; validates rules, not runtime secret delivery. |
| Config patch | `python3 scripts/openclaw-patch.py --self-test` | Python 3; no running gateway. |
| `clawctl` | `bash scripts/clawctl --self-test` | Host tools; uses stub Docker and temporary files. |
| Host image update | `python3 scripts/test-update.py` | Host tools; runs the real updater with isolated Git and Docker stubs. Does not prove live readiness or Compose merging. |
| Saved deployment selection | `python3 scripts/test-update-compose.py --selection-only` | Real Compose CLI, no daemon, no credentials; covers saved/explicit settings, restored volumes, secret initialization and refusals. |
| Host image update with Compose | `python3 scripts/test-update-compose.py LOCAL_IMAGE OTHER_LOCAL_IMAGE` | Two cached images with `sh`, `sleep`, and `test`; synthetic containers, two disposable projects, no registry or service credentials. Does not run OpenClaw or prove channel/MCP operation. |
| Release set and selection | `python3 scripts/release-assets.py --self-test`; `python3 scripts/test-release-render.py` | Python 3, Git, and the real Compose CLI; no daemon, pull, or credential. Inert digests and the v0.5.2 tag fixtures. Does not run the release workflow, publish, or prove a pull. |
| Guided installer | `python3 scripts/test-install.py` | Host tools; runs the real installer, secret-file script, parsers and `clawctl migrate` with Docker, bootstrap and other `clawctl` stubs. Proves input, order, refusal and rerun rules only; no pull, clone, gateway or service check. |
| Target sync | `bash scripts/sync-targets.sh --self-test` | Bash, Git, Python 3; creates temporary local repositories. |
| Shell diagnostic text | `python3 scripts/lint-heredocs.py scripts/*.sh` | Local static check; not a separate build CI step. |
| CLI updater input | `bash scripts/pretorin-update.sh --self-test` | Docker and the candidate build overlay; the wrapper runs the in-image script. |
| CLI updater result and activation rules | Node command below | Simulated installer, restart, MCP, and Slack boundaries; not live activation proof. |
| Managed Slack rules | Node command below | Candidate image; network disabled; not live Slack proof. |
| Gateway shutdown | `bash scripts/test-gateway-stop.sh compliance-claw:local` | Candidate image; synthetic drain, isolated volumes, no network. |
| File-secret delivery | `bash scripts/test-file-secrets.sh compliance-claw:local` | Candidate image; temporary canary secrets. |
| Native proxy/local maintenance | `bash scripts/test-proxy-auth.sh compliance-claw:local` | Candidate image; no network or published ports; native requests with synthetic state and password. |
| Effort credential delivery and local records | `bash scripts/test-effort-credentials.sh compliance-claw:local` | Candidate image; canary credentials, native Plan/preflight reads and resume, stopped-record copy/restore, restart and replacement. Synthetic API, no live platform proof. |
| Fresh Slack seed | `bash scripts/test-fresh-slack-seed.sh` | Builds an isolated deployment; no live Slack exchange. |
| Integrated runtime | `bash scripts/smoke.sh --no-creds` | Disposable project and fixtures above; writes test state. |
| Documentation/templates | Links, anchors, front matter, and command/source checks | Run changed examples only where needed. No artificial tests or full image build solely for prose. |

Run the Node tests with the candidate image, from the repository root:

```sh
docker run --rm --platform linux/amd64 --network none \
  --mount "type=bind,src=$PWD,dst=/tests,readonly" \
  --entrypoint node compliance-claw:local --experimental-vm-modules --test \
  /tests/scripts/managed-slack.test.mjs /tests/scripts/pretorin-update.test.mjs
```

For updater self-tests, select `compose.build.yaml` in the isolated stack so the
wrapper tests the candidate, not the released image. Tests with their own
fixtures can still need a built image. Read each script's requirements first.

Smoke Section A needs no service credentials. Section B runs only when a supplied
Pretorin key authenticates. It is optional for public contributions. Without a
write-posture flag, it attempts no platform write. `--expect-read-only` attempts
a write and requires rejection; a wrongly scoped key can still permit it.
`--test-write-enabled` requires success and can create a real platform record.
Use only an approved test account/scope for either flag.

## Contribution process

1. Search existing issues and PRs. Use the bug or change-request template for
   public work; use the private security contact for vulnerabilities.
2. Agree on scope for substantial changes. Keep the diff focused. Add meaningful
   regression tests for runtime fixes where practical. Explain test limits or
   why a test is impractical. Update affected documentation.
3. Run relevant checks. Review the full diff and `git diff --check`. Use simple
   STE English. Do not change tests, thresholds, or safety checks to hide failures.
4. Open a PR against `master`. State the problem, result, related issue, checks
   and observed results, skips, and state/credential/recovery effects. Address
   review findings and report CI separately from local verification.

No gstack skill, private service account, or specific AI tool is required to
contribute. Optional skill guidance is in [AGENTS.md](AGENTS.md#optional-gstack-skills).
There is no universal coverage target here: tests must check the changed behavior.

Publishing a release is a separate maintainer action. Follow
[How to publish a release](docs/releasing.md). An ordinary documentation PR does
not change `IMAGE_VERSION`, the image digest, or dependency pins.
