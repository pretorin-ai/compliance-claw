# Security

Compliance Claw is a **proof of concept**. This document states what it does
protect, what it deliberately does not, and everything known to be outstanding.
The hardening ledger at the end is complete as of Phase 5 — if something is not in
it, it was not considered, and that is worth telling us about.

Report a vulnerability to security@pretorin.com rather than opening an issue.

## The authorization model

Authorization is the **Pretorin API key's scopes, enforced server-side by the
platform**. Compliance Claw does not implement an access-control layer of its own
and does not second-guess the platform.

```
            ┌──────────────────────────────────────────────────────────┐
            │ OpenClaw gateway — transport and cost control, NOT authz  │
            │                                                           │
  operator  │  gateway.auth.token ──► who may talk to the gateway       │
  ────────► │  tools.toolSearch   ──► how many schemas reach the prompt │
     or     │  plugins.allow      ──► which plugin code loads at all    │
   Slack    │  channels.slack     ──► which channel, mention-only, no DMs│
            └───────────────────────────┬───────────────────────────────┘
                                        │ stdio, full 192-tool surface
                                        ▼
            ┌──────────────────────────────────────────────────────────┐
            │ pretorin mcp-serve                                        │
            │   PRETORIN_API_KEY ──► scope check, SERVER-SIDE   ◄── THE │
            │   read-only key   => write tools rejected        AUTHZ    │
            │   write key       => whatever the key authorizes BOUNDARY │
            └──────────────────────────────────────────────────────────┘
```

The full Pretorin tool surface is registered with no local allowlist. A read-only
key is the documented default and is sufficient for everything Compliance Claw
does: bootstrap, onboarding and assessment write only host-local state. Verified
directly — with a read-only key, `create_risk` through MCP returns
`Access denied: Missing required scopes: write`.

`toolFilter` ships commented out and is labelled a cost/context lever and defence
in depth, **not** an authorization control.

### A write-enabled key is an explicit opt-in

Nothing in this repository escalates on its own. Choosing a write-enabled key
enables platform writes: evidence upload, control status, risks, vendors.
`PRETORIN_KEY_MODE` in `.env` is your **declaration** about the key, not a check —
`pretorin whoami` reports authentication but no scopes, so key mode cannot be
detected. It only gates whether the smoke test attempts a write.

### Shared Slack channels: the attribution problem

**A shared Slack channel means every member of that channel acts with the
configured key's authority, and no per-user attribution exists anywhere.** The
platform sees one API key. It does not see which human typed the message, and
neither does the audit trail.

The documented posture is therefore:

> **Use a read-only Pretorin key for any shared channel.** A write-enabled key in
> a shared channel is explicitly warned against and should not be used until RBAC
> and user-level attribution exist. Any channel member could cause a platform
> record to be written, and nothing would record who did it.

What containment does exist is real but partial, and is not a substitute:

| Control | Effect |
| --- | --- |
| `dmPolicy: "disabled"` | No DMs at all — no unattributed private sessions |
| `groupPolicy: "allowlist"` + one channel ID | Only the channel you named is served |
| `requireMention: true` | The agent answers only when explicitly addressed |
| `configWrites: false` | Slack traffic cannot rewrite the gateway config |
| Socket Mode | Outbound only; no inbound port, no public URL |
| Minimal manifest | 12 bot scopes instead of the recommended 23 |

One honest gap in that table: the manifest grants `im:history`, `im:read` and
`im:write` because they are part of upstream's supported minimal scope set, while
DMs are closed one layer up in OpenClaw's config. The scopes are granted and
unused. Removing them is untested against the plugin.

## Credentials and where they live

| Secret | Lives in | Reaches the container? | In `docker inspect`? |
| --- | --- | --- | --- |
| `PRETORIN_API_KEY` | `.env` | yes (env) | **yes** |
| `OPENCLAW_GATEWAY_TOKEN` | `.env` | yes (env) | **yes** |
| `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` | `.env` | yes (env) | **yes** |
| GitHub App private key | `secrets/*.pem`, **host only** | **no** | no |
| Model credentials | OpenClaw state volume (device-code login) | volume | no |

Verified, with canary values: no secret of any class reaches the rendered
`openclaw.json`, either state volume, an image layer, or the container logs. The
Slack block in the config names no token at all — not even a `${VAR}` marker —
because OpenClaw reads both Slack tokens from the environment.

**The GitHub App private key is deliberately outside `.env`.** `.env` is handed to
the container wholesale by compose's `env_file`, so a key there would be a git
credential inside the container by construction. Instead the key stays on the
host, `bootstrap.sh` uses it to mint a token scoped to `contents:read` on exactly
the declared repositories, clones with it through a credential helper that keeps
it out of both the URL and the process table, deletes it on exit, and asserts that
no clone's `.git/config` retained it. The container sees only the resulting
working tree, read-only.

## What the POC does NOT protect against

- **`docker inspect` and anyone who can reach the Docker socket.** `env_file` is
  how three secrets reach the container, so they are visible to any process that
  can query the daemon. Docker file-based secrets would close this; see the
  ledger. The realistic vector is `docker inspect` output pasted into a ticket.
- **A malicious or compromised review target.** Tool execution inside the
  container is **unsandboxed** (`sandbox` is off). See the boundary statement
  below — this is the single most important limitation in this document.
- **Any Slack channel member.** Everyone in the allowlisted channel has the same
  authority. There is no per-user policy and no attribution.
- **A hostile operator.** Anyone who can edit `.env`, `targets.yaml` or the state
  volume controls the deployment. There is no separation of duties.
