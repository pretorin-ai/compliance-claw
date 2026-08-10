# Phase 2 — Runtime image + compose

Goal: join Phase 1's verified Pretorin binary to OpenClaw in a runnable image, and define the compose
services that mount state and review targets. Nothing from later phases — the gateway is deliberately
left unconfigured.

**Status: IMPLEMENTED and validated.** Every check in "Validation" below was run against the
committed files. The gateway container starts and then exits `78` with `Missing config` — that is the
expected Phase 2 end state, not a defect; Phase 3 configures it.

## Established facts — the base image, verified rather than assumed

`docker pull --platform linux/amd64 ghcr.io/openclaw/openclaw:2026.7.1` resolves to OCI **index**
digest `sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c` (amd64 manifest
`sha256:165b4992…`; a linux/arm64 manifest is also published, so the OpenClaw side is not what blocks
multi-arch — the missing linux/arm64 Pretorin binary is). The `FROM` line pins the **index** digest,
matching Phase 1's `debian` pin, which is also an index digest: it still resolves per-platform, so
`--platform` keeps meaning what it says and the later multi-arch work needs no edit here.

The planned assumptions held; **no deviations**:

| Fact | Observed |
| --- | --- |
| User | `node`, `uid=1000 gid=1000`, `/bin/bash` |
| Home / state | `/home/node`; `/home/node/.openclaw` already exists in the image, `0700`, owned by `node` |
| Entrypoint / Cmd | `["tini","-s","--"]` / `["node","openclaw.mjs","gateway"]`, WorkingDir `/app` |
| `openclaw` | `/usr/local/bin/openclaw` → `/app/openclaw.mjs`; `openclaw --version` → `OpenClaw 2026.7.1` |
| Base | `node:24-bookworm-slim` — glibc Debian, which is what Phase 1's dynamically linked binary needs |
| Port | image healthcheck probes `127.0.0.1:18789/healthz`, confirming the port |

Three findings that shaped the implementation:

- **`tini -s --` passes arguments straight through** (`docker run <img> node --version` → `v24.16.0`),
  so the `cli` service needs no entrypoint override: `docker compose run --rm cli pretorin version`
  runs exactly that, and still gets tini's process reaping.
- **`~/.openclaw` ships in the image**, so a fresh named volume is seeded from it with `node`
  ownership. No `chown` on the state dir, and no init container.
- **`pretorin skill install --path`** is the right call: the built-in agent registry knows only
  `claude` and `codex` and roots both under `/root/`, which the non-root runtime user cannot read.

## Changes

| File | Change |
| --- | --- |
| `Dockerfile` | New final stage on the digest-pinned OpenClaw image: copies the verified binary from `pretorin-verify`, installs the skill to `/opt/compliance-claw/skills`, creates the target mount point, ends on `USER node`. Phase 1's stage is untouched. |
| `compose.yaml` | New. `openclaw` (gateway, loopback port) and `cli` (run-only profile), sharing one image, one state volume, and one read-only target mount via a YAML anchor. |
| `versions.env` | Comment only: bumping `OPENCLAW_VERSION` also requires re-pinning the runtime digest on the second `FROM` line. |
| `docs/plans/phase2.md` | This document. |

**Phase 1's `fetch-pretorin.sh` and `verify-pretorin.sh` needed no changes**, and neither did
`.dockerignore` (the runtime stage copies nothing from the build context) or `.gitignore`
(`workspace/` was already ignored).

The pin carve-out is now **two** `FROM` lines rather than one. Both the Dockerfile header and
`versions.env` say so, so a pin audit still knows where to look.

### Decisions worth the ink

**`platform: linux/amd64` sits on the service, not under `build:`.** `build.platform` is rejected by
the Compose schema (`additional properties 'platform' not allowed`) — found by running
`docker compose config`. The service-level key covers both the build and the container.

**`env_file` uses the long form with `required: false`.** `.env` is gitignored, and Phase 4's
bootstrap is what writes it; with the short form, every `docker compose` command fails on a fresh
clone. Phase 2 reads no value out of `.env`, and no secret is named in `compose.yaml`.

**A YAML anchor, not two hand-maintained service blocks.** The value is that `cli` cannot drift from
`openclaw` — a CLI whose mounts differ from the gateway's would debug a different container than the
one that runs.

**The bind mount is the *parent* of all targets, read-only.** No repo name appears in the image or in
compose; Phase 4 adds `targets.yaml` to select among whatever is mounted. Read-only is the point: the
agent reviews code, it never edits it.

**`/workspace/targets` is created in the Dockerfile** rather than left to the daemon, which creates a
missing mount point as root and leaves it unreadable to `node`.

