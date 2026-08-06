# Compliance Claw

OpenClaw with the Pretorin CLI attached, so an agent can review the repositories
you mount and do compliance work against your Pretorin system — from a terminal or
from a Slack channel.

Compliance Claw is deliberately thin. Pretorin already provides the compliance
intelligence: the skill, the MCP tool surface, workflows, recipes, source
preflight, active recipe sets, plans. This repository supplies the runtime that
joins those to your code — a supply-chain-verified Pretorin binary, a configured
OpenClaw gateway, a pinned Slack channel, and the wiring that tells Pretorin which
repositories this deployment is about.

This is a POC. `docs/plans/phase1.md` … `phase5.md` record what was built, what was
verified, and what is deliberately not done yet. **Read [SECURITY.md](SECURITY.md)
before pointing this at anything that matters** — in particular the shared-channel
attribution limit and the unsandboxed-tool-execution boundary.

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
docker compose run --rm cli openclaw agent --agent main -m "..."
```

Two ordering rules, both of which bite silently if ignored:

- **Slack credentials must be in `.env` before the first `up`.** The config is
  seeded once and never overwritten. Adding them later does nothing until you
  reset — the container warns explicitly when it sees exactly that situation.
- **Onboard before `up`.** Onboarding writes host-local Pretorin state, and a
  running gateway keeps a per-session `pretorin mcp-serve` child that can serve
  the older view (the preflight artifact carries a 3600-second TTL). If you do
  onboard while the gateway is running:

  ```sh
  docker compose run --rm cli openclaw mcp reload    # or restart the gateway
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
`:0.1.0` can be made to resolve to different bytes tomorrow. A digest is the
bytes: `@sha256:…` is a content address, so if it resolves at all, it resolves to
exactly the image that was built, smoked, scanned and inventoried by the release
run that produced it.

```sh
docker login ghcr.io          # the package is not public
docker pull ghcr.io/pretorin-ai/compliance-claw:0.1.0@sha256:<digest>
```

The digest is printed in the release run's job summary, and `compose.yaml` carries
the line to paste it into. The release job also proves the round trip itself: it
deletes the local image, pulls the digest back from the registry, runs it, and
regenerates the SBOM from the pulled bytes to confirm the package inventory
matches the one taken from the build.

Check what you are actually running at any time:

```sh
docker compose images                      # what compose resolved
docker inspect --format '{{index .RepoDigests 0}}' \
  ghcr.io/pretorin-ai/compliance-claw:0.1.0
```

### What this does and does not prove

> **The image is not signed.** A digest gives **integrity** — these exact bytes,
> not some other bytes wearing the same tag. It does not give **authenticity**:
> it is no proof of *who* built the image. Anyone who can push to the registry can
> publish a different digest, and nothing in a digest alone tells you which one
> came from this repository's release workflow.

Signing was designed in and deliberately dropped for this POC. Keyless cosign
would have written a permanent, publicly searchable Sigstore transparency-log
entry naming this repository, which is internal — a disclosure decision, not just
a technical one. The alternative, a signing key in CI, contradicts this
repository's rule that CI holds zero credentials.

If you need authenticity, treat that as the next step rather than assuming it:
see the hardening ledger in [SECURITY.md](SECURITY.md).

The SBOM is generated for every release in SPDX JSON and attached to the run as a
build artifact. It is not attached to the image, because attaching it as an OCI
attestation is a signing operation.

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

Import the manifest rather than assembling scopes by hand — that is the whole
reason it is committed. It requests upstream's **minimal** socket-mode scope set:
**12 bot scopes instead of the recommended 23**, dropping files, reactions, pins,
group DMs, `emoji:read` and `usergroups:read`.

**Already have a Slack app?** You do not need to recreate it. Any app with Socket
Mode enabled, an app-level token carrying `connections:write`, and a bot token
works — put its three values in `.env` and the rest of this section applies
unchanged. The manifest matters for a *new* app, where it saves you from
hand-picking scopes and from over-granting. Worth knowing if you reuse an older
app: it probably carries the broader recommended scope set, so it can read files,
reactions and group DMs that this deployment never uses.

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

`PRETORIN_KEY_MODE` (default `read-only`) is your declaration about the key —
`pretorin whoami` reports authentication but not scopes, so it cannot be detected.
`scripts/smoke.sh` reads it to decide whether attempting a write tool is safe.

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

## Upgrading

```sh
# 1. bump IMAGE_VERSION in versions.env and the image line in compose.yaml
# 2. pull and restart
docker compose pull && docker compose up -d
```

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
compliance-claw: WARNING — Slack is configured in .env but NOT in this volume's config.
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
| `plugins list` shows 8 plugins, not 1 | Slack not configured | Expected; the two profiles are documented above |

Logs and state:

```sh
docker compose logs -f openclaw
docker compose run --rm cli openclaw doctor
docker compose run --rm cli openclaw plugins inspect slack
scripts/onboard-targets.sh --verify-only
```

## Releasing

Tag-triggered. `.github/workflows/release.yml` builds `linux/amd64`, smokes the
image, blocks on fixable CRITICAL vulnerabilities, generates an SPDX SBOM, pushes
to GHCR, and then **pulls the published digest back and re-verifies it** — the
image is removed locally first so the pull cannot be served from cache, and the
SBOM is regenerated from the pulled bytes and compared against the built one.
It holds **no** Pretorin, model or Slack credentials — only the automatic
`GITHUB_TOKEN`, and it asserts that itself. It does not sign; see "Verifying what
you pulled".

```sh
# 1. bump IMAGE_VERSION in versions.env AND the image line in compose.yaml
#    (smoke.sh asserts the two agree; the workflow refuses a mismatched tag)
git tag v0.1.0 && git push origin v0.1.0
# 2. take the digest from the job summary and pin it in compose.yaml:
#      image: ghcr.io/pretorin-ai/compliance-claw:0.1.0@sha256:<digest>
```

Step 2 is not optional bookkeeping: a tag is mutable, so without the digest the
artifact an operator verified is not necessarily the one they later pull.

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
- Outstanding hardening is tracked in [SECURITY.md](SECURITY.md), including Docker
  file-based secrets, RBAC before shared channels, and the sandbox boundary.
