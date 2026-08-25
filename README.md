# Compliance Claw

OpenClaw with the Pretorin CLI attached, so an agent can review the repositories
you mount and do compliance work against your Pretorin system — from a terminal or
from a Slack channel.

Compliance Claw is deliberately thin. Pretorin already provides the compliance
intelligence: the MCP tool surface and its own routing instructions, workflows,
recipes, source preflight, active recipe sets, plans. This repository supplies the runtime that
joins those to your code — a supply-chain-verified Pretorin binary, a configured
OpenClaw gateway, a pinned Slack channel, and the wiring that tells Pretorin which
repositories this deployment is about.

This is a POC. `docs/plans/phase1.md` … `phase5.md` record what was built, what was
verified, and what is deliberately not done yet. **Read [SECURITY.md](SECURITY.md)
before pointing this at anything that matters** — in particular the shared-channel
attribution limit and the unsandboxed-tool-execution boundary.

## Status

Verified against the published image, pulled by digest, on a fresh clone:

| | |
| --- | --- |
| Public-repository operation | **passed** |
| Slack connectivity, and a real message/reply round trip | **passed** |
| Read-only Pretorin key | **passed** |
| Write-enabled Pretorin key, through the recipe workflow | **passed** |
| Published image pulled by immutable digest | **passed** |
| Private GitHub repository support | **implemented; live validation deferred** |

Two honest caveats, not passes:

- **Private repositories:** the path is complete and its refusal paths, parser
  contract and credential hygiene are verified, but the live happy path needs
  Pretorin **organisation-owner** permission to create and install the GitHub App.
  That validation is deferred to an owner, post-merge, against the published image.
  The step-by-step runbook is under "Private repositories" below.
- **Slack:** validated with an existing, manually created app. The committed
  `slack/app-manifest.json` is the reproducible setup path for a *new* app and is
  reviewed, but importing it from scratch was not separately tested.

The image is **unsigned**. Its integrity controls are the digest pin, the
per-release SBOM, the release-time vulnerability scan, and documented release
provenance — see "Verifying what you pulled".

## Requirements

- Docker Desktop (or another daemon) with **linux/amd64** support. Upstream ships
  no linux/arm64 Pretorin binary, so on Apple Silicon this runs emulated — enable
  Rosetta for amd64 in Docker Desktop settings. `bootstrap.sh` checks before it
  does anything slow.
- `git`, `python3`, `openssl`. On macOS all three come with the Command Line
  Tools, which `git` already requires. No PyYAML, no `jq`, no `gh`, nothing to
  `pip install`.
- Access to the GHCR package. It is not public, so `docker login ghcr.io` first.
- A Pretorin API key. **Read-only is the default and is sufficient** for
  everything here.
- Optional: a Slack workspace where you can install an app, and a read-only
  GitHub App if you want to review private repositories.

## Quickstart

```sh
# 0. authenticate to the registry (the package is not public)
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-github-username> --password-stdin

# 1. declare what you are reviewing, and for which compliance scope
vi targets.yaml                  # system_id, framework_id, one or more targets

# 2. write .env, clone the targets, PULL the released image
scripts/bootstrap.sh

# 3. fill in .env  — the read-only Pretorin key at minimum
vi .env                          # PRETORIN_API_KEY=...  (+ Slack, + GitHub App)

# 4. register the targets with Pretorin (idempotent; safe to re-run)
scripts/onboard-targets.sh

# 5. start the gateway
docker compose up -d             # http://127.0.0.1:18789

# anything one-off, in the same image with the same mounts:
docker compose run --rm cli pretorin --json context show
docker compose exec openclaw openclaw agent --agent main -m "..."
```

**`exec openclaw`, not `run --rm cli`, for agent turns.** `openclaw agent` talks to the
gateway over `127.0.0.1:18789`, and the `cli` service is a *different container* with
nothing on its own loopback — so there it silently falls back to running the agent
embedded, where model resolution is stricter and fails with
`Unknown model: ...`. Setting `OPENCLAW_GATEWAY_URL` does not help; resolution
happens before dispatch. Everything else (`pretorin ...`, `openclaw mcp ...`,
`openclaw config ...`) works fine under `run --rm cli`, because it needs no gateway.

Two ordering rules, both of which bite silently if ignored:

- **Slack credentials must be in `.env` before the first `up`.** The config is
  seeded once and never overwritten. Adding them later does nothing until you
  reset — the container warns explicitly when it sees exactly that situation.
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

  ```sh
  ```