- **Multi-tenancy of any kind.** One key, one scope, one channel, one operator.
- **Prompt injection.** Content in a reviewed repository reaches the model. A
  crafted file can influence what the agent says and which tools it calls. The
  read-only key is what bounds the damage, which is the main reason it is the
  default.
- **Host compromise.** The GitHub App key, `.env` and the Docker socket are all
  on the host, so host access is total access.

### The sandbox boundary — say it plainly

OpenClaw's sandbox is **not enabled**. Tools that execute commands do so directly
inside the container as `node` (uid 1000), with the target repositories mounted
read-only and both state volumes writable.

> **Required hardening before onboarding third-party or untrusted repositories:**
> trim the tool surface, evaluate and enable OpenClaw's sandbox, and move secrets
> out of the environment. Until all three are done, only review repositories your
> organisation already trusts.

Phase 5 does part of the first item: `plugins.allow: ["slack"]` is an exclusive
allowlist, so the runtime activates one plugin instead of eight and the `browser`
plugin in particular is not loaded. That reduces the surface; it does not create a
boundary. Sandbox enablement is future work, not a documented posture that can be
substituted for it.

## Hardening ledger — everything outstanding

Ordered roughly by how much it matters, not by effort.

1. **Docker file-based secrets instead of `env_file`.** Keeps `PRETORIN_API_KEY`,
   `OPENCLAW_GATEWAY_TOKEN` and the Slack tokens out of `docker inspect`. Reopens
   the "single authoritative token source" decision, so it needs a call rather
   than a patch.
2. **RBAC and user-level attribution before any shared channel with a
   write-enabled key.** The prerequisite for treating Slack as more than a
   read-only surface. Until it exists, the read-only posture above is the control.
3. **Fail-closed runtime-pin validation.** The `models.providers.openai.
   agentRuntime` pin is currently observable only as a log line the smoke test
   greps. If it silently regressed, agent turns would route through the Codex
   app-server plugin, which does not receive `tools.toolSearch` and bypasses
   `toolFilter`. A startup assertion that refuses to serve on the wrong runtime
   would make this fail closed instead of fail quietly.
4. **OpenClaw base-image attestation.** Phase 1's chain guarantees the *Pretorin
   binary* and Phase 5's gate guarantees the *Slack plugin*; the OpenClaw base
   image is trusted on its digest pin alone. Verifying upstream's own GHCR
   attestation would close the last unverified link in the image.
5. **Connected Sources (`source_admin`) as the eventual binding source.** Local
   `preflight` resolvers are a host-local approximation. Connected Sources is also
   the **only** path to `branch_protection`, `code_review_records` and
   `pull_request_records` — i.e. the thing that resolves `code_repository`
   reporting `degraded`, which is expected today and cannot be fixed from a local
   checkout. Requires a scope this POC deliberately does not use.
6. **Config reconciliation instead of warn-and-`down -v`.** Templates are seeded
   write-if-absent and never overwritten, so a newer image cannot tighten an
   existing deployment's config. Today the entrypoint warns — including a specific
   warning when Slack is configured in `.env` but absent from an existing
   config — and `down -v` is the only reset.
7. **`tools.toolSearch` is experimental upstream.** Its runtime behaviour is
   observed working (`cataloged 223 tools behind compact directory surface`) but
   upstream marks all Tool Search modes experimental. If it regresses, the prompt
   returns to roughly 40k tokens per turn and the commented `toolFilter` block is
   the lever.
8. **Per-repository authorization.** Every target shares one Pretorin key and one
   scope. A reviewer who should see one repository sees all of them.
9. **`mcp.sessionIdleTtlMs` is untuned.** Default 600000 ms — ten minutes of
   idleness before a session's `pretorin mcp-serve` child (a 23 MB binary) is
   reaped; `0` disables idle cleanup. Fine for one operator, unmeasured for a
   shared channel where each session spawns its own child.
10. **Multi-arch is blocked upstream.** `SHA256SUMS` publishes only
    `linux-x86_64` and `macos-arm64`, so there is no linux/arm64 Pretorin binary
    to build against. Not deferred by choice — blocked. Apple Silicon runs amd64
    under emulation.
11. **Upstream feedback: `pretorin preflight unbind --id <resolver-id>`.**
    `unbind --name` removes *every* resolver with that name, and names derive from
    directory basenames, so two targets that both own `docs/` collide. The
    sweep-then-bind ordering makes this safe rather than merely tolerable; an
    id-scoped unbind would retire the constraint entirely.

### Accepted, with reasons

- **`ca-certificates` and `curl` are installed unpinned** in the verify stage, so
  builds are not byte-reproducible and the CA bundle is the one unpinned link in
  an otherwise fully pinned chain. Pinning exact Debian package versions breaks
  builds whenever a mirror drops an old version, which is the worse failure mode
  at POC stage.
- **cosign is pinned twice, deliberately.** `v2.4.1` verifies the Pretorin release
  blob and cannot move: cosign v3 removed `verify-blob --signature`. A separate
  `COSIGN_CI_VERSION` signs the published image, because keyless signing
  transacts with the live Sigstore trust root and cannot be exercised outside CI.
- **Trivy's release gate ignores unfixed CRITICALs.** A critical CVE in the base
  image with no upstream patch would otherwise make every release unshippable,
  and an unsatisfiable gate gets disabled. Unfixed criticals are printed in the
  job summary rather than dropped.
- **The published image is referenced by tag until a release exists.** A tag is
  mutable; the digest is the artifact. The release workflow prints the digest for
  pinning in `compose.yaml`, and that pin is the intended steady state.
