# Phase 3 — Gateway config, MCP registration, key-scoped access

Goal: turn Phase 2's `exit 78` container into a usable gateway. Config is generated on first start,
`pretorin mcp-serve` is registered with its full tool surface, and access control is the Pretorin API
key's scopes rather than anything hard-coded here.

**Status: IMPLEMENTED and validated.** All 11 unconditional gates pass against the committed files.
Four gates need credentials this environment does not have and are marked as not run.

## Authorization model

Compliance Claw does **not** hard-code read-only at the OpenClaw MCP layer.

```
            ┌──────────────────────────────────────────────────────────┐
            │ OpenClaw gateway — transport and cost control, NOT authz  │
            │                                                           │
  operator  │  gateway.auth.token ──► who may talk to the gateway       │
  ────────► │  tools.toolSearch   ──► how many schemas reach the prompt │
            │  toolFilter (OFF)   ──► optional operator cost lever      │
            └───────────────────────────┬───────────────────────────────┘
                                        │ stdio, full 192-tool surface
                                        ▼
            ┌──────────────────────────────────────────────────────────┐
            │ pretorin mcp-serve                                        │
            │   PRETORIN_API_KEY ──► scope check, SERVER-SIDE   ◄── THE │
            │   read-only key   => write tools rejected        AUTHZ    │
            │   write key       => whatever the key authorizes BOUNDARY │
            └──────────────────────────────────────────────────────────┘

  Independent of the above, and verified separately: /workspace/targets is
  mounted ro; the state volume and the agent workspace stay writable.
```

`toolFilter` ships **commented out**, labelled a cost/context lever and defence in depth, explicitly
not an authorization control. It is the fallback if `tools.toolSearch` misbehaves, not the primary
mitigation.

**Shared-channel deployments need a restricted key.** A write-enabled key plus a shared channel means
every channel user inherits that key's authority with no per-user attribution. Phase 3 ships
single-operator. User-level attribution and RBAC are prerequisites for anything else.

## Established facts, verified against the image

**`toolSearch: true` is not the compact directory.** `true` selects `code` mode, which exposes
`tool_search_code`, a JavaScript bridge in a sandboxed Node subprocess. The compact-directory
behaviour is `{ mode: "directory" }`, which defers schemas behind `tool_search`/`tool_describe`/
`tool_call` and adds no code-execution surface. We use `directory`. There is no 18,000-char cap in
2026.7.1; the only sizing knobs are `searchDefaultLimit` (8) and `maxSearchLimit` (20). Upstream
marks all Tool Search modes experimental.

**Tool catalog cost, measured off a live `tools/list`:** 192 tools, 162,885 B, of which inputSchemas
106,787 B, descriptions 41,360 B, names 4,927 B. Roughly 40k tokens per turn advertised directly.
Directory mode defers the schemas, giving a computed upper bound near 46 KB, about a 72% reduction.
The exact runtime figure is an operator measurement: `/context list` reports it as
`Tool schemas (JSON): N chars`.

**The Codex runtime is a live alternate path, not a theoretical one.** Removing
`models.providers.openai.agentRuntime` and running a turn loads a 9th plugin (`codex`), logs
`[agent/embedded] codex app-server one-shot cleanup`, and calls `api.openai.com/v1/responses`
directly. The image has no `codex` **binary**, but the Codex **app-server plugin** at
`/app/extensions/codex` needs none. With the pin the gateway logs 8 plugins with `codex` absent. The
pin matters for the auth path, for billing reproducibility, and because shipped
`docs/tools/tool-search.md` says *"Codex harness runs do not receive these experimental OpenClaw Tool
Search controls"* — without it `toolSearch` does not apply at all.

**`bind: "lan"` is required and is not a widening.** Upstream's Docker doc: with bridge networking a
`loopback` bind listens on the container's own `127.0.0.1` and a published port can never reach it.
The exposure boundary stays compose's `127.0.0.1:18789:18789` publish plus token auth. Reachability
is host loopback plus the compose project network (`openclaw`, `cli`).

**`/healthz` does not enforce auth** (200 with no token), and `/openclaw/` returns 200 even with a
wrong token because the Control UI authenticates over the WebSocket. `POST /tools/invoke` is the
endpoint that enforces it, so that is what the gate uses.

**`${VAR}` is OpenClaw's config-load substitution, not shell.** The literal text lands in the volume;
the value resolves in memory from the container env that `compose.yaml`'s `env_file` supplies.

## Changes