Check what you bound at any time, read-only:

```sh
scripts/onboard-targets.sh --verify-only
```

`code_repository` reporting **`degraded`** there is expected, not a failure: the
platform wants capabilities like `branch_protection` that a local checkout cannot
supply. Those need a Connected Source on the platform side, which is future work.

## Verifying what you pulled

**Pull by digest, not by tag.** A tag is a mutable pointer — the same
`:<version>` can be made to resolve to different bytes tomorrow. A digest is the
bytes: `@sha256:…` is a content address, so if it resolves at all, it resolves to
exactly the image that was built, smoked, scanned and inventoried by the release
run that produced it.

```sh
docker login ghcr.io          # the package is not public
docker pull ghcr.io/pretorin-ai/compliance-claw:<version>@sha256:<digest>
```

The pair this checkout deploys is in [compose.yaml](compose.yaml) — copy it from
there rather than retyping a version seen in these examples.

The digest is printed in the release run's job summary, and `compose.yaml` carries
the line to paste it into. The release job also proves the round trip itself: it
deletes the local image, pulls the digest back from the registry, runs it, and
regenerates the SBOM from the pulled bytes to confirm the package inventory
matches the one taken from the build.

Check what you are actually running at any time:

```sh
docker compose images                      # what compose resolved
docker inspect --format '{{index .RepoDigests 0}}' \
  ghcr.io/pretorin-ai/compliance-claw:<version>@sha256:<digest>
```

The image also states its own version, set from the release tag at build time:

```sh
docker compose run --rm cli \
  grep '^IMAGE_VERSION=' /opt/compliance-claw/versions.env
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  ghcr.io/pretorin-ai/compliance-claw:<version>@sha256:<digest>
```

A local build reports `0.0.0-dev` (or `0.0.0-dev+<shortsha>` via
`scripts/bootstrap.sh --build`), never a release number — so an image built on
someone's laptop can never be mistaken for a published one.

### What this does and does not prove

> **The image is not signed.** There is no signature to verify, so do not reach for
> `cosign verify` — it will not find anything. A digest gives **integrity**: these
> exact bytes, not some other bytes wearing the same tag. It does not give
> **authenticity** — it is no proof of *who* built the image. Anyone who can push
> to the registry can publish a different digest, and a digest alone does not tell
> you which one came from this repository's release workflow.

The image's current integrity controls, in full:

| Control | What it gives you |
| --- | --- |
| GHCR image pinned by **immutable digest** | the bytes are the bytes that were built and scanned |
| **SBOM** generated per release (SPDX JSON) | a package inventory, retained as a workflow artifact on the release run |
| **Vulnerability scan** at release | fixable CRITICAL findings block publication |
| Documented release provenance | the workflow, the digest, and the version pin are all recorded |

The SBOM is **not** attached to the image and **not** signed — attaching an SBOM as
an OCI attestation is itself a signing operation. Read it from the release run's
artifacts.

**Planned, not implemented:** image signing backed by **Azure Key Vault**,
following the approach the Pretorin CLI already uses for its own releases. That is
production / internal-pilot work; see the hardening ledger in
[SECURITY.md](SECURITY.md). Until it lands, the digest pin is the control.

### Building locally instead (development)

The default path pulls, and `compose.yaml` deliberately has no `build:` section so
`docker compose up` can never quietly substitute an unscanned local build for the
released, scanned image. To build:

```sh
export COMPOSE_FILE=compose.yaml:compose.build.yaml
scripts/bootstrap.sh --build
```

`COMPOSE_FILE` is docker compose's own mechanism, so every script in the repo picks
it up with no extra flags. A local build is tagged `compliance-claw:local` so it
cannot be mistaken for the published image in `docker images`.

## `targets.yaml`

```yaml
system_id: 7b74d8f3-d77c-49e4-8792-c372dd154d38   # UUID or system name
framework_id: soc2                                # the same system under two
                                                  # frameworks is two scopes
targets:
  - name: simple-crm                              # becomes the directory name
    url: https://github.com/pretorin-ai/simple-crm.git
    ref: main                                     # optional
  # - name: crm-deploy                            # shipped commented out
  #   url: https://github.com/pretorin-ai/crm-deploy.git
  #   ref: master
  #   private: true                               # needs a GitHub App
```

One system and framework for the whole file; one or many targets. `bootstrap.sh`
clones each into `workspace/targets/<name>`, which compose bind-mounts
**read-only** at `/workspace/targets`.

