# Compliance Claw

Compliance Claw is an OpenClaw runtime with Pretorin CLI integrated. Agents can
review mounted repositories and work with your Pretorin system. Use a configured
agent from a terminal or an optional communication channel such as Slack.

Compliance Claw is deliberately thin. Pretorin already provides the compliance
intelligence: the MCP tool surface and its own routing instructions, workflows,
recipes, source preflight, active recipe sets, plans. This repository supplies the runtime that
joins those to your code — a supply-chain-verified Pretorin binary, a configured
OpenClaw gateway, optional Slack integration, and the wiring that tells Pretorin which
repositories this deployment is about.

This is a POC. `docs/plans/phase1.md` … `phase5.md` record what was built, what was
verified, and what is deliberately not done yet. **Read [SECURITY.md](SECURITY.md)
before pointing this at anything that matters** — in particular the shared-channel
attribution limit and the unsandboxed-tool-execution boundary.

## Documentation

| Task | Start here |
| --- | --- |
| Install | [Requirements](#requirements), [Quickstart](#quickstart), and [image verification](docs/image-verification.md) |
| Administer the Claw | [Administrator guide](docs/administration.md), [effort schema](docs/efforts.md), and [secret delivery](docs/file-secrets.md) |
| Use an agent | [Agent commands](docs/file-secrets.md#docker-compose-exec-does-not-see-these-secrets), [repositories and target sync](docs/repositories.md), and [key permissions](#read-only-vs-write-enabled-keys) |
| Upgrade or recover | [Update, upgrade and recovery](docs/upgrade.md), [CLI updates](docs/upgrade.md#updating-the-pretorin-cli), and [troubleshooting](#troubleshooting) |
| Contribute | [CONTRIBUTING.md](CONTRIBUTING.md) and [coding-agent guide](AGENTS.md) |
| Report a vulnerability | Private reporting contact in [SECURITY.md](SECURITY.md) |

VM operators deploy and maintain the runtime, state, network, declared efforts,
repositories and file-based credentials. Claw administrators use verified native
UI controls without SSH access. Slack is optional: omit `slack_channel_id` for a
browser effort. Effort provisioning still needs the operator's `efforts.yaml`
and host `clawctl` commands; native New agent does not provision that scope.

See the [administrator guide](docs/administration.md) for edit paths and
[configuration ownership](docs/efforts.md#what-apply-does-to-the-openclaw-configuration)
for settings that apply retains or replaces. Historical plans under `docs/plans/`
are not guarantees for every current deployment.

## Status

The table below records earlier published-image and isolated validation.
Target synchronization and the fresh Slack-seeding fix were included in v0.5.1.
This checkout now pins v0.5.2. The table is not evidence that every current-source
change passed a live service test.

| | |
| --- | --- |
| Public-repository operation | **passed** |
| Slack connectivity, and a real message/reply round trip | **passed** |
| Read-only Pretorin key | **passed** |
| Write-enabled Pretorin key, through the recipe workflow | **passed** |
| Published image pulled by immutable digest | **passed** |
| Private GitHub repository support | **implemented; live validation deferred** |
| Target synchronization from the host | **passed** |
| Target synchronization from Slack | **passed — command and conversational routes** |

Three honest caveats, not passes:

- **Private repositories:** the path is complete and its refusal paths, parser
  contract and credential hygiene are verified, but the live happy path needs
  Pretorin **organisation-owner** permission to create and install the GitHub App.
  That validation is deferred to an owner, post-merge, against the published image.
  The step-by-step runbook is in [docs/repositories.md](docs/repositories.md#private-repositories).
- **Slack:** validated with an existing, manually created app. The committed
  `slack/app-manifest.json` is the reproducible setup path for a *new* app and is
  reviewed, but importing it from scratch was not separately tested.
- **Target synchronization:** the engine, its refusals, the global lock and the
  credential hygiene are gated offline against real local repositories. Both the
  deterministic Slack command and conversational tool route were then exercised
  successfully against the fresh local deployment. The remaining live gap is a
  private clone over HTTPS with a fine-grained PAT. Details and evidence:
  [docs/plans/target-sync.md](docs/plans/target-sync.md).

The image is **unsigned**. Its integrity controls are the digest pin, the
per-release SBOM, the release-time vulnerability scan, and documented release
provenance — see [Verifying the image you pulled](docs/image-verification.md).

### Source versus the published image

This checkout pins the published **v0.5.2** image but its host scripts and
guides are newer. Script changes (saved Compose selection, the 720-second
update wait, secret-file creation during update) apply as soon as you pull
`master`. Changes inside the image (efforts without a Slack channel, per-effort
records, proxy authentication, Slack CLI-update authority) arrive with the next
release, or now with `scripts/bootstrap.sh --build`.

## Requirements

- Docker Compose **v2.27.2 or newer**. The host commands resolve the saved
  deployment selection with `docker compose config --environment`, added in
  v2.27.2. The file-secret overlay uses the `!reset`
  tag introduced in v2.24.0; older versions may retain `.env` unexpectedly.
- Docker Desktop (or another daemon) with **linux/amd64** support. Upstream ships
  no linux/arm64 Pretorin binary, so on Apple Silicon this runs emulated — enable
  Rosetta for amd64 in Docker Desktop settings. `bootstrap.sh` checks before it
  does anything slow.
- `git`, `python3`, `openssl`. On macOS all three come with the Command Line
  Tools, which `git` already requires. No PyYAML, no `jq`, no `gh`, nothing to
  `pip install`.
- Access to the GHCR package. It is not public, so `docker login ghcr.io` first.
- A Pretorin API key. A read-only key supports onboarding and read operations.
  Platform writes need the relevant write scopes. The platform enforces the
  key permissions; this repository does not add a local permission mode.
- A model-provider key (OpenAI or Anthropic), or an OpenAI device-code login.
- Optional: a Slack workspace where you can install an app, and a read-only
  GitHub App if you want to review private repositories.

## Quickstart

### Guided installation on a Linux amd64 VM

`scripts/install.sh` guides a VM operator through a first installation of one
chosen release. It does not build source. It checks the release set with
`scripts/release-assets.py`, then calls the existing host scripts in this order:
`clawctl migrate` for a new declaration, `init-file-secrets.sh`, `bootstrap.sh`,
`clawctl validate`, `clawctl plan` and, after your approval, `clawctl apply`.
It needs a release that publishes a release set
([checking a release set](docs/image-verification.md#checking-a-release-set)).

> **Not available yet.** Every published release set is unsigned, and no
> signature verifier exists. The installer refuses an unsigned set before any
> write, and it has no option to accept one. Until signing and verification
> exist, use the [manual installation](#manual-installation). The steps below
> describe the guided route for that time.

**1. Get the release and check it before you run any script from it.** Use
only Git and a SHA-256 tool that are already on the VM:

```sh
git clone https://github.com/pretorin-ai/compliance-claw.git ~/compliance-claw
git -C ~/compliance-claw switch --detach vX.Y.Z
mkdir ~/cc-release && cd ~/cc-release
# Download the two assets from the vX.Y.Z GitHub release page, for example:
curl -fLO https://github.com/pretorin-ai/compliance-claw/releases/download/vX.Y.Z/compliance-claw-release.json
curl -fLO https://github.com/pretorin-ai/compliance-claw/releases/download/vX.Y.Z/compose.release.yaml

grep -E '"(commit|stage|tag|version)"' compliance-claw-release.json
git -C ~/compliance-claw rev-parse 'vX.Y.Z^{commit}' 'HEAD^{commit}'
grep -A2 '"name": "compose.release.yaml"' compliance-claw-release.json
sha256sum compose.release.yaml        # macOS: shasum -a 256 compose.release.yaml
```

Continue only when `stage` is `final`, the tag and version are the release you
chose, both `rev-parse` lines equal `commit`, and the two SHA-256 values are
equal. These checks show that the clone, the record and the overlay agree. The
record is **not signed** and all of these files come from GitHub, so the checks
do not prove who published the release. A downloaded checker cannot prove its
own origin; signing is planned work. The installer repeats these checks with the
helper and adds the signature check, but the helper comes from the same clone.

**2. Run the installer.** Put each credential in a file that only you can read
(`chmod 600`). The installer copies a value into an empty secret file only. It
never accepts a value as an argument and never shows one. In a terminal, it asks
for a missing Pretorin or OpenAI key with hidden input.

```sh
cd ~/compliance-claw
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-github-username> --password-stdin

# Check the host, the release set, the existing files and image access. No writes.
# Without --release-dir, the helper downloads the set into scratch space.
scripts/install.sh --check --release X.Y.Z --release-dir ~/cc-release \
  --effort crm-soc2 --system-id <system-uuid> --framework-id soc2 \
  --target simple-crm=https://github.com/pretorin-ai/simple-crm.git#main \
  --pretorin-key-file ~/keys/pretorin --openai-key-file ~/keys/openai

# Install: run the same command without --check. The installer shows the plan
# and asks before apply; add --yes when no terminal is attached.
```

The installer stops before any write when the release set fails a check (an
unsigned set included), the checkout is not the release commit, or a later
Compose overlay selects another image. It places `compose.release.yaml` and `compliance-claw-release.json` in
the checkout and saves this selection in `.env`:
`COMPOSE_FILE=compose.yaml:compose.release.yaml:compose.secrets.yaml:compose.efforts.yaml`.
A saved selection must list `compose.release.yaml` directly after
`compose.yaml`; other overlays keep their order.

Options:

- `--private-target NAME=URL[#BRANCH]` declares a private repository. Supply its
  credential first; see [private repositories](docs/repositories.md#private-repositories).
- `--slack-channel-id C...` routes the effort to a Slack channel. Then give
  `--slack-app-token-file` and `--slack-bot-token-file` too: the installer stops
  before the first start if a declared channel has no tokens. Omit the channel
  for browser-only access.
- `--anthropic-key-file` replaces `--openai-key-file`. Then select an Anthropic
  model in the Control UI ([providers and models](docs/administration.md#providers-and-models)).
- With an existing `efforts.yaml`, omit the declaration options. The installer
  uses the file as it is. After the first run, you can omit `--release-dir`;
  the installer checks the placed release files again.

The installer reports an exact conflict and changes nothing when an existing
file disagrees with an input. It keeps `efforts.yaml`, `.env`, the saved
Compose selection with its overlay order, the placed release files, clones, and
every secret file, empty or not. After an interruption, fix the reported cause
and run the same command again. To rotate a credential, use the
[rotation procedure](docs/file-secrets.md#rotation).

The last stage reports separate results: gateway health, a local model
configuration check (the provider is not contacted), the Pretorin scope probe
from `clawctl validate` (writes are not tested), the release set check, and the
first useful task. The installer cannot do that task. A healthy
container or a saved key does not show that the Claw works. The Claw
administrator then follows the
[operator handoff checklist](docs/administration.md#operator-handoff-checklist) to test
the model connection and run one approved task. If a stage stops, the
installer names it; see [if a setup stage fails](docs/administration.md#if-a-setup-stage-fails).
Use [update, upgrade and recovery](docs/upgrade.md) for problems after installation.

The installer does not set up the VM, Docker, the network, an identity provider
or a model service. Providers, models, external MCP connections and agent
settings stay in the native Control UI. A custom endpoint
([internal AI endpoint](docs/administration.md#internal-ai-endpoint-with-a-private-ca))
or another mounted credential stays an operator task. The VM needs the
[network connections](docs/administration.md#network-connections) for the
registry, GitHub and the services you use. For other hosts, a custom selection, or
full control of each step, use the manual installation below.

### Manual installation

```sh
# 0. authenticate to the registry (the package is not public)
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-github-username> --password-stdin

# 1. select the file-backed credential path (recommended, and what Azure needs)
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml

# 2. declare what you are reviewing, for which compliance scope, and where it
#    uses a Slack channel, if needed. efforts.yaml is what the deployment reads.
cp efforts.example.yaml efforts.yaml
vi efforts.yaml                  # system_id, framework_id, targets; optional slack_channel_id
scripts/clawctl validate --schema-only
#    Do not edit the committed targets.yaml for a new installation. Only an
#    existing single-effort deployment converts its targets.yaml:
#    scripts/clawctl migrate --name crm-soc2 --slack-channel-id C0123ABCDEF

# 3. clone the targets, PULL the released image, create the secret files
scripts/bootstrap.sh             # generates the gateway token; writes NO secret to .env

# 4. paste values into the files bootstrap just created — nothing goes in .env
vi secrets/runtime/pretorin-api-key
vi secrets/runtime/openai-api-key         # matches the shipped default model
# OR use anthropic-api-key, then select an Anthropic model before first use:
# docker compose run --rm cli openclaw models set anthropic/<model>
#  optional: slack-app-token, slack-bot-token
#    (SLACK_CHANNEL_ID is NOT needed: which channels are served comes from each
#     effort's slack_channel_id in efforts.yaml)
#  full checklist and per-service delivery matrix: docs/file-secrets.md

# 5. apply the effort configuration. With no gateway running, apply first runs
#    native Doctor; this can change native configuration before effort onboarding.
#    It then onboards each effort and generates agents, Slack bindings, and MCP
#    servers. Do not `up -d` first: apply starts the gateway on the result.
scripts/clawctl plan             # previews effort changes; starts no containers
scripts/clawctl apply

# 6. the gateway is now running on http://127.0.0.1:18789
docker compose ps

# anything one-off, in the same image with the same mounts:
docker compose run --rm cli pretorin --json context show
# To invoke an effort agent, use the file-secret-aware command in
# docs/file-secrets.md under "docker compose exec does not see these secrets".
```

### Save deployment settings

Save non-secret selection in the repository-root `.env` for later shells. For
example, add these lines to the existing file; do not replace its other settings:

```dotenv
COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml
COMPOSE_PROJECT_NAME=compliance-claw
COMPLIANCE_CLAW_SECRET_DIR=./secrets/runtime
```

Compose and the host setup, credential, plan/apply and update commands use this
selection. Explicit shell values override saved values. Keep custom overlays in
the required order. `COMPOSE_PATH_SEPARATOR` and `COMPOSE_PROFILES` also use native
Compose rules. A relative secret directory must start with `./` (or use an
absolute path). Never put credentials in these selection fields.

Deployment commands require the Compose CLI. Local selection and `clawctl plan`
do not need a running Docker daemon. Help, migration and `validate --schema-only`
do not need Compose; schema-only validation does not check credentials. An
invalid saved selection stops before host writes or container startup.

The legacy path keeps secret values in `.env`; it serves one effort and is
described in [Legacy path: secret values in `.env`](docs/file-secrets.md#legacy-path-secret-values-in-env).

**`exec openclaw`, not `run --rm cli`, for agent turns.** `openclaw agent` talks to the
gateway over `127.0.0.1:18789`, and the `cli` service is a *different container* with
nothing on its own loopback — so there it silently falls back to running the agent
embedded, where model resolution is stricter and fails with
`Unknown model: ...`. Setting `OPENCLAW_GATEWAY_URL` does not help; resolution
happens before dispatch. For configuration and MCP commands while the gateway
runs, use its namespace and the secret-loading entrypoint. See
[host command fallback](docs/administration.md#host-command-fallback).
A one-off CLI container can fail the native state-owner check against live state.

Two ordering rules, both of which bite silently if ignored:

- **Slack credentials must be in place before the first `up`** — in
  `secrets/runtime/slack-{app,bot}-token` on the recommended path, or in `.env` on
  the legacy one. Which channels are served comes from each effort's
  `slack_channel_id` in `efforts.yaml`, not from `.env`. The Slack half of the
  config is seeded once and never overwritten, so adding the tokens later does
  not update an existing config. Inspect the warning and keep the state. See
  [upgrade and recovery](docs/upgrade.md) before a configuration repair.
- **Onboard before `up`.** Onboarding writes host-local Pretorin state, and a
  running gateway keeps a per-session `pretorin mcp-serve` child that can serve
  the older view (the preflight artifact carries a 3600-second TTL). If you do
  onboard while the gateway is running:

  ```sh
  docker compose restart openclaw
  ```

  Not `openclaw mcp reload` from the `cli` service: that disposes cached MCP
  runtimes in the *calling* process only, so a one-off container disposes its own
  empty cache and exits, leaving the gateway's children untouched.

Check what you bound at any time, read-only:

```sh
scripts/clawctl validate         # per-effort rows: credential, mode, live probe
```

`code_repository` reporting **`degraded`** there is expected, not a failure: the
platform wants capabilities like `branch_protection` that a local checkout cannot
supply. Those need a Connected Source on the platform side, which is future work.

## Verifying what you pulled

Pull by digest, not by tag; the pair this checkout deploys is in
[compose.yaml](compose.yaml). A release can also carry a release set: a record,
a `compose.release.yaml` overlay that selects its digest, and the SBOM. It is
unsigned today, so `scripts/release-assets.py check` and the customer install
and update tools refuse it until signing and verification exist. The image and
the record are **unsigned**: the digest pin, the asset checksums, the per-release SBOM, the
release-time scan and recorded provenance are its integrity controls. Commands
and what they do and do not prove:
[Verifying the image you pulled](docs/image-verification.md).

## Repositories and targets

Targets are declared per effort in `efforts.yaml`; the single-effort
`targets.yaml` remains the legacy input to `scripts/clawctl migrate`. Public
repositories need no configuration.

### Private repositories

`private: true` is a flag only; no credential ever appears in a declaration. The
supported path is a read-only GitHub App created by an organisation owner; a
fine-grained PAT is the file-secret-path fallback for synchronizing from inside
the container. The runbook, error table and PAT limits:
[Repository access and synchronization](docs/repositories.md#private-repositories).

## Multiple compliance efforts

One deployment serves several. An **effort** is a named system/framework scope
with its own targets, its own named Pretorin credential, its own local Plan and
preflight records, and an optional Slack channel. The same system under SOC 2 and
under HIPAA is two efforts. Two efforts may also share one platform scope: Claw
keeps their local records under separate effort parents, while platform records
and API-key permissions stay shared under Pretorin authorization.

```text
One VM
└── one OpenClaw gateway, one Slack app
    ├── #soc2   (C0AAA…) → agent crm-soc2   → MCP pretorin-crm-soc2   → SOC 2 scope
    └── #hipaa  (C0BBB…) → agent crm-hipaa  → MCP pretorin-crm-hipaa  → HIPAA scope
```

Each agent gets its own workspace, sessions, memory, generated `AGENTS.md`, and a
repository view containing only its own targets. Every Pretorin MCP server runs
the **same** persistent CLI binary, so one `pretorin-update` moves the version for
every agent at once.

Efforts are declared in `efforts.yaml` and driven by one command:

```sh
scripts/clawctl migrate --name crm-soc2 --slack-channel-id C0123ABCDEF
scripts/clawctl credential add hipaa-key  # a per-effort key file, correct mode
scripts/clawctl validate                  # every effort, one table, one run
scripts/clawctl plan                      # the whole change; starts no containers
scripts/clawctl apply                     # onboard, generate, verify, or roll back
scripts/clawctl dm allow U0123ABCDEF --effort crm-soc2   # optional; DMs are off
```

`credential_ref` is a **name**, never a token, so `efforts.yaml` holds no secret.
`default` resolves to the key this deployment already has, so migrating creates no
new secret file.

**`efforts.yaml` is the runtime authority.** Once it exists, every target name is
resolved and scoped through it. `targets.yaml` survives as input to
`clawctl migrate` and as the legacy fallback: it stays mounted read-only in the
gateway so a deployment that has not migrated yet still has a working
`/target-sync`, and it is ignored entirely once `efforts.yaml` is present.

**What separates one effort from another, and what does not.** Each agent's tool
policy denies every other effort's Pretorin tools, and its instructions state a
fixed scope and refuse to switch. That is a tool-visibility and prompt boundary,
not a process or filesystem one — tool execution is unsandboxed and `mcp.servers`
is gateway-wide. The enforced boundary is the Pretorin key's own server-side
scopes and the platform's cross-scope write guard.

Full guide, including how to add a second effort, what you choose when you mint
each token, and the one-key-or-many trade-off:
**[docs/efforts.md](docs/efforts.md)**. The design and its measured evidence:
[docs/plans/effort-config.md](docs/plans/effort-config.md).

## Keeping targets up to date

Targets do not move on their own. `scripts/sync-targets.sh` fast-forwards clones
from the host or, through the same wrapper, from Slack (`/target-sync`). It never
resets, stashes or rewrites history. Outcomes, refusals, the writable mount and
the audit record: [Repository access and synchronization](docs/repositories.md#keeping-targets-up-to-date).

## Slack

Optional. Leave the Slack credentials empty and Slack is simply not used — the
config is then byte-identical to a Slack-less deployment.

**Two variables, or three, depending on which path you are on.** They are not
interchangeable, and the container tells you which set it is enforcing:

| | multi-effort (`efforts.yaml` present) | legacy single-effort |
|---|---|---|
| required | `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` | `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_CHANNEL_ID` |
| which channels are served | each effort's `slack_channel_id`, written by `clawctl apply` | the single `SLACK_CHANNEL_ID` |
| `SLACK_CHANNEL_ID` if set anyway | **ignored**, and the container says so — one owner per field | it *is* the configuration |

```
1. api.slack.com/apps/new -> Create New App -> From a manifest
   -> pick your workspace -> paste slack/app-manifest.json -> Create
2. Basic Information -> App-Level Tokens -> Generate Token and Scopes
   -> add connections:write            -> SLACK_APP_TOKEN   (xapp-...)
3. Install App -> Install to Workspace -> SLACK_BOT_TOKEN   (xoxb-...)
4. Invite the bot to each effort's channel, right-click it -> Copy link
   -> the C... at the end of the URL -> that effort's slack_channel_id
      in efforts.yaml (NOT .env: one channel per effort)
   Everyone in that channel can then run /compliance-claw ... in it, so channel
   membership is the access control. Only configured channels are served.
5. Supply the two tokens as secret files (recommended) or in .env (legacy).
   For a fresh installation, follow Quickstart with the tokens present before
   the first configuration seed. For an existing installation, keep the state
   and inspect its configuration and startup warnings before a repair.
```

For a **new** app, import the manifest rather than assembling scopes by hand — that
is the whole reason it is committed. It requests upstream's **minimal** socket-mode
scope set: **12 bot scopes instead of the recommended 23**, dropping files,
reactions, pins, group DMs, `emoji:read` and `usergroups:read`.

### Already have a Slack app? Reuse it.

**You do not need to create another one.** Any app with Socket Mode enabled, an
app-level token carrying `connections:write`, and a bot token works: supply its
two tokens the same way as any other secret (files on the recommended path, `.env`
on the legacy one), put each effort's channel id in `efforts.yaml`, and the rest of
this section applies unchanged. The manifest is
the reproducible path for a *new* app, not a requirement for an existing one.

Two things to know when reusing an older app. It probably carries the broader
*recommended* scope set, so it can read files, reactions and group DMs this
deployment never touches. And **separate, independent Claws should generally use
separate Slack apps** — Slack may deliver a given event to any one of an app's
Socket Mode connections, so two deployments sharing one app get ambiguous routing
and a message can be answered by whichever Claw happened to receive it.

### What lives where

See [Slack runtime administration](docs/administration.md#optional-slack) for
configuration, state, verification and network requirements. Keep the app
registration and reuse instructions above for initial app setup.

## The model

<a id="changing-the-model-on-an-existing-deployment"></a>

See [providers and models](docs/administration.md#providers-and-models) for native
controls, file-based credentials and the operator command fallback. Runtime model
selection is available; the `.env` file does not override the build-time seed.

## Read-only vs write-enabled keys

`PRETORIN_API_KEY` is the access-control boundary. Compliance Claw registers the
full Pretorin tool surface and does not second-guess it: what the agent can do is
whatever the key authorizes, enforced server-side.

| | Read-only key | Write-enabled key |
| --- | --- | --- |
| Bootstrap, onboarding, verification | works | works |
| Read frameworks, controls, recipes, plans | works | works |
| Assessment and gap analysis | works | works |
| Evidence upload, control status, risks, vendors | **rejected server-side** | works |
| Safe in a shared Slack channel | yes | **no — no attribution** |

Read-only covers everything except platform writes, because binding resolvers,
verifying them and provisioning recipes write only host-local state — the single
platform call is a *read* of the recommended source-kind profile.

**Switching to a write-enabled key is a deliberate act with real consequences.**
Any platform record the agent creates is attributed to the key, not to a person.
Evidence written through a recipe workflow carries repository URL, commit SHA,
repo-relative path and line range, so it is reviewable — but *who asked for it* is
not recorded. Platform-side scope approval is a separate prerequisite: without it
Pretorin answers `Scope is not approved with a confirmed scale yet`.

**The key's server-side scopes are the sole authorization boundary.** Compliance
Claw does no local permission filtering and has no "mode" to configure — a
read-only key gets platform rejections on write tools, a write-enabled key does
not, and both are supported paths.

`pretorin whoami` reports authentication but not scopes, so `scripts/smoke.sh`
cannot discover which kind of key it is holding. It therefore takes the expected
outcome as an argument — `--expect-read-only` or `--test-write-enabled` — and with
neither flag it never attempts a write at all. Those are test declarations, not
configuration.

## Updating the Pretorin CLI

The active CLI lives in the `pretorin-state` volume and survives image upgrades.
Move it with `scripts/pretorin-update.sh` from the host, or from Slack with
native administrator authority. Commands, authority requirements, activation and
the audit record: [Updating the Pretorin CLI](docs/upgrade.md#updating-the-pretorin-cli).

## Testing

Contributor test commands, prerequisites, and disposable container setup are in
[CONTRIBUTING.md](CONTRIBUTING.md#test-selection).

## Updating an existing deployment

```sh
scripts/update.sh
```

One command: fast-forward the checkout, pull the pinned image, restart the
selected gateway, verify, and report. What survives an update, the health wait,
refusals and the template warnings are in
[Routine deployment update](docs/upgrade.md#routine-deployment-update). For an
OpenClaw version change, back up both state volumes first:
[Update, upgrade and recovery](docs/upgrade.md).

## Resetting

`docker compose down -v` deletes both state volumes. It is a destructive
reset, not a repair step. See [Resetting (destructive)](docs/upgrade.md#resetting-destructive)
before using it.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `pull access denied` / `unauthorized` | The package is not public | `docker login ghcr.io`; a classic token needs `read:packages` |
| `deployment is not running the selected image` | Selection changed or repo pulled, deployment never restarted | `scripts/update.sh` |
| Gateway authentication fails at startup | Missing credential or invalid native auth configuration | Check the selected native authentication mode and its secret references. See [secret delivery](docs/file-secrets.md#native-proxy-authentication-and-local-maintenance). |
| Gateway exits 78 `Missing config` | Config missing or unreadable | Check logs, selected mounts, and file permissions. Preserve state and use [recovery guidance](docs/upgrade.md); do not delete volumes. |
| Slack never connects | Missing credentials, channel setup, or existing config without Slack | Inspect the Slack warning and current configuration; see [Slack](#slack) and [recovery](docs/upgrade.md). |
| Slack connects, bot never answers | Channel **name** instead of ID, or bot not invited | Use the `C...` ID; invite the bot; mention it explicitly |
| `Slack is only partially configured` (multi-effort) | one of the **two** tokens set | Both tokens are required together; the channels come from `efforts.yaml` |
| `Slack is only partially configured` (legacy) | 1 or 2 of the **three** variables set | All three are required together |
| `SLACK_CHANNEL_ID is set but IGNORED` | `.env` still carries it while `efforts.yaml` exists | Remove it from `.env`; `clawctl apply` owns the channel allowlist |
| `slack_channel_id ... is not a Slack channel id` | A name or a URL was used in `efforts.yaml` | Right-click channel → Copy link → the `C...` value |
| `slack_channel_id ... is a DM conversation id` | A `D...` id was used as an effort's home | Use the channel's `C...` id; DMs are `clawctl dm allow` |
| `slack_channel_id ... is a legacy G id` | A `G...` id is ambiguous (private channel vs MPIM) | Use the channel's `C...` id |
| `GITHUB_APP_ID is not set` on a private target | No App configured | Follow [private repositories](docs/repositories.md#private-repositories), or drop `private: true` |
| `/target-sync` says `missing_clone` | The target was added to `efforts.yaml` but never cloned | `scripts/clawctl apply` on the host — sync never clones |
| `/target-sync` says `dirty_refused` | Something wrote into the clone | `git -C workspace/targets/<name> status`; resolve it yourself, sync will not |
| `/target-sync` says `diverged_refused` | Upstream force-pushed, or the clone has local commits | `git -C workspace/targets/<name> log --oneline <branch> ^origin/<branch>` |
| `/target-sync` says `auth_failed` on a private target | No usable credential in the container | Put a fine-grained PAT in `secrets/runtime/github-readonly-pat` and use `compose.secrets.yaml` |
| `up` fails with `bind source path does not exist: …/github-readonly-pat` | Upgraded without creating the new secret file | `scripts/init-file-secrets.sh` — or use `scripts/update.sh`, which does it before stopping anything |
| `the GitHub App installation does not include:` | App not installed on that repo | Add it on the linked installation page |
| `exists but is not the root of a git repository` | Interrupted clone | Inspect and move the directory aside if needed, then re-run bootstrap. |
| `tracks a different remote` | the declared URL changed | Fix the URL, or move the directory aside |
| `code_repository` is `degraded` | Expected | Needs a platform Connected Source; future work |
| `Missing required scopes: write` | Read-only key, write tool | Correct behaviour — see "Read-only vs write-enabled" |
| `Scope is not approved with a confirmed scale yet` | Platform prerequisite | Approve scope setup on platform.pretorin.com |
| Agent answers with no sources bound | Wrong channel for the effort | Each agent serves one effort and refuses to switch; ask in that effort's own channel |
| Loaded plugin set differs after an upgrade | OpenClaw can change bundled and required provider plugins | Inspect the loaded set and compare it with your configured allowlist |
| `pretorin version` is newer than `versions.env` | The CLI was updated in place | Expected. `versions.env` pins the seed; `scripts/pretorin-update.sh --status` shows both |
| An image upgrade did not change the CLI | By design | The CLI lives in a volume. Use `scripts/pretorin-update.sh` |
| Updated the CLI but MCP still reports the old version | The gateway's MCP child is still the old process | `docker compose restart openclaw`, then check the next MCP call. `--status` reports the installed binary only |
| `/compliance-claw /pretorin-update` does nothing in Slack | Existing slash-command configuration or missing owner authority | Check startup warnings, the registered command name, and `commands.ownerAllowFrom`. Preserve state before configuration repair; see [CLI updates](docs/upgrade.md#updating-the-pretorin-cli). |

Logs and state:

```sh
docker compose logs -f openclaw
docker compose run --rm cli openclaw doctor
docker compose run --rm cli openclaw plugins inspect slack
scripts/clawctl validate                 # the efforts, credentials and channels
scripts/onboard-targets.sh --verify-only # LEGACY single-effort deployments only
```

## Releasing

Maintainers use [How to publish a release](docs/releasing.md): tag, prepare a
draft candidate, then publish the same bytes without a rebuild. Publishing is
separate from updating a customer deployment or its active Pretorin CLI. To learn
about new releases, use GitHub **Watch → Custom → Releases**.

## Notes

- Every pin lives in `versions.env`, with two documented carve-outs that cannot
  read a sourced file: image digests on the Dockerfile's `FROM` lines, and action
  commit SHAs on `uses:` lines. A pin audit looks in three places.
- Slack is an official external package. The image contains its verified bytes
  for scanning. OpenClaw installs the pinned runtime package in `openclaw-state`;
  deleting that volume also deletes the installation.
- `mcp.sessionIdleTtlMs` stays at its default `600000` — milliseconds, so 10
  minutes of idleness before a session's MCP child is reaped; `0` disables idle
  cleanup. Untuned until multi-session usage is measured.
- The image is **unsigned**; the digest pin is its integrity control. Azure Key
  Vault–backed signing, following the Pretorin CLI's approach, is planned
  production / internal-pilot work.
- `MODEL` is the build-time seed. For runtime model changes, use the
  [administrator guide](docs/administration.md#providers-and-models).
- Outstanding hardening is tracked in [SECURITY.md](SECURITY.md), including Docker
  file-based secrets, RBAC before shared channels, and the sandbox boundary.