| File | Change |
| --- | --- |
| `scripts/openclaw-config.template.json` | New. The generated config, as reviewable JSON5, with `@MODEL@` baked at build time and a commented `toolFilter` block. |
| `scripts/agents-md.template` | New. Seeds the agent workspace with the Pretorin routing instruction. |
| `scripts/entrypoint.sh` | New. Scoped token pre-check, write-if-absent seeding of both files, then `exec` tini. |
| `Dockerfile` | Runtime stage: copies the templates and `versions.env`, bakes `MODEL`, asserts tini, sets `ENTRYPOINT` **and restates `CMD`**. |
| `.env.example` | `PRETORIN_API_KEY` documented as the access-control boundary; `OPENCLAW_GATEWAY_TOKEN` as required and Phase-4-owned. |
| `compose.yaml` | Comments only. No functional change. |

Phase 1's `fetch`/`verify` scripts, `vendor/`, and `.dockerignore` needed no changes: the new files
live under `scripts/`, which the allowlist already admits.

### Startup flow

```
docker compose up
   │
   ├─ args contain "gateway" AND token unset/empty? ─► name .env, exit 1
   │     (scoped, so `run --rm cli pretorin version` still works with no .env)
   │
   ├─ ~/.openclaw/openclaw.json absent? ─► install -m 0600 template   ─┐
   │                            present ─► "keeping it"                ├─ never clobbers
   ├─ <workspace>/AGENTS.md absent?     ─► install -m 0600 template   ─┤
   │                            present ─► "keeping it"                ┘
   │
   └─ exec /usr/bin/tini -s -- "$@"   ─► tini is PID 1, as inherited
```

All entrypoint messages go to **stderr**. Found by a gate: on stdout they corrupt
`openclaw ... --json` output for any consumer, because the wrapper also runs for the `cli` service.

### Decisions worth the ink

**Config is generated, not baked.** `~/.openclaw` is a named volume, so anything baked into the image
is shadowed on first start. Generating keeps the volume authoritative and operator edits durable.

**The token check is scoped to gateway invocations, not global.** Requiring a gateway token for
`docker compose run --rm cli pretorin version` would break Phase 2's documented workflow on a fresh
clone, where `.env` is `required: false`. OpenClaw already fails closed on its own; the pre-check only
replaces a `SecretRefResolutionError` pointing at `openclaw gateway status --deep` with a message
naming the file the operator actually has to edit.

**`agents.defaults.workspace` is stated explicitly** rather than left to its default, so the path the
entrypoint seeds and the path the runtime reads are provably the same. The alternative failed
silently: the agent simply never sees the routing instruction.

**`CMD` is restated in the Dockerfile.** Docker resets an inherited `CMD` to null whenever a stage
sets `ENTRYPOINT`. Omitting it hands tini zero arguments, and tini answers by printing its usage and
exiting 1. This was found by gate 1, not by reading the docs.

**`RUN test -x /usr/bin/tini`** turns a base image that moves or drops tini into a build failure
rather than a deploy-time one, matching Phase 1's habit of asserting its own assumptions.

## Validation — observed results

`docker build --platform linux/amd64 -t compliance-claw:local .` then `docker compose up -d`, with a
canary `PRETORIN_API_KEY=CANARY-PRETORIN-KEY-9f3a1c7e2b`.

| # | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | Gateway starts and stays up | **pass** | `Up (healthy)`; entrypoint seeded both files; no exit 78 |
| 2 | Auth enforced on `POST /tools/invoke` | **pass** | no token `401`, wrong token `401`, good token `404 not_found` (auth passed, tool not an HTTP tool). `/healthz` is `200` unauthenticated **by design** and proves nothing |
| 3 | Config idempotent | **pass** | marker appended, `down` && `up` → `openclaw.json exists, keeping it`, marker present, gateway healthy |
| 4 | Missing token fails closed | **pass** | `Exited (1)`, `compliance-claw: OPENCLAW_GATEWAY_TOKEN is unset or empty.` |
| 4b | `cli` still works with no token | **pass** | `pretorin version 0.26.14` |
| 5 | Full tool surface, no filtering | **pass** | `tools=192`, no `filteredTools` key; `apply_campaign`, `create_evidence`, `create_risk`, `create_vendor` all advertised; `mcp doctor pretorin --probe` → `ok` |
| 6 | Runtime pin holds (drift alarm) | **pass** | `http server listening (8 plugins: browser, canvas, device-pair, file-transfer, memory-core, ollama, phone-control, talk-voice)` — `codex` absent |
| 7 | Secret containment | **pass** | canary count: rendered config `0`, whole state volume `0`, image layers `0`, `docker compose logs` `0`. Config holds the literal `env: { PRETORIN_API_KEY: "${PRETORIN_API_KEY}" }`, mode `600 node`. `docker inspect` `1`, **expected** |
| 8 | Skill shadow check | **pass** | `Source: openclaw-extra`, `Path: /opt/compliance-claw/skills/pretorin/SKILL.md` |
| 9 | Skill modes readable | **pass** | `700 node` dir, `600 node` SKILL.md, readable as `node` |
| 10 | AGENTS.md seeded and preserved | **pass** | ours 648 B at 06:04; bootstrap added SOUL/TOOLS/IDENTITY/USER/HEARTBEAT/BOOTSTRAP at 06:07; our content intact |
| 11 | Turn reaches the pinned runtime | **pass** | `ProviderAuthError` / `Auth store: …/openclaw-agent.sqlite`, **no** `api.openai.com` 401 |
| — | Mount posture | **pass** | `/workspace/targets` `ro` (`Read-only file system`), state volume and agent workspace writable, PID 1 `tini`, uid `node` |