The private example ships **commented out**, and deliberately: the committed file
has to work for a fresh clone that has nothing but a Pretorin key, and for CI,
which holds zero credentials. A private target with no GitHub App is a hard
failure — correct behaviour, wrong default. Uncomment it once your App is
configured.

List the scopes your key can see:

```sh
docker compose run --rm cli pretorin --json context list
```

### Public repositories

Nothing to configure. Any `https://` remote that clones anonymously works.

### Private repositories

`private: true` is a flag only — **no token, no credential and no path to one ever
appears in `targets.yaml`**, which is committed.

The supported path is a **read-only GitHub App**. Creating one on an organisation
requires **organisation owner** permission; a member cannot do it. If you are not
an owner, everything below is the request to hand to one — steps 1–5 are theirs,
steps 6–8 are yours once they give you the App ID and the `.pem`.

#### 1. Create the App (org owner)

`https://github.com/organizations/<ORG>/settings/apps/new`
— or Organisation settings → Developer settings → GitHub Apps → **New GitHub App**.

| Field | Value |
| --- | --- |
| GitHub App name | `Compliance Claw <org>` (must be globally unique) |
| Homepage URL | your repo URL — unused, but required |
| **Webhook** | **UNCHECK "Active"**. Compliance Claw pulls; it receives nothing. |
| Where can this be installed | **Only on this account** |

#### 2. Permissions — exactly one

Repository permissions → **Contents: Read-only**. Nothing else. Leave every other
permission at *No access*, and grant **no** organisation or account permissions.

`Metadata: Read-only` will be selected for you automatically — that is a GitHub
requirement and is expected. Do not add write access anywhere: this agent reviews
code and never pushes.

#### 3. Generate a private key (org owner)

On the App's page after creation: **Private keys → Generate a private key**. GitHub
downloads a `.pem` once and never shows it again.

#### 4. Install it on selected repositories only (org owner)

App page → **Install App** → the organisation → **Only select repositories** →
choose exactly the repositories to be reviewed. Not "All repositories".

#### 5. Hand over two things (org owner → operator)

- The numeric **App ID** — top of the App's settings page, e.g. `1234567`. This is
  *not* the Client ID and *not* the App name.
- The **`.pem` file**, over a secure channel. It is a private key.

#### 6. Place the key (operator)

```sh
mkdir -p secrets
mv ~/Downloads/<app-name>.<date>.private-key.pem secrets/compliance-claw.private-key.pem
chmod 600 secrets/compliance-claw.private-key.pem
```

`secrets/` and `*.pem` are both gitignored, and `.dockerignore` is an allowlist, so
the key can reach neither git nor a Docker build context.

#### 7. Point `.env` at it (operator)

```sh
GITHUB_APP_ID=1234567
GITHUB_APP_PRIVATE_KEY_FILE=secrets/compliance-claw.private-key.pem
GITHUB_APP_INSTALLATION_ID=          # leave empty; discovered automatically
```

Only fill `GITHUB_APP_INSTALLATION_ID` if the App is installed on more than one
account, in which case bootstrap lists the candidates and asks you to pick.

#### 8. Declare the target and run (operator)

Uncomment the private block in `targets.yaml` — the committed file ships it
commented out so a clone with no App still works — then:

```sh
scripts/bootstrap.sh        # mints the token, clones, deletes the token
scripts/onboard-targets.sh  # registers it with Pretorin like any other target
```

Bootstrap mints an installation token scoped to `contents:read` on exactly the
private targets you declared, clones with it, and deletes it. Verify afterwards:

```sh
git -C workspace/targets/<name> log --oneline -1        # the clone worked
git -C workspace/targets/<name> remote get-url origin   # a clean https URL
grep -c x-access-token workspace/targets/<name>/.git/config   # must print 0
```

#### If something is wrong

| Message | Meaning |
| --- | --- |
| `GITHUB_APP_ID is not set` | Step 7 not done, or `.env` not saved |
| `GITHUB_APP_ID must be numeric` | You used the Client ID or the App name |
| `cannot read the GitHub App private key` | Wrong path in step 6/7; paths are relative to the repo root |
| `is not a usable RSA private key` | Not the `.pem` — probably the manifest or a certificate |
| `the App JWT was rejected` | App ID and key are from different Apps, or the host clock is off |
| `the App is installed on 0 or several accounts` | Set `GITHUB_APP_INSTALLATION_ID` to the one listed |
| `the GitHub App installation does not include:` | Step 4 missed that repository; the message links the installation page |
| `needs Repository -> Contents -> Read-only` | Step 2 permission missing, or the org owner has not accepted a permission change |

