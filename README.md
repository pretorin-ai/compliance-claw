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
| Install | [Requirements](#requirements), [Quickstart](#quickstart), and [image verification](#verifying-what-you-pulled) |
| Administer the Claw | [Administrator guide](docs/administration.md), [effort schema](docs/efforts.md), and [secret delivery](docs/file-secrets.md) |
| Use an agent | [Agent commands](docs/file-secrets.md#docker-compose-exec-does-not-see-these-secrets), [target sync](#keeping-targets-up-to-date), and [key permissions](#read-only-vs-write-enabled-keys) |
| Upgrade or recover | [Deployment updates](#updating-an-existing-deployment), [CLI updates](#updating-the-pretorin-cli), [recovery](docs/upgrade.md), and [troubleshooting](#troubleshooting) |
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

Baseline operation was verified against the published image, pulled by digest,
on a fresh clone. Target synchronization and the fresh Slack-seeding fix were
then verified in isolation and in CI. They are included in the v0.5.1 image
pinned by this checkout.

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
  The step-by-step runbook is under "Private repositories" below.
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
provenance — see "Verifying what you pulled".

## Requirements

- Docker Compose **v2.24.0 or newer**. The file-secret overlay uses the `!reset`
  tag introduced in that release; older versions may retain `.env` unexpectedly.
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

```sh
# 0. authenticate to the registry (the package is not public)
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <your-github-username> --password-stdin

# 1. select the file-backed credential path (recommended, and what Azure needs)
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml

# 2. declare what you are reviewing, for which compliance scope, and where it
#    uses a Slack channel, if needed. efforts.yaml is what the deployment reads.
cp efforts.example.yaml efforts.yaml
vi efforts.yaml                  # system_id, framework_id, targets; optional slack_channel_id
#    Already have a single-effort targets.yaml? Convert it instead:
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

**Keep `COMPOSE_FILE` exported for every later command.** It is how compose knows
to mount the secret files; without it a `docker compose` in a new shell falls back
to the legacy path and the deployment loses its credentials. `bootstrap.sh` prints
the line to re-export.

<details>
<summary>Legacy path — secret values in <code>.env</code></summary>

Still supported, and still what an existing deployment uses. Omit step 1, and
`bootstrap.sh` then generates a gateway token into `.env` and asks you to add the
Pretorin key there:

```sh
scripts/bootstrap.sh
vi .env                          # PRETORIN_API_KEY=...  (+ Slack, + GitHub App)
scripts/onboard-targets.sh       # LEGACY single-effort onboarding
docker compose up -d
```

> **Legacy.** This path serves one effort and cannot build per-effort agents:
> `scripts/clawctl` needs the file-backed credential path. The quickstart above is
> the supported route.

The cost is that compose's `env_file` hands every value in `.env` to the container
**and to `docker inspect`**, so anyone who can query the daemon can read them. To
migrate an existing deployment, `scripts/init-file-secrets.sh` copies what is
already in `.env` into the secret files; then blank the secret lines in `.env`,
because supplying a credential both ways is refused rather than silently resolved.

</details>

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
| **Vulnerability scan** at release | fixable HIGH and CRITICAL findings block publication |
| Documented release provenance | the workflow, the digest, and the version pin are all recorded |

The SBOM is not attached to the OCI image and is not signed. It is available
as a workflow artifact and as an asset on the published GitHub Release. See the
[release procedure](docs/releasing.md).

**Planned, not implemented:** image signing backed by **Azure Key Vault**,
following the approach the Pretorin CLI already uses for its own releases. That is
production / internal-pilot work; see the hardening ledger in
[SECURITY.md](SECURITY.md). Until it lands, the digest pin is the control.

### Building locally instead (development)

Contributor builds use a separate local image. See
[development setup and build commands](CONTRIBUTING.md#how-to-build-a-candidate-image).

## `targets.yaml` (legacy — see `efforts.yaml` above)

> This is the single-effort format. It is still the shape `scripts/clawctl
> migrate` reads, and the per-target rules below are unchanged in `efforts.yaml`,
> but `efforts.yaml` takes precedence on the multi-effort path. `targets.yaml`
> remains mounted for the legacy target-sync fallback. A multi-effort deployment
> declares its targets under each effort in `efforts.yaml`.

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

`ref` is a **branch name** — not a tag and not a SHA. Synchronization
fast-forwards a branch to its upstream, and a detached checkout at a tag has no
upstream to fast-forward to. Without `ref`, a target follows whatever branch the
clone is on, which after a fresh clone is the remote's default.

Once cloned, targets are brought up to date with **[Keeping targets up to
date](#keeping-targets-up-to-date)** — from the host or from Slack.

The private example ships **commented out**, and deliberately: the committed file
has to work for a fresh clone that has nothing but a Pretorin key, and for CI,
which holds zero credentials. A private target with **no credential at all** —
neither a GitHub App nor a PAT — is a hard failure, which is correct behaviour
and the wrong default. Uncomment it once you have configured one of the two.

List the scopes your key can see:

```sh
docker compose run --rm cli pretorin --json context list
```

### Public repositories

Nothing to configure. Any `https://` remote that clones anonymously works.

### Private repositories

`private: true` is a flag only — **no token, no credential and no path to one ever
appears in the declaration**, in either format.

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

Add the target with `private: true` to the relevant effort in `efforts.yaml`
(`efforts.example.yaml` documents the shape), then:

```sh
scripts/bootstrap.sh        # mints the token, clones, deletes the token
scripts/clawctl apply       # registers it with Pretorin like any other target
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

**The GitHub App credential never leaves this host.** The private key is
host-only, the installation token it mints lives in a 0600 temp file for one
`bootstrap.sh` run, both reach git through a credential helper rather than the
URL or `argv`, neither is ever written into a clone's `.git/config` (asserted
after every clone, and independently by `scripts/smoke.sh`), and neither is ever
mounted into a container.

#### The PAT fallback, and the invariant it relaxes

Earlier releases said the container never holds a git credential at all. **That
is no longer true**, and this section says so rather than leaving the old
sentence standing.

Synchronizing a private target from Slack happens *inside* the container, and the
App private key deliberately never goes there — so that path uses a
**fine-grained PAT** instead, delivered as a mounted file:

```sh
scripts/init-file-secrets.sh                     # creates it empty if absent
$EDITOR secrets/runtime/github-readonly-pat      # paste the token, no newline needed
```

The token must be:

- **fine-grained** (not classic),
- limited to **only the selected repositories** you review,
- with **Repository permissions → Contents: Read-only** and nothing else.

Then `export COMPOSE_FILE=compose.yaml:compose.secrets.yaml` and restart. The PAT
is only available on the file-secret path; the legacy `.env` path has no PAT and
a private target there reports `auth_failed` naming the fix.

**Status: internal-pilot acceptable, not recommended.** The GitHub App is the
recommended mechanism for any customer or production deployment. A PAT carries a
person's identity, expires on a human's schedule, is harder to scope, and —
unlike the App — is a git credential that lives inside the container. It is never
an environment variable, never in a URL, `.git/config`, a log, an audit line or a
Slack message; but tool execution in that container is unsandboxed, so a
prompt-injected agent can read the file. Read
[SECURITY.md](SECURITY.md#the-pat-is-a-deliberately-relaxed-invariant-not-an-oversight)
before enabling it.

`bootstrap.sh` prefers the App whenever `GITHUB_APP_ID` is set, and **will not
fall back to the PAT if minting fails** — a broken App stops the run rather than
silently substituting a longer-lived credential.

## Multiple compliance efforts

One deployment serves several. An **effort** is one system + one framework, with
its own targets, its own named Pretorin credential and its own Slack channel. That
pairing is Pretorin's own: preflight state and the active recipe set are keyed on
system + framework, so the same system under SOC 2 and under HIPAA is two separate
compliance efforts.

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

Targets do not move on their own. Three ways to advance them, all running the
**same implementation** (`scripts/sync-targets.sh`) so they cannot disagree:

```sh
scripts/bootstrap.sh                  # host: clone what is missing, update the rest
scripts/sync-targets.sh all           # host: update only, never clone
scripts/sync-targets.sh simple-crm    # host: one target
```

and from Slack, once the gateway is running:

```
/compliance-claw /target-sync all                # deterministic; bypasses the model
/compliance-claw /target-sync simple-crm
@claw update the simple-crm target    # the target_sync tool, same wrapper
```

The reply names every target it touched:

```
simple-crm updated: 276b5fd → 918ac42
```

**Fast-forward only.** It never resets, force-checks-out, stashes, discards local
changes, switches branches, rewrites history, deletes anything, or creates a
merge commit. A target it cannot move safely is reported and left exactly as it
is, with a message naming the remedy:

| Outcome | What it means |
| --- | --- |
| `updated` | fast-forwarded; both SHAs reported |
| `already_current` | nothing to do |
| `dirty_refused` | the working tree has local changes |
| `detached_refused` | HEAD is not on a branch |
| `no_upstream_refused` | the branch does not track `origin/<branch>` |
| `branch_mismatch_refused` | checked out on a branch other than `ref` |
| `origin_mismatch_refused` | the clone tracks a different remote than `efforts.yaml` declares |
| `diverged_refused` | local commits the remote lacks, or upstream rewrote history |
| `missing_clone` | not cloned yet — run `scripts/bootstrap.sh` |
| `auth_failed` | the remote refused the credential |
| `invalid_target` | not declared at all, or a malformed request |
| `out_of_effort` | a real target, but not one this effort declares — ask in that effort's channel |
| `targets_unreadable` | `efforts.yaml` could not be parsed — nothing was examined |
| `sync_already_running` | another sync holds the global lock |

A lock left behind by a killed process is reclaimed automatically once its owner
is provably gone, and the reclaim is announced in the log. A lock held by a live
process, or by one this container cannot see (the host, or an earlier container),
is never taken — clear that by hand with `rmdir` on the path the message names.

`all` processes targets one at a time, keeps going after a failure, reports every
target, and exits non-zero if any failed.

**What it cannot do.** Only `all` or the name of a target declared **for the
calling agent's own effort** is accepted — no URL, ref, path, flag or shell
fragment is expressible on any route, and `all` means all of that effort's
targets, never every repository on the deployment. A target belonging to another
effort is refused by name. Which effort is calling comes from the OpenClaw agent
id, which the host resolves from the routed session before the tool runs, so a
prompt cannot name a different one. Adding, removing, re-pointing or onboarding a
target stays an operator action on the host: edit `efforts.yaml`, then run
`scripts/clawctl apply`.

Ordinary synchronization does **not** re-run onboarding and does **not** restart
the gateway. Source resolvers bind paths rather than commits, and
`/workspace/targets` is a live bind mount, so the new bytes are visible
immediately.

### Where the writable mount is, and what it is not

Assessment reads `/workspace/targets`, **read-only on both services**. The
synchronizer writes through a second mount of the same host directory,
`/var/lib/compliance-claw/targets`, on the **gateway service only**.

That is process-level separation inside one container, **not a security
boundary**: the wrapper and the agent's unsandboxed tool execution run as the
same uid, so an agent can reach the writable path directly. What it buys is that
the assessment path — the one every evidence citation comes from — stays
read-only, so an accidental write fails instead of silently succeeding. See
[SECURITY.md](SECURITY.md#the-sandbox-boundary--say-it-plainly).

### The sync audit record

One line per target, to `docker compose logs openclaw` **and** to
`/home/node/.pretorin/target-sync-audit.log`:

```
v=1 ts=2026-08-26T00:01:53Z op=target-sync target=simple-crm outcome=already_current previous=276b5fd8… resulting=276b5fd8… credential=none requester=slack:U123 route=command
```

`credential` records the *source* (`none`, `github-app`, `pat`) and never a
value. The log copy is the one that matters: the agent can rewrite anything in
the state volume, so a file it can edit is not evidence on its own.

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

The active CLI is `/home/node/.pretorin/bin/pretorin` in `pretorin-state`.
It survives image upgrades. A CLI update affects **every agent and user of this
instance** and does not require an image release. The shared installer verifies
signatures and refuses downgrades and prereleases.

From the deployment host:

```sh
scripts/pretorin-update.sh              # installed version, seed, and last update
scripts/pretorin-update.sh latest       # latest stable release
scripts/pretorin-update.sh 0.28.7       # exact version
scripts/pretorin-update.sh --dry-run    # inspect without changes
```

From Slack, use the command name registered for your app:

```
/compliance-claw /pretorin-update latest
/compliance-claw /pretorin-update 0.28.7
/compliance-claw /pretorin-update status
@Compliance Claw update Pretorin
```

**Automatic restart applies only to the owner Slack command.** Configure
`commands.ownerAllowFrom` with the operator's verified Slack identity, for example
`["slack:U0123456789"]`. Channel membership alone does not grant restart authority.
The first reply reports installation and pending activation. The gateway restarts
inside the running container. A final Slack message reports completion only after
the expected CLI version, executable bytes, and real MCP calls are verified.

**The conversational model tool requires an operator restart.** Disabled restart
and unsupported reply routes also return **OPERATOR RESTART REQUIRED**. With the
deployment's Compose project and overlays selected, run:

```sh
docker compose restart openclaw
docker compose exec -T openclaw pretorin version
```

The version command checks the installed file. Confirm that the restart and next
Pretorin MCP call succeed before treating the update as complete. Failed automatic
verification reports installation success with unverified activation.

Automatic verification supports the pinned OpenClaw `2026.10.5` Linux container,
the canonical Pretorin MCP command, and the shipped effort launcher. See
[activation, pending results, and recovery limits](docs/upgrade.md#pretorin-cli-activation-and-results)
and the [update audit record](docs/upgrade.md#pretorin-cli-update-audit).

## Testing

Contributor test commands, prerequisites, and disposable container setup are in
[CONTRIBUTING.md](CONTRIBUTING.md#test-selection).

## Updating an existing deployment

```sh
scripts/update.sh
```

One command: fast-forward the checkout, pull the image this checkout pins, restart
the selected gateway, then report anything you have to act on. Compose waits up
to 360 seconds for startup. The script then verifies the selected container's
running state, health, and actual image against the effective Compose selection,
including customer overlays. It checks the gateway again after diagnostics.
It is idempotent: a second run does not force container replacement.

Use Docker Compose 2.24.0 or newer, with `--wait` and `--wait-timeout` support,
and Python 3. Keep the deployment's `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, and
profiles selected. Only the gateway and its Compose dependencies are started;
the one-shot `cli` service is used for diagnostics.

Exit 0 means gateway image and health verification and the configuration
diagnostic succeeded. Recognized configuration-drift warnings remain warnings.
Startup, wait, inspection, image mismatch, and diagnostic failures return nonzero
without a completion report. A failed diagnostic reports configuration status as
unknown. Inspect the reported error and `docker compose ps -a` with the same
deployment selection. No automatic recovery is attempted. Gateway health does
not prove that Slack or Pretorin MCP calls succeed.

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

OpenClaw can migrate the stored configuration and databases at startup. Before
an upgrade, stop the gateway and back up both state volumes and deployment
files. See [Upgrade and recovery](docs/upgrade.md). An older image can require
the matching pre-upgrade state; changing the image alone is not a full rollback.

**Two things about the CLI row, because both surprise people.** `down -v` deletes
`pretorin-state`, so the next start re-seeds the CLI from the image and every
update you had applied is gone. Reserve this command for intentional state
deletion; it is not routine configuration repair. And rolling the *image* backwards
does **not** roll the CLI backwards: the volume keeps whatever version it has.
The CLI moves in exactly one way, `scripts/pretorin-update.sh`.

Re-run
`scripts/clawctl apply` only after `down -v`, or when `efforts.yaml` changes; it
is idempotent either way.

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

**Templates do not replace an existing configuration.** OpenClaw can migrate its
schema, and this release replaces the obsolete Slack load path with a managed
installation. Other template changes still require administrator review. The
container reports a template revision difference:

```
compliance-claw: WARNING — this volume's config predates the image.
  volume template version 2, image ships 3.
```

For a template change, merge the change by hand — diff your
`~/.openclaw/openclaw.json` against
`/opt/compliance-claw/openclaw-config.template.json` in the image, then
`echo 3 > ~/.openclaw/.compliance-claw-templates`. Back up the state before
repair. Do not delete volumes to apply a template change.

There is a second, Slack-specific version of this warning, because the
template-version message says nothing about Slack:

```
compliance-claw: WARNING — Slack credentials are supplied but NOT in this volume's config.
```

That means the Slack credentials this deployment requires — both tokens on the
multi-effort path, all three variables on the legacy one — are set while the
existing config predates them. It names the managed install and configuration
steps. It does not replace the existing configuration.

## Resetting

`docker compose down` retains the named volumes. Adding `-v` deliberately deletes
both: OpenClaw config, sessions, agent workspaces, model login, and the managed
Slack installation; and Pretorin context, resolvers, recipes, active CLI, and
volume audit files. Bind-mounted target clones and host files such as `.env`
and secret files remain.

Do not use `down -v` for routine setup or troubleshooting. Before intentional
state deletion, select the correct Compose project and files and follow
[upgrade and recovery](docs/upgrade.md) to preserve verified backups. Bootstrap
and `clawctl apply` can create initial state; they cannot restore deleted sessions
or prior configuration. Restore from a verified recovery set when state matters.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `pull access denied` / `unauthorized` | The package is not public | `docker login ghcr.io`; a classic token needs `read:packages` |
| `deployment is behind the repo pin` | Repo was pulled, deployment never restarted | `scripts/update.sh` |
| Gateway exits 1 immediately | `OPENCLAW_GATEWAY_TOKEN` empty | Check the gateway-token file on the file-secret path; `.env` is the legacy path. See [secret delivery](docs/file-secrets.md). |
| Gateway exits 78 `Missing config` | Config missing or unreadable | Check logs, selected mounts, and file permissions. Preserve state and use [recovery guidance](docs/upgrade.md); do not delete volumes. |
| Slack never connects | Missing credentials, channel setup, or existing config without Slack | Inspect the Slack warning and current configuration; see [Slack](#slack) and [recovery](docs/upgrade.md). |
| Slack connects, bot never answers | Channel **name** instead of ID, or bot not invited | Use the `C...` ID; invite the bot; mention it explicitly |
| `Slack is only partially configured` (multi-effort) | one of the **two** tokens set | Both tokens are required together; the channels come from `efforts.yaml` |
| `Slack is only partially configured` (legacy) | 1 or 2 of the **three** variables set | All three are required together |
| `SLACK_CHANNEL_ID is set but IGNORED` | `.env` still carries it while `efforts.yaml` exists | Remove it from `.env`; `clawctl apply` owns the channel allowlist |
| `slack_channel_id ... is not a Slack channel id` | A name or a URL was used in `efforts.yaml` | Right-click channel → Copy link → the `C...` value |
| `slack_channel_id ... is a DM conversation id` | A `D...` id was used as an effort's home | Use the channel's `C...` id; DMs are `clawctl dm allow` |
| `slack_channel_id ... is a legacy G id` | A `G...` id is ambiguous (private channel vs MPIM) | Use the channel's `C...` id |
| `GITHUB_APP_ID is not set` on a private target | No App configured | Follow "Private repositories", or drop `private: true` |
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
| An image upgrade did not change the CLI | By design since this release | The CLI lives in a volume. Use `scripts/pretorin-update.sh` |
| Updated the CLI but MCP still reports the old version | The gateway's MCP child is still the old process | `docker compose restart openclaw`, then check the next MCP call. `--status` reports the installed binary only |
| `/compliance-claw /pretorin-update` does nothing in Slack | Existing slash-command configuration or missing owner authority | Check startup warnings, the registered command name, and `commands.ownerAllowFrom`. Preserve state before configuration repair; see [CLI updates](#updating-the-pretorin-cli). |

Logs and state:

```sh
docker compose logs -f openclaw
docker compose run --rm cli openclaw doctor
docker compose run --rm cli openclaw plugins inspect slack
scripts/clawctl validate                 # the efforts, credentials and channels
scripts/onboard-targets.sh --verify-only # LEGACY single-effort deployments only
```

## Releasing

Maintainers use [How to publish a release](docs/releasing.md). Publishing is
separate from updating a customer deployment or its active Pretorin CLI.

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