### Not run — require credentials

| # | Check | Blocked on |
| --- | --- | --- |
| 12 | `check_context` round-trips through the agent runtime | OpenAI device-code login |
| 13 | `toolSearch` directory surface active; schema loads on demand; record real directory size via `/context list` | OpenAI device-code login. Not observable earlier: an agent turn at `--log-level debug` emits zero tool-search lines to stdout or `/tmp/openclaw/*.log` before the auth failure |
| 14 | Write tool rejected server-side with a read-only key | a real read-only `PRETORIN_API_KEY` |
| 15 | Write tool accepted with a write-enabled key | a real write-enabled key |

Operator procedure for 14 and 15, once a key exists:

```sh
docker compose run --rm cli openclaw agent --agent main \
  -m "Call create_evidence for any control and report the exact error."
# read-only key  -> the platform rejects it server-side
# write key      -> it is accepted
```

Auth state for the device-code flow lands in the named volume at
`~/.openclaw/agents/main/agent/openclaw-agent.sqlite` (confirmed as the store path; `Profiles: (none)`
here).

### Known benign result

`openclaw mcp doctor pretorin --probe` warns `env.PRETORIN_API_KEY contains a literal sensitive value`
**only when the variable is set**, because doctor reads the post-substitution config held in memory.
Re-running with it unset makes the warning disappear. The file on disk never holds the value.

## Acceptance

Gateway starts, stays up, and is reachable on host loopback with the token. Config generation is
idempotent across restarts. The full Pretorin tool surface is registered with no hard-coded
allowlist, and authorization is the key's scopes. No secret reaches `openclaw.json`, the state volume,
an image layer, container logs, or `git status`. The skill resolves to the image copy. Target mounts
are read-only; state and workspace are writable.

## Accepted limitations

- **`PRETORIN_API_KEY` and `OPENCLAW_GATEWAY_TOKEN` appear in `docker inspect`.** `env_file` is how
  they reach the container, so this is unavoidable while env is the transport. Everything a Docker
  socket does not already grant is still closed. The real vector is `docker inspect` output pasted
  into a ticket or CI log. Docker file-based secrets would close it; see hardening notes.
- **A newer image does not update an existing volume's config.** Never-clobber is the point, but it
  means a tightened template has no effect on an existing deployment. `docker compose down -v` is the
  reset. Reconciliation is a Phase 4 question.
- **`tools.toolSearch` is experimental upstream** and its runtime behaviour is unverified here. If it
  regresses, the prompt returns to roughly 40k tokens per turn and the commented `toolFilter` block is
  the lever.
- **Comments in `openclaw.json` are JSON5 and survive on disk**, but would be lost if OpenClaw ever
  rewrites the file itself, for example `openclaw doctor --fix`.
- **Each session spawns its own `pretorin mcp-serve` child** (a 23 MB binary), reaped by
  `mcp.sessionIdleTtlMs`, default 10 minutes. Fine for one operator.

## Hardening notes (not Phase 3)

- Docker file-based secrets for both credentials, replacing `env_file`, to keep values out of
  `docker inspect`. Reopens the "single authoritative token source" decision, so it needs a call.
- User-level attribution and RBAC before any shared-channel deployment with a write-enabled key.

## Open questions for Phase 4

1. **Stale-config drift.** Reconcile strategy, or document `down -v` as the upgrade path.
2. **Key provisioning.** Bootstrap should probably default to a read-only key and require an explicit
   opt-in for a write-enabled one.
3. **Docker file-based secrets** for `PRETORIN_API_KEY` and `OPENCLAW_GATEWAY_TOKEN`.
4. **`toolSearch` fallback policy.** If it regresses, does bootstrap uncomment `toolFilter`
   automatically, or only warn?
5. **Per-session MCP children** before any multi-session use.