**The container never holds a git credential.** The token is used on the host, is
passed to git through a credential helper rather than in the URL or in `argv`, is
never written into any clone's `.git/config` (asserted after every clone, and
independently by `scripts/smoke.sh`), and the container only ever sees the
resulting working tree over its read-only mount.

A **fine-grained PAT is a development fallback only** and is not recommended: it
carries a person's identity, expires on a human's schedule, and is much harder to
scope down to one repository and one permission.

## Slack

Optional. Leave the three Slack variables empty and Slack is simply not used — the
config is then byte-identical to a Slack-less deployment.

```
1. api.slack.com/apps/new -> Create New App -> From a manifest
   -> pick your workspace -> paste slack/app-manifest.json -> Create
2. Basic Information -> App-Level Tokens -> Generate Token and Scopes
   -> add connections:write            -> SLACK_APP_TOKEN   (xapp-...)
3. Install App -> Install to Workspace -> SLACK_BOT_TOKEN   (xoxb-...)
4. Invite the bot to ONE channel, right-click it -> Copy link
   -> the C... at the end of the URL   -> SLACK_CHANNEL_ID  (C...)
5. Put all three in .env, then: docker compose down -v && scripts/bootstrap.sh
   && scripts/onboard-targets.sh && docker compose up -d
```

For a **new** app, import the manifest rather than assembling scopes by hand — that
is the whole reason it is committed. It requests upstream's **minimal** socket-mode
scope set: **12 bot scopes instead of the recommended 23**, dropping files,
reactions, pins, group DMs, `emoji:read` and `usergroups:read`.

### Already have a Slack app? Reuse it.

**You do not need to create another one.** Any app with Socket Mode enabled, an
app-level token carrying `connections:write`, and a bot token works: put its three
values in `.env` and the rest of this section applies unchanged. The manifest is
the reproducible path for a *new* app, not a requirement for an existing one.

Two things to know when reusing an older app. It probably carries the broader
*recommended* scope set, so it can read files, reactions and group DMs this
deployment never touches. And **separate, independent Claws should generally use
separate Slack apps** — Slack may deliver a given event to any one of an app's
Socket Mode connections, so two deployments sharing one app get ambiguous routing
and a message can be answered by whichever Claw happened to receive it.

### What lives where

The **image** contains the pinned Slack plugin and the logic that generates the
Slack configuration. It contains **no Slack credentials**, and no channel id.

`SLACK_APP_TOKEN`, `SLACK_BOT_TOKEN` and `SLACK_CHANNEL_ID` are **deployment-time
values supplied through `.env`**, read from the environment at load time. They are
never baked into an image and never written into the config in the state volume.

- On a **fresh** OpenClaw volume, Slack is configured **automatically** when all
  three are present — no manual JSON, no plugin editing.
- An **existing** config volume is **never overwritten**. Adding the Slack
  variables to a volume that was previously Slack-less does nothing on its own; the
  container detects exactly that and prints the two ways forward — the documented
  reset (`down -v`, then bootstrap and onboard) or the manual
  `openclaw config patch` procedure. See "Upgrading".

Verify:

```sh
docker compose logs openclaw | grep -i 'slack'
#  [slack] channels resolved: C... -> your-channel
#  [slack] socket mode connected
```

then `@Compliance Claw what targets are onboarded?` in that channel.

**Slack connects outbound.** Socket Mode dials `slack.com` over a websocket, so
there is no request URL, no inbound port and no reverse proxy. The gateway port
stays published on `127.0.0.1` only, exactly as it is without Slack.

Behaviour, all set by `scripts/slack-channel.patch.json5`: DMs are **disabled**,
only the one allowlisted channel is served, and the agent answers only when
**explicitly mentioned**.

Enabling Slack also **trims the plugin surface**, because `plugins.allow` is an
exclusive allowlist. The gateway banner goes from
`(8 plugins: browser, canvas, device-pair, file-transfer, memory-core, ollama,
phone-control, talk-voice)` to `(1 plugin: slack)`. This is intended — it removes
the browser plugin and six others from a container whose tool execution is
unsandboxed. To restore one, add its id to `plugins.allow`; to restore all of
them, delete the `allow` line. If you remove `channels.slack`, remove `allow` too.

> **Security, not a footnote.** Every member of that Slack channel acts with the
> authority of the configured Pretorin key, and there is **no per-user
> attribution**. Use a **read-only key for shared channels**. A write-enabled key
> in a shared channel is explicitly warned against until RBAC exists — see
> [SECURITY.md](SECURITY.md).