## Validation — observed results

`docker build --platform linux/amd64 -t compliance-claw:local .` on Apple Silicon (qemu), then:

| Check | Result | Observed |
| --- | --- | --- |
| Build | **pass** | Phase 1 gates re-ran (`PRETORIN VERIFIED: 0.26.14`), skill installed to `/opt/compliance-claw/skills/pretorin` |
| `openclaw --version` | **0** | `OpenClaw 2026.7.1` |
| `pretorin version` | **0** | `pretorin version 0.26.14`, `path: /usr/local/bin/pretorin` |
| `pretorin mcp-smoke-test` | **0** | `PASSED — all 20 checks green` (mock-based; no API key involved) |
| Skill readable as `node` | **pass** | `SKILL.md` + `examples/` + `references/`, all owned by `node` |
| Container user | **pass** | `uid=1000(node)`; PID 1 is `tini` running as `node` |
| Write under `/workspace/targets` | **fails, as required** | `touch: cannot touch '/workspace/targets/canary': Read-only file system`; `/proc/mounts` shows `ro` |
| `docker compose config` | **pass** | `host_ip: 127.0.0.1`, `read_only: true` on the bind, named volume, and no environment values rendered |
| State survives `down` → `up` | **pass** | marker written under `~/.openclaw`, volume retained by `down`, marker still present after `up` |
| `docker compose run --rm cli …` | **pass** | runs one-off `openclaw`/`pretorin` commands as `node`; the profile keeps it out of `up` |

The skill installs with `0700`/`0600` modes — tighter than needed, harmless here because the tree is
`chown`ed to `node` and the process runs as `node`. Phase 3 should re-check this if it ever runs the
gateway under a different uid.

## Acceptance

Image builds for `linux/amd64` with the Phase 1 verification chain intact; both binaries run; the
process is non-root; the target mount is provably read-only; the gateway port is published on
loopback only; OpenClaw state survives `docker compose down` && `up`. No `.env` value, API key, or
token exists in the image, in `compose.yaml`, or in `git status`.

## Open questions for Phase 3

1. **Config location and shape.** `openclaw.json` lives at `~/.openclaw/openclaw.json`
   (`OPENCLAW_CONFIG_PATH`, with `OPENCLAW_STATE_DIR` / `OPENCLAW_CONFIG_DIR` as the env overrides) —
   inside the named volume, so config written once persists. The unconfigured gateway exits `78`
   with `Missing config. Run 'openclaw setup' or set gateway.mode=local (or pass
   --allow-unconfigured)`, which names the three ways in.
2. **Skill registration.** OpenClaw's documented loading order is workspace skills → `<workspace>/
   .agents/skills` → `~/.agents/skills` → `~/.openclaw/skills` → bundled → **`skills.load.extraDirs`
   (lowest)**. `skills.load.extraDirs` is therefore the hook for `/opt/compliance-claw/skills`.
   Lowest precedence means any same-named skill anywhere else silently wins — worth an explicit check
   in Phase 3 that the loaded `pretorin` skill is ours.
3. **Gateway token.** `~/.openclaw/gateway.token` / `OPENCLAW_GATEWAY_TOKEN`, and the upstream Docker
   flow generates the token during `onboard` and writes it to `.env`. `.env.example` already reserves
   the variable; Phase 3 decides which of the two is authoritative — do not let both drift.
4. **Whether config should be baked or generated.** Baking `openclaw.json` into the image conflicts
   with the volume seeding it; generating it on first start keeps the volume authoritative. This is
   the main Phase 3 design call, and Phase 4's bootstrap is the natural place for it.
5. **Config write path runs pre-start upstream** (`docker compose run --no-deps --entrypoint node
   openclaw-gateway dist/index.js config set …`). Our `cli` service does not share the gateway's
   network namespace, so it has no such ordering constraint — but it also means the upstream docs'
   `--no-deps` incantation is not the shape we need.

## Accepted limitations

- **The gateway is not usable yet** — by design. `docker compose up` starts a container that exits
  `78`; only `docker compose run --rm cli …` does anything useful in Phase 2.
- **`workspace/targets` must exist on the host** before `docker compose up`, or the daemon creates it
  root-owned. It is gitignored and deliberately not committed as a `.gitkeep`; Phase 4's bootstrap
  creates it. Until then: `mkdir -p workspace/targets`.
- **The image is not itself signed or attested.** Phase 1's chain guarantees the *Pretorin binary*
  inside it; the OpenClaw base is trusted on its digest pin alone. Verifying OpenClaw's own GHCR
  attestation is a real gap, and belongs with the GHCR publishing work rather than here.
