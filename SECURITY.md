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
4. **The base image ships five fixable CRITICAL vulnerabilities.** Measured, not
   estimated: two `libgnutls30` (Debian has `3.7.9-2+deb12u7`), one
   `@vitest/browser` — a test framework upstream ships inside a runtime image —
   and two vendored copies of `node-tar`, one inside npm and one inside
   corepack's pnpm. **Nothing this repository adds contributes any of them**; the
   Pretorin binary and the Slack plugin scan clean at CRITICAL. They cannot be
   patched here without running an unpinned `apt upgrade` over a digest-pinned
   base, so they are documented per-id in `.trivyignore.yaml` with a written
   justification and a **90-day expiry**, printed into every release job summary,
   and fixed properly by bumping `OPENCLAW_VERSION` and the runtime `FROM` digest
   once upstream rebuilds. The `libgnutls30` pair is the one to watch: unlike the
   others it sits on a live TLS path, and the reason for deferring it is
   inability to patch, not a claim that it is unreachable.
5. **Image signing — Azure Key Vault, following the Pretorin CLI.** The release
   publishes and verifies an immutable digest, which is integrity but not
   authenticity: nothing attests *who* built a given digest. **The image is
   unsigned today**, and there is no signature for an operator to verify.

   The planned resolution for production and the internal pilot is signing backed
   by **Azure Key Vault**, mirroring the approach the Pretorin CLI already uses for
   its own releases — a KMS-held key, not a key in CI, and not a public
   transparency-log entry. That reuses infrastructure and a review path the
   organisation already has, which is why it is preferred over the two options
   considered and rejected for this POC: keyless cosign, which writes a permanent
   publicly searchable transparency-log entry naming an internal repository, and a
   CI-held signing key, which contradicts the zero-credentials rule.

   Until it ships, the digest pin in `compose.yaml` is the image-integrity
   control. Nothing in this repository should tell an operator to run
   `cosign verify` against the Compliance Claw image.
6. **OpenClaw base-image attestation.** Phase 1's chain guarantees the *Pretorin
   binary* and Phase 5's gate guarantees the *Slack plugin*; the OpenClaw base
   image is trusted on its digest pin alone. Verifying upstream's own GHCR
   attestation would close the last unverified link in the image.
7. **RESOLVED — the release workflow can now be rehearsed.** It previously could
   not: GitHub only exposes `workflow_dispatch` for workflows on the **default
   branch**, and `release.yml` lived on a feature branch, so its first execution
   was the v0.1.0 tag push. It is now on `master` and carries a `dry_run` input
   (default true) that builds, smokes, scans and produces an SBOM without pushing
   or tagging:

   ```sh
   gh workflow run release.yml -f dry_run=true
   ```

   Kept in the ledger as history, because the reasoning still applies to any new
   workflow: a pipeline whose first run is a real release has never been tested.
8. **Connected Sources (`source_admin`) as the eventual binding source.** Local
   `preflight` resolvers are a host-local approximation. Connected Sources is also
   the **only** path to `branch_protection`, `code_review_records` and
   `pull_request_records` — i.e. the thing that resolves `code_repository`
   reporting `degraded`, which is expected today and cannot be fixed from a local
   checkout. Requires a scope this POC deliberately does not use.
9. **Config reconciliation instead of warn-and-`down -v`.** Templates are seeded
   write-if-absent and never overwritten, so a newer image cannot tighten an
   existing deployment's config. Today the entrypoint warns — including a specific
   warning when Slack is configured in `.env` but absent from an existing
   config — and `down -v` is the only reset.
10. **`tools.toolSearch` is experimental upstream.** Its runtime behaviour is
   observed working (`cataloged 223 tools behind compact directory surface`) but
   upstream marks all Tool Search modes experimental. If it regresses, the prompt
   returns to roughly 40k tokens per turn and the commented `toolFilter` block is
   the lever.
11. **Per-repository authorization.** Every target shares one Pretorin key and one
   scope. A reviewer who should see one repository sees all of them.
12. **`mcp.sessionIdleTtlMs` is untuned.** Default 600000 ms — ten minutes of
   idleness before a session's `pretorin mcp-serve` child (a 23 MB binary) is
   reaped; `0` disables idle cleanup. Fine for one operator, unmeasured for a
   shared channel where each session spawns its own child.
13. **Multi-arch is blocked upstream.** `SHA256SUMS` publishes only
    `linux-x86_64` and `macos-arm64`, so there is no linux/arm64 Pretorin binary
    to build against. Not deferred by choice — blocked. Apple Silicon runs amd64
    under emulation.
14. **Upstream feedback: `pretorin preflight unbind --id <resolver-id>`.**
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
- **cosign is pinned once, and only for the Pretorin binary.** `COSIGN_VERSION`
  `v2.4.1` verifies the Pretorin release blob at build time and cannot move:
  cosign v3 removed `verify-blob --signature`. There is deliberately no second
  pin, because nothing signs the container image — a pin no job consumes would
  advertise a verification that does not happen.
- **Trivy's release gate ignores unfixed CRITICALs.** A critical CVE in the base
  image with no upstream patch would otherwise make every release unshippable,
  and an unsatisfiable gate gets disabled. Unfixed criticals are printed in the
  job summary rather than dropped.
- **The published image is not signed, and the SBOM is not an attestation.** The
  release publishes by immutable digest and verifies the round trip in CI — the
  image is deleted locally, pulled back by digest, run, and its SBOM regenerated
  from the pulled bytes and compared against the built one. That is **integrity**:
  the bytes are the bytes that were scanned. It is not **authenticity**: nothing
  proves which digest came from this repository's workflow, so anyone who can push
  to the registry can publish another. The SBOM is retained as a workflow artifact,
  not attached to the image and not signed. Azure Key Vault–backed signing is
  ledger item 5 above — recorded as planned work, not quietly omitted.