## The model

`MODEL=openai/gpt-5.6-sol` in `versions.env` is baked into the config template at
**image build time**. It is an image-build choice: changing that line needs a
rebuild.

**No model credential is ever baked into the image.** Provider authentication
happens at **deployment time** and persists in the OpenClaw state volume, which is
why it survives `docker compose down` and is destroyed by `down -v`.

For VM deployments, OpenAI and Anthropic API keys can instead arrive through the
file-secret overlay and remain outside Docker's configured environment. See
[file-backed runtime secrets](docs/file-secrets.md). Model selection remains a
separate runtime action (`openclaw models set`); supplying a credential does not
silently change the selected model.

The POC's tested path is OpenAI/ChatGPT **device-code** login:

```sh
docker compose run --rm cli openclaw models auth login --provider openai --device-code
docker compose restart openclaw
```

It needs a TTY, so run it yourself rather than from a script. Check it took with
`openclaw models auth list` — but only an actual turn proves it reaches the model:

```sh
docker compose exec openclaw openclaw agent --agent main -m "Reply with exactly: OK"
```

### Changing the model on an existing deployment

No rebuild required:

```sh
docker compose run --rm cli openclaw models set <provider/model>
docker compose restart openclaw
```

`openclaw models list` shows what the authenticated provider offers.

**Selecting the model from `.env` at runtime is not implemented.** `versions.env`'s
`MODEL` is a build-time value and there is no runtime override — use
`openclaw models set` above. Runtime model selection is recorded as internal-pilot
/ product work, not a feature of this POC.

## Read-only vs write-enabled keys

`PRETORIN_API_KEY` is the access-control boundary. Compliance Claw registers the
full Pretorin tool surface and does not second-guess it: what the agent can do is
whatever the key authorizes, enforced server-side.

| | Read-only (default) | Write-enabled (opt-in) |
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

The image ships an **immutable seed**. On first start it is copied to
`/home/node/.pretorin/bin/pretorin` inside the `pretorin-state` volume, and that
copy is the CLI this deployment runs: it is first on `PATH`, it is what
`mcp.servers.pretorin.command` points at, and an image upgrade never replaces it.
So `pretorin version` has one meaning everywhere, and moving the CLI does not
require a Compliance Claw release.

```sh
scripts/pretorin-update.sh              # status: active vs seed, and the last update
scripts/pretorin-update.sh latest       # the latest stable release
scripts/pretorin-update.sh 0.28.7       # exactly that version
scripts/pretorin-update.sh --dry-run    # say what would happen; change nothing
```

From Slack, either route works and both run the same implementation:

```
/claw /pretorin-update latest           deterministic; bypasses the model entirely
/claw /pretorin-update status
@Compliance Claw update Pretorin        conversational; goes through the model
```

**Any authorized Slack user can do this, deliberately, with no approval step.**
The compensating control is the audit record below, not a confirmation prompt.

`latest` is passed to the CLI as *no argument at all*, which is how
`pretorin update` already means "install the latest stable release" — so release
selection, signature verification, downgrade refusal and prerelease exclusion are
all the CLI's own, not reimplemented here. Explicit prereleases (`0.29.0-rc2`) are
refused: an unattended, Slack-triggered update on a shared instance is the wrong
place for a release candidate.

**An update changes the CLI for every user of the instance.** Deployments are
independent of each other, but users of one deployment are not. The Slack
acknowledgement says so before the work starts.

**Activation is part of the update.** The CLI replaces its own binary by rename,
so a running `pretorin mcp-serve` child keeps the old one until it restarts —
which means "the file was replaced" is not "the update is live". After a
successful update the gateway is restarted (from Slack, through OpenClaw's own
restart path; from the host, with `docker compose restart openclaw`) and the
result is confirmed. If a restart is not possible, the update is reported as
**installed but not yet active**, naming the manual step. It is never reported as
complete when it is not.

### The update audit record

Every invocation appends one line to `/home/node/.pretorin/update-audit.log`
(mode `0600`) **and** writes the same line to the container log:

```
v=1 ts=2026-08-24T14:05:02Z requested=latest normalized= previous=0.28.7 \
    resulting=0.29.0 outcome=installed requester=slack:U024BE7LH route=command
```

