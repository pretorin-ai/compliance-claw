# Compliance Claw

OpenClaw with the Pretorin CLI attached, so an agent can review the repositories
you mount and do compliance work against your Pretorin system.

Compliance Claw is deliberately thin. Pretorin already provides the compliance
intelligence — the skill, the MCP tool surface, workflows, recipes, source
preflight, active recipe sets, plans. This repository supplies the runtime that
joins those to your code: a supply-chain-verified Pretorin binary, a configured
OpenClaw gateway, and the wiring that tells Pretorin which repositories this
deployment is about.

This is a POC. See `docs/plans/phase1.md` … `phase4.md` for what was built, what
was verified, and what is deliberately not done yet.

## Requirements

- Docker Desktop (or another daemon) with **linux/amd64** support. Upstream ships
  no linux/arm64 Pretorin binary, so on Apple Silicon this runs emulated — enable
  Rosetta for amd64 in Docker Desktop settings. `bootstrap.sh` checks this before
  it builds anything.
- `git`, `python3`, `openssl`. On macOS all three come with the Command Line
  Tools, which `git` already requires. No PyYAML, no `jq`, no `gh`, nothing to
  `pip install`.
- A Pretorin API key. **Read-only is the default and is sufficient** for
  everything here.

## Quickstart

```sh
# 1. declare what you are reviewing, and for which compliance scope
vi targets.yaml                  # system_id, framework_id, one or more targets

# 2. clone the targets, write .env, build the image
scripts/bootstrap.sh

# 3. put a read-only Pretorin key in .env
vi .env                          # PRETORIN_API_KEY=...

# 4. register the targets with Pretorin (idempotent; safe to re-run)
scripts/onboard-targets.sh

# 5. start the gateway
docker compose up -d             # http://127.0.0.1:18789

# anything one-off, in the same image with the same mounts:
docker compose run --rm cli pretorin --json context show
docker compose run --rm cli openclaw agent --agent main -m "..."
```

**Onboard before `up`.** Onboarding writes host-local Pretorin state, and a
running gateway keeps a per-session `pretorin mcp-serve` child that can serve the
older view (the preflight artifact carries a 3600-second TTL). If you do onboard
while the gateway is running:

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

## `targets.yaml`

```yaml
system_id: 7b74d8f3-d77c-49e4-8792-c372dd154d38   # UUID or system name
framework_id: soc2                                # the same system under two
                                                  # frameworks is two scopes
targets:
  - name: simple-crm                              # becomes the directory name
    url: https://github.com/pretorin-ai/simple-crm.git
    ref: main                                     # optional
```

One system and framework for the whole file; one or many targets. `bootstrap.sh`
clones each into `workspace/targets/<name>`, which compose bind-mounts
**read-only** at `/workspace/targets`. Only `https://` remotes that clone
anonymously are supported — private and SSH remotes are future work.

List the scopes your key can see:

```sh
docker compose run --rm cli pretorin --json context list
```

## Credentials

Both live in `.env`, which is gitignored and excluded from the Docker build
context. `bootstrap.sh` creates it from `.env.example` with a generated
`OPENCLAW_GATEWAY_TOKEN` and **never overwrites an existing one**.

`PRETORIN_API_KEY` is the access-control boundary. Compliance Claw registers the
full Pretorin tool surface and does not second-guess it: what the agent can do is
whatever the key authorizes, enforced server-side by the platform. A **read-only
key is the POC default** and covers bootstrap, onboarding and assessment, because
binding resolvers, verifying them and provisioning recipes write only host-local
state — the single platform call is a *read* of the recommended source-kind
profile. A **write-enabled key is an intentional opt-in** for platform writes
(evidence upload, control status, risks, vendors); nothing here escalates on its
own. On a shared channel every user inherits that key's authority with no
per-user attribution, so user-level attribution and RBAC come first.

`PRETORIN_KEY_MODE` (default `read-only`) is your declaration about the key —
`pretorin whoami` reports authentication but not scopes, so it cannot be
detected. `scripts/smoke.sh` reads it to decide whether attempting a write tool
is safe.

## Testing

```sh
scripts/smoke.sh              # Section A always; Section B if a key authenticates
scripts/smoke.sh --no-creds   # Section A only — exactly what CI runs
```

Section A needs no credentials at all: versions, the Pretorin MCP surface, the
`targets.yaml` parser, gateway startup and plugin pin, config and `AGENTS.md`
seeding, mount posture, the stale-template warning, bootstrap's refusal to
clobber, and the CWD fix — including a check that reads the working directory of
the live `pretorin mcp-serve` child. Section B proves onboarding end to end, that
a read tool succeeds through MCP, and that a write tool is rejected server-side.

## Resetting

```sh
docker compose down -v
```

This deletes **both** named volumes: the OpenClaw state volume (config, sessions,
agent workspace, your customised `AGENTS.md`) **and** the Pretorin state volume
(active context, preflight resolvers, active recipe set). It does **not** touch
the bind-mounted target repositories under `workspace/targets`. Recovery is
re-running `scripts/bootstrap.sh` and `scripts/onboard-targets.sh`; both are
idempotent.

`docker compose down` without `-v` keeps everything.

Config and `AGENTS.md` are seeded once and never overwritten, so a newer image
does not update an existing volume. When that happens the entrypoint prints a
warning naming the drift; it never edits your files. `down -v` is the reset.

## Notes

- `mcp.sessionIdleTtlMs` stays at its default `600000` — milliseconds, so 10
  minutes of idleness before a session's MCP child is reaped; `0` disables idle
  cleanup. Untuned until multi-session usage is measured.
- Every pin lives in `versions.env`, except the two base-image digests on the
  `FROM` lines (Docker cannot read a sourced file there).
- Hardening still outstanding before anything shared or production: Docker
  file-based secrets instead of `env_file`, user-level attribution and RBAC, and
  verifying the OpenClaw base image's own attestation.