| Field | Meaning |
| --- | --- |
| `v` | record format version, so a parser can tell when this changes |
| `requested` / `normalized` | what was asked for, verbatim, and after normalizing (`v0.28.7` → `0.28.7`) |
| `previous` / `resulting` | the version before and after |
| `outcome` | `installed`, `already_current`, `refused_input`, `rolled_back`, `timeout`, `backup_failed`, `backup_mismatch`, `interrupted` |
| `requester` | `<channel>:<user-id>`, from the **authenticated** invocation, or `unavailable` |
| `route` | `command`, `tool`, or `repair` |

Read it with `scripts/pretorin-update.sh --status`, or in full:

```sh
docker compose run --rm cli cat /home/node/.pretorin/update-audit.log
docker compose logs openclaw | grep 'outcome='
```

**Requester identity is never taken from a model or an argument.** The command
route reads it from the authenticated Slack message; the tool route reads it from
the runtime's trusted inbound sender. When neither is available the field is
literally `unavailable` rather than a value someone could have chosen.

**What this record is, and is not.** It is the compensating control for having no
approval workflow: it tells you who moved the CLI, when, and to what. It is not
tamper-evident storage. The agent runs as the same user, tool execution in this
container is unsandboxed (see SECURITY.md), and `down -v` deletes the volume the
file lives in. The copy in the container log is outside the volume and outside the
agent's write path, which is why the record is written twice.

## Testing

```sh
scripts/smoke.sh              # Section A always; Section B if a key authenticates
scripts/smoke.sh --no-creds   # Section A only — exactly what CI runs
python3 scripts/parse-targets.py --self-test
```

Section A needs no credentials at all: versions, the Pretorin MCP surface, the
`targets.yaml` parser, gateway startup and the plugin profile, config and
`AGENTS.md` seeding, mount posture, the stale-template warning, the CWD fix,
secret containment for every secret class, the private-target refusals, and proof
that a **fresh volume** comes up Slack-configured with no manual JSON. Section B
proves onboarding end to end, that a read tool works through MCP, and that a write
tool is rejected server-side.

Pre-release, run the tests against a local build (`export
COMPOSE_FILE=compose.yaml:compose.build.yaml`), since the pull path needs a
published image.

## Updating an existing deployment

```sh
scripts/update.sh
```

One command: fast-forward the checkout, pull the image this checkout pins, restart
the gateway on it, then report anything you have to act on. It is idempotent — run
it twice and the second run pulls nothing and recreates nothing.

On `master` the digest pin and `IMAGE_VERSION` are already set to the current
release, so updating means pulling `master` rather than editing anything. To move
to a *specific* release instead, point `compose.yaml` at that digest and set the
matching `IMAGE_VERSION` in `versions.env` before running it — `smoke.sh` asserts
the two agree.

`update.sh` refuses rather than guessing, and names the exact command each time:
a dirty working tree, a detached HEAD, a branch with no upstream, a branch that has
diverged from its upstream, or a shell with `COMPOSE_FILE` set to the local build
overlay (that is a rebuild, not an update).

### What survives an update, and what does not

| | Survives `update.sh` | Survives `down -v` |
| --- | --- | --- |
| The image | replaced — that is the point | n/a |
| **The Pretorin CLI** (`pretorin-state`) | **yes — `update.sh` no longer moves it** | **no — reverts to the image seed** |
| Model login (`openclaw-state`) | **yes** | **no** |
| Seeded config, sessions, `AGENTS.md` | **yes** | **no** |
| Pretorin context, resolvers, recipes (`pretorin-state`) | **yes** | **no** |
| `.env` | **yes** | **yes** — never touched by either |
| `workspace/targets` clones | **yes** | **yes** — bind-mounted, not a volume |

So an update never costs you a re-login or a re-onboard.

**Two things about the CLI row, because both surprise people.** `down -v` deletes
`pretorin-state`, so the next start re-seeds the CLI from the image and every
update you had applied is gone — worth knowing, because `down -v` is the remedy
this README recommends in three other places. And rolling the *image* backwards
does **not** roll the CLI backwards: the volume keeps whatever version it has.
The CLI moves in exactly one way, `scripts/pretorin-update.sh`.

Re-run
`scripts/onboard-targets.sh` only after `down -v`, or when `targets.yaml` changes;
it is idempotent either way.

`smoke.sh` also reports this state on its own:

```
NOTE  deployment is behind the repo pin: run scripts/update.sh
      running sha256:58690e31...
      pinned  sha256:e123bf53...
```

A warning, not a failure — being mid-update is not being broken.

**The image no longer decides which Pretorin CLI you run.** It ships a *seed*;
the CLI a deployment actually uses lives in the `pretorin-state` volume, and
`update.sh` does not touch volumes. So pulling a newer image gives you a newer
seed and the same CLI. Move the CLI with:

```sh
scripts/pretorin-update.sh --status     # what is installed, and what the image seeds
scripts/pretorin-update.sh latest       # update to the latest stable release
```

**Historical note:** on v0.2.x and earlier the CLI *was* welded to the image, so
an image upgrade did move it — that is how a v0.1.x deployment went from 0.26.14
to 0.28.2. From this release on, the two are independent.

**A newer image does not update an existing volume's config.** Templates are
seeded write-if-absent and never overwritten, so a tightened template has no
effect on a deployment that already has a config. The container tells you instead:

```
compliance-claw: WARNING — this volume's config predates the image.
  volume template version 2, image ships 3.
```

It never edits anything. Either merge the change by hand — diff your
`~/.openclaw/openclaw.json` against
`/opt/compliance-claw/openclaw-config.template.json` in the image, then
`echo 3 > ~/.openclaw/.compliance-claw-templates` — or reset.

There is a second, Slack-specific version of this warning, because the
template-version message says nothing about Slack:

```
compliance-claw: WARNING — Slack credentials are supplied but NOT in this volume's config.
```

That means all three Slack variables are set and the existing config predates
them. It names both fixes.

## Resetting

```sh
docker compose down -v
```

This deletes **both** named volumes: the OpenClaw state volume (config, sessions,
agent workspace, your customised `AGENTS.md`, and any model login) **and** the
Pretorin state volume (active context, preflight resolvers, active recipe set). It
does **not** touch the bind-mounted target repositories under `workspace/targets`,
and it does not touch `.env`.

Recovery is re-running `scripts/bootstrap.sh` and `scripts/onboard-targets.sh`;
both are idempotent. `docker compose down` without `-v` keeps everything.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `pull access denied` / `unauthorized` | The package is not public | `docker login ghcr.io`; a classic token needs `read:packages` |
| `deployment is behind the repo pin` | Repo was pulled, deployment never restarted | `scripts/update.sh` |
| Gateway exits 1 immediately | `OPENCLAW_GATEWAY_TOKEN` empty | `scripts/bootstrap.sh` generates one; check `.env` |
| Gateway exits 78 `Missing config` | Config was never seeded | `docker compose down -v` then bootstrap |
| Slack never connects | Credentials added after the first `up` | Look for the Slack-specific warning; `down -v` and re-bootstrap |
| Slack connects, bot never answers | Channel **name** instead of ID, or bot not invited | Use the `C...` ID; invite the bot; mention it explicitly |
| `Slack is only partially configured` | 1 or 2 of the 3 variables set | All three are required together |
| `SLACK_CHANNEL_ID is not a Slack channel id` | A name or a URL was used | Right-click channel → Copy link → the `C...` value |
| `GITHUB_APP_ID is not set` on a private target | No App configured | Follow "Private repositories", or drop `private: true` |
| `the GitHub App installation does not include:` | App not installed on that repo | Add it on the linked installation page |
| `exists but is not the root of a git repository` | Interrupted clone | Inspect, then `rm -rf` that directory yourself and re-run |
| `tracks a different remote` | `targets.yaml` URL changed | Fix the URL, or move the directory aside |
| `code_repository` is `degraded` | Expected | Needs a platform Connected Source; future work |
| `Missing required scopes: write` | Read-only key, write tool | Correct behaviour — see "Read-only vs write-enabled" |
| `Scope is not approved with a confirmed scale yet` | Platform prerequisite | Approve scope setup on platform.pretorin.com |
| Agent answers with no sources bound | Framework switched in chat | One scope per deployment; re-run onboarding for another |
| `plugins list` shows 9 plugins, not 2 | Slack not configured | Expected; the two profiles are documented above |
| `pretorin version` is newer than `versions.env` | The CLI was updated in place | Expected. `versions.env` pins the seed; `scripts/pretorin-update.sh --status` shows both |
| An image upgrade did not change the CLI | By design since this release | The CLI lives in a volume. Use `scripts/pretorin-update.sh` |
| Updated the CLI but MCP still reports the old version | The gateway's MCP child is still the old process | `docker compose restart openclaw`. `--status` confirms which binary is active |
| `/claw /pretorin-update` does nothing in Slack | `channels.slack.slashCommand` missing from an existing config | Never-clobber: the container warns. Re-seed, or set it by hand |

Logs and state:

```sh
docker compose logs -f openclaw
docker compose run --rm cli openclaw doctor
docker compose run --rm cli openclaw plugins inspect slack
scripts/onboard-targets.sh --verify-only
```

## Releasing

**The GitHub Release tag is the source of truth for the version.** Releasing means
publishing `vX.Y.Z` — nothing is bumped first, and **no version-bump PR is required
before releasing**. CI derives the version from the tag and builds the image with
it, so the image states the version it was released as.

```sh
# 1. cut the release — this is the whole release trigger
gh release create vX.Y.Z --target master --generate-notes

# 2. wait for the release workflow to succeed

# 3. one POST-RELEASE PR pins what it published:
#      versions.env   IMAGE_VERSION=X.Y.Z
#      compose.yaml   image: ghcr.io/pretorin-ai/compliance-claw:X.Y.Z@sha256:<digest>
#    both lines are printed in the release run's job summary
```

**Why step 3 is a separate PR, and not a bump beforehand:** the digest does not
exist until the image is built. Nothing can pin `@sha256:…` in advance, because
that value is the hash of bytes that have not been produced yet. So the version
flows *forward* from the tag into the image, and the digest flows *back* from the
completed run into the checkout. Any attempt to bump first would either invent a
digest or leave the pin stale.

Step 3 is not optional bookkeeping. A tag is mutable and the image is unsigned, so
the digest pin is the only thing tying a deployment to the bytes that were actually
built and scanned. `IMAGE_VERSION` and the pin describe **what this checkout
deploys**, which is why they move together, once, after the release.

`.github/workflows/release.yml` builds `linux/amd64`, smokes the image, blocks on
fixable CRITICAL vulnerabilities, generates an SPDX SBOM, then:

1. **pushes by digest** under a single constant staging ref,
   `ghcr.io/pretorin-ai/compliance-claw:build` — no version tag yet. `docker push`
   requires *some* tag before a digest can be published; a constant name means at
   most one such ref ever exists instead of one per release
2. **pulls that digest back and re-verifies it** — the local image is removed first
   so the pull cannot be served from cache, and the SBOM is regenerated from the
   pulled bytes and compared against the built one
3. **only then applies the version tag** to the verified digest, by re-PUTting the
   same manifest bytes so the digest is preserved by construction, and resolves the
   tag to confirm it lands there

That ordering is deliberate: a floating tag should never point at bytes nobody has
checked. The SBOM is also attached to the GitHub Release, so it outlives
workflow-artifact retention.

### Not part of releasing

Releasing is the four steps above and nothing else. None of the following is a
prerequisite, a blocker, or part of the procedure:

| | Status |
| --- | --- |
| release-please or other release automation | not implemented; releases are cut by hand |
| Azure Key Vault image signing | planned, SECURITY.md ledger item 5 — the image is unsigned |
| cleaning up old GHCR package versions | separate housekeeping, never required to release |
| `scripts/update.sh` | for operators updating a deployment, unrelated to publishing |
| a pre-release version bump | explicitly not required — see step 3 above |

CI holds **no** Pretorin, model or Slack credentials — only the automatic
`GITHUB_TOKEN`, and it asserts that itself. It does not sign; see "Verifying what
you pulled".

Rehearse the pipeline without publishing anything:

```sh
gh workflow run release.yml -f dry_run=true
```

## Notes

- Every pin lives in `versions.env`, with two documented carve-outs that cannot
  read a sourced file: image digests on the Dockerfile's `FROM` lines, and action
  commit SHAs on `uses:` lines. A pin audit looks in three places.
- The Slack plugin is not bundled with OpenClaw. It is installed from npm at build
  time, integrity-checked against `SLACK_PLUGIN_INTEGRITY`, and loaded from the
  image via `plugins.load.paths` — never from the state volume, so `down -v`
  cannot remove it.
- `mcp.sessionIdleTtlMs` stays at its default `600000` — milliseconds, so 10
  minutes of idleness before a session's MCP child is reaped; `0` disables idle
  cleanup. Untuned until multi-session usage is measured.
- The image is **unsigned**; the digest pin is its integrity control. Azure Key
  Vault–backed signing, following the Pretorin CLI's approach, is planned
  production / internal-pilot work.
- Runtime model selection from `.env` is **not implemented**. `MODEL` is a
  build-time value; change an existing deployment with `openclaw models set`.
- Outstanding hardening is tracked in [SECURITY.md](SECURITY.md), including Docker
  file-based secrets, RBAC before shared channels, and the sandbox boundary.
