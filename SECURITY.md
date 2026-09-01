# Security

Compliance Claw is a **proof of concept**. This document states what it does
protect, what it deliberately does not, and everything known to be outstanding.
The hardening ledger at the end is complete as of the CLI self-update release — if
something is not in
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

Nothing in this repository escalates on its own, and nothing in it restricts
either. **The key's server-side scopes are the sole authorization boundary.**
Choosing a write-enabled key enables platform writes — evidence upload, control
status, risks, vendors — and choosing a read-only key means the platform rejects
them. Compliance Claw applies no local permission filtering, ships no local
"mode", and does not default a deployment to a locally-restricted posture; a
rejection you see is Pretorin's, not ours.

`pretorin whoami` reports authentication but no scopes, so the smoke test cannot
discover which kind of key it holds. It takes the expected outcome as an argument
instead (`--expect-read-only` / `--test-write-enabled`), and attempts no write
without one. That is a property of the harness, not of the deployment.

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
| `users: ["*"]` per channel | Slash commands are authorized by **membership of that configured channel** — the channel is the trust boundary, not an individual allowlist. Anyone who can post in a served channel can run its commands |
| `configWrites: false` | Slack traffic cannot rewrite the gateway config |
| Socket Mode | Outbound only; no inbound port, no public URL |
| Minimal manifest | 12 bot scopes instead of the recommended 23 |

`users: ["*"]` is worth reading twice: it does **not** widen which channels are
served — `groupPolicy: "allowlist"` still admits only the channels generated from
`efforts.yaml`, and DMs stay disabled. It means that within an admitted channel,
every member may run `/compliance-claw ...`. Control who is in the channel.

One honest gap in that table: the manifest grants `im:history`, `im:read` and
`im:write` because they are part of upstream's supported minimal scope set, while
DMs are closed one layer up in OpenClaw's config. The scopes are granted and
unused. Removing them is untested against the plugin.

## Credentials and where they live

| Secret | Legacy `.env` path | File-secret path | In `docker inspect` with file secrets? |
| --- | --- | --- | --- |
| `PRETORIN_API_KEY` | value in container env | `/run/secrets/pretorin_api_key` | no |
| `OPENCLAW_GATEWAY_TOKEN` | value in container env | `/run/secrets/openclaw_gateway_token` | no |
| Slack tokens | values in container env | two `/run/secrets/*` mounts | no |
| Model API keys | values in container env | provider `/run/secrets/*` mount | no |
| GitHub App private key | host only | host only | no |
| GitHub read-only PAT | not available | `/run/secrets/github_readonly_pat` (gateway only) | no |
| Device-code model credential | state volume | state volume | no |

The file-secret path is `compose.secrets.yaml`; how to select it, what the Azure
pilot does today, and the deferred Key Vault mapping are in
[file-backed runtime secrets](docs/file-secrets.md).

Verified, with canary values: no **complete** secret of any class reaches the
rendered `openclaw.json`, either state volume, an image layer, `docker inspect`,
or the container logs. The Slack block in the config names no token at all — not
even a `${VAR}` marker — because OpenClaw reads both Slack tokens from the
environment. One upstream caveat was measured during the file-secret test: an
OpenAI `401 invalid_api_key` response includes a masked key fingerprint, and
OpenClaw logs that response (prefix and suffix, not the complete key). Treat
runtime logs as sensitive and do not paste them into public issues.

**The GitHub App private key is deliberately outside every container secret
path.** It is needed only for host-side cloning; mounting it would create an
unnecessary git credential inside the agent. Instead the key stays on the
host, `bootstrap.sh` uses it to mint a token scoped to `contents:read` on exactly
the declared repositories, clones with it through a credential helper that keeps
it out of both the URL and the process table, deletes it on exit, and asserts that
no clone's `.git/config` retained it. The container sees only the resulting
working tree, read-only.

### The PAT is a deliberately relaxed invariant, not an oversight

Earlier releases said flatly that the container never holds a git credential.
**That is no longer true, and the docs that said it have been corrected rather
than left standing.**

Target synchronization from Slack runs inside the container, so a private target
needs a credential *there* — and the App private key cannot be it, for the reason
directly above. The pilot therefore accepts a **fine-grained,
selected-repositories, Contents: Read-only PAT**, mounted read-only on the
gateway service alone.

What is still true, and enforced:

- It is the **only secret with no environment variable**. Every other credential
  is exported into PID 1 by the entrypoint; this one is read from the mounted
  path by a git credential helper at the moment git asks. `smoke.sh` fails if a
  `GITHUB_READONLY_PAT_FILE` ever appears on either service.
- It is never in a URL, in `argv`, in `.git/config`, in the audit record, in any
  message the plugin returns, or in the image. Asserted after every authenticated
  operation and canary-tested offline in `sync-targets.sh --self-test`.
- `bootstrap.sh` prefers the GitHub App and **will not fall back to the PAT if
  minting fails** — a broken App stops the run rather than silently substituting
  a longer-lived personal credential.
- `cli` does not get it. Only the gateway carries the sync routes.

What is **not** true: that this puts the token beyond a prompt-injected agent.
Tool execution here is unsandboxed and runs as the same uid, so the file is
readable by anything the agent can run. The containment that actually bounds the
damage is GitHub's: read-only, one permission, only the selected repositories.
The GitHub App remains the recommended mechanism for anything past this pilot,
and moving the synchronizer into its own container is the fix — see the ledger.

## The Pretorin CLI trust root, and how this release changes it

Until this release the Pretorin CLI was part of the image, so its bytes were
covered by `PRETORIN_SHA256` in `versions.env` — a fail-closed pin, checked at
build time against the cosign-signed `SHA256SUMS`, that would refuse the build
even if the upstream signing key were compromised and used to sign different
bytes.

**That pin now governs the SEED only.** The CLI a deployment runs lives in the
`pretorin-state` volume and is updated in place by `scripts/pretorin-update.sh`,
which delegates to the CLI's own signed `pretorin update`. After the first
update, what stands behind those bytes is upstream's signature verification, not
a pin in this repository.

**State the cost plainly.** Before, a compromised Pretorin signing key could only
reach deployments if someone cut a Compliance Claw release, and the local pin
would have refused it. Now it reaches a deployment on the next update, with no
repo-side check that fails closed. That is a real reduction in defence-in-depth,
accepted here because the alternative — a release cycle for every upstream
dependency bump — produced deployments that stayed months behind, and because the
component in question holds the Pretorin API key and runs with unsandboxed tool
execution either way. It is ledger item 3.

What did **not** change: the seed is still pinned and still fails closed at build
time, the anchor is still vendored and reviewed in a diff (`vendor/README.md`),
and the image is still unsigned with its digest as the integrity control.

### The local plugins are audited paths, not security boundaries

Two plugins expose one fixed action each, by two routes each. The command routes
(`/compliance-claw /pretorin-update`, `/compliance-claw /target-sync`) bypass the model entirely and
cannot be reached by a prompt-injected agent. The tool routes can be,
deliberately, in this trusted-repository pilot, and each has a bounded blast
radius:

- `pretorin_update` — *which signed Pretorin version installs*. No command, path
  or URL is expressible.
- `target_sync` — *which already-declared target fast-forwards*. Only `all` or a
  name declared for **the calling agent's own effort** in the mounted
  `efforts.yaml` is accepted; no URL, ref, path, flag or shell fragment is
  expressible; nothing can add, remove, re-point or onboard a target; and the
  operation itself is fast-forward-only, so it cannot reset, discard local
  changes, switch branches or delete anything. A target that cannot move safely
  is reported and left alone. Which effort is calling comes from the OpenClaw
  agent id, which the host resolves from the routed session before the tool runs
  — it is not a parameter, so a prompt cannot name a different effort.

The writable maintenance mount that synchronization needs is on the gateway
service only, at a path distinct from the read-only assessment mount. **That is
process-level separation inside one container, not a boundary** — the agent runs
as the same uid and can reach it. What it buys is that the assessment path, which
every evidence citation comes from, stays read-only.

**Neither route is a boundary, and the docs must not imply otherwise.** Tool
execution in this container is unsandboxed (see below), so an agent can already
run the wrapper directly, replace the binary in the volume without it, and
rewrite the audit file afterwards. What the updater provides is a *narrow,
identity-bearing, audited path for the supported routes* — and it adds no
LLM-reachable capability that `exec` did not already provide. Closing that gap is
ledger item 4.

### Separating one effort from another — say it plainly

One deployment now serves several compliance efforts, each with its own Slack
channel, OpenClaw agent, workspace, sessions, memory and Pretorin MCP server.
**That separation is a tool-visibility and prompt boundary, not an enforced
one**, and the generated instructions tell each agent to say so rather than imply
otherwise.

What it actually consists of:

- Each agent's tool policy **denies** every other effort's Pretorin MCP tool
  prefix, so another effort's tools are not in its catalogue and a call to one is
  refused. This is real and is enforced by OpenClaw, but `mcp.servers` is
  **gateway-wide**: the isolation is in the policy, not in the process.
- Each agent's workspace holds a `targets/` view of only its own repositories.
  Tool execution is unsandboxed and runs as the same uid, so an absolute path
  still reaches another effort's clone. The view is a scoping aid.
- Each Pretorin MCP child is started by a launcher that pins
  `PRETORIN_SYSTEM_ID` / `PRETORIN_FRAMEWORK_ID` from the read-only mounted
  `efforts.yaml` and loads that effort's own credential file. It fails closed
  rather than inheriting the container-wide key.

**The enforced boundary is the Pretorin API key.** Its server-side scopes, and
the platform's cross-scope write guard reading the pinned environment, are what
actually stop one effort's agent writing into another's scope. A single
organization-wide key therefore still permits cross-system *reads*; a key per
system is the operator's option for hard platform isolation, and `credential_ref`
exists to make that a per-effort choice.

**Slack authorization is per channel, not per user.** Every member of an effort's
channel has that effort's full authority, and an authorized DM has the authority
of the one effort it is bound to. Keep channel membership to the people who
should be able to act in that compliance scope.

## What the POC does NOT protect against

- **Legacy `.env` deployments.** The base Compose file still uses `env_file` for
  backward compatibility, so those deployments expose secret values to anyone
  who can query the daemon. `compose.secrets.yaml` closes that specific path.
- **The running process and Docker administrator.** The entrypoint must export
  mounted values because OpenClaw and the Pretorin child consume environment
  variables. Root, the same UID inside the container, or a Docker administrator
  can inspect a live process. File secrets protect delivery and routine inspect
  output; they do not make a compromised workload unable to use its credential.
- **Provider error fingerprints in logs.** An invalid OpenAI key produces a
  masked prefix/suffix in OpenClaw's error log. Full canary values remained
  absent, but log access and export still require access control and redaction.
- **A malicious or compromised review target.** Tool execution inside the
  container is **unsandboxed** (`sandbox` is off). See the boundary statement
  below — this is the single most important limitation in this document. Since
  target synchronization landed, this also means the read-only GitHub PAT and the
  writable maintenance mount are both reachable by a prompt-injected agent.
- **Any Slack channel member.** Everyone in the allowlisted channel has the same
  authority. There is no per-user policy and no attribution.
- **A hostile operator.** Anyone who can edit `.env`, `efforts.yaml` or the state
  volume controls the deployment. There is no separation of duties.
- **Multi-tenancy of any kind.** Several efforts now share one gateway, one
  container and one uid. See the boundary statement below.
- **Prompt injection.** Content in a reviewed repository reaches the model. A
  crafted file can influence what the agent says and which tools it calls. The
  read-only key is what bounds the damage, which is the main reason it is the
  default.
- **Host compromise.** The GitHub App key, `.env` and the Docker socket are all
  on the host, so host access is total access.

### The sandbox boundary — say it plainly

OpenClaw's sandbox is **not enabled**. Tools that execute commands do so directly
inside the container as `node` (uid 1000), with the target repositories mounted
read-only for assessment, both state volumes writable, and — on the gateway — a
writable maintenance alias of the target directory plus a mounted read-only
GitHub PAT that target synchronization needs. Same uid, same container: the split
between those paths is separation of *purpose*, not of *privilege*.

> **Required hardening before onboarding third-party or untrusted repositories:**
> trim the tool surface, evaluate and enable OpenClaw's sandbox, and move secrets
> out of the environment. Until all three are done, only review repositories your
> organisation already trusts.

Phase 5 does part of the first item: `plugins.allow` is an exclusive allowlist, so
on a Slack deployment the runtime activates the three local/Slack plugins instead
of eight bundled ones and the `browser` plugin in particular is not loaded. That reduces the surface; it does not create a
boundary. Sandbox enablement is future work, not a documented posture that can be
substituted for it.

## Hardening ledger — everything outstanding

Ordered roughly by how much it matters, not by effort.

1. **Adopt the file-secret deployment path everywhere.** `compose.secrets.yaml`
   now keeps `PRETORIN_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`, Slack tokens and model
   API keys out of `docker inspect`; the legacy `.env` path remains for backward
   compatibility and retains its documented exposure. Azure still needs the
   managed-identity startup service that materialises these files from Key Vault.
2. **RBAC and user-level attribution before any shared channel with a
   write-enabled key.** The prerequisite for treating Slack as more than a
   read-only surface. Until it exists, the read-only posture above is the control.
3. **Restore a fail-closed check over the ACTIVE Pretorin CLI.** `PRETORIN_SHA256`
   now covers the seed only (see the trust-root section above), so a deployment
   that has updated its CLI has no repo-side pin behind its bytes. Options worth
   evaluating: recording the expected digest in the audit record and asserting it
   on start, or having the updater verify the signed `SHA256SUMS` itself with a
   vendored anchor — which would mean adding cosign to the runtime image and
   maintaining a second verification path alongside the CLI's own.
4. **Trim agent tool execution, or sandbox it.** Tool execution is unsandboxed and
   the config sets no `tools.profile`, so `exec` is available to every agent turn.
   That predates this release, but the CLI moving into a writable volume widens
   what `exec` can reach: an agent can replace the active binary directly and
   rewrite the update audit file. The wrapper's audit therefore covers the
   supported routes only. `tools.exec.security: "allowlist"` with a host approvals
   file is the narrow fix; enabling the sandbox is the broad one. **Required
   before production** — the provenance workflow in `AGENTS.md` currently depends
   on `git`, so neither can simply be switched on without replacing that path.

   Target synchronization widens the same gap again, and in two specific ways
   worth naming rather than folding into the sentence above: the gateway now has
   a **writable** alias of the target directory, and a **mounted git credential**.
   Both are reachable by anything the agent can execute. The narrow fix is the
   same allowlist; the real fix is item 4b.

4b. **Move the synchronizer out of the agent's container.** Today the wrapper, the
   writable maintenance mount and the PAT all live in the gateway container as the
   same uid as unsandboxed tool execution, so the read-only assessment mount is a
   separation of purpose rather than of privilege. A sidecar with its own uid —
   holding the credential and the writable mount, reached over a socket that
   accepts only `all` or a declared target name — is what would make it a boundary.
   Deliberately out of scope for the internal pilot; **required before a customer
   deployment with private repositories.**

5. **Fail-closed runtime-pin validation.** The `models.providers.openai.
   agentRuntime` pin is currently observable only as a log line the smoke test
   greps. If it silently regressed, agent turns would route through the Codex
   app-server plugin, which does not receive `tools.toolSearch` and bypasses
   `toolFilter`. A startup assertion that refuses to serve on the wrong runtime
   would make this fail closed instead of fail quietly.
6. **The base image ships five fixable CRITICAL vulnerabilities.** Measured, not
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
7. **Image signing — Azure Key Vault, following the Pretorin CLI.** The release
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
8. **OpenClaw base-image attestation.** Phase 1's chain guarantees the *Pretorin
   binary* and Phase 5's gate guarantees the *Slack plugin*; the OpenClaw base
   image is trusted on its digest pin alone. Verifying upstream's own GHCR
   attestation would close the last unverified link in the image.
9. **RESOLVED — the release workflow can now be rehearsed.** It previously could
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
10. **Connected Sources (`source_admin`) as the eventual binding source.** Local
   `preflight` resolvers are a host-local approximation. Connected Sources is also
   the **only** path to `branch_protection`, `code_review_records` and
   `pull_request_records` — i.e. the thing that resolves `code_repository`
   reporting `degraded`, which is expected today and cannot be fixed from a local
   checkout. Requires a scope this POC deliberately does not use.
11. **Config reconciliation instead of warn-and-`down -v`.** Templates are seeded
   write-if-absent and never overwritten, so a newer image cannot tighten an
   existing deployment's config. Today the entrypoint warns — including a specific
   warning when Slack is configured in `.env` but absent from an existing
   config — and `down -v` is the only reset.
12. **`tools.toolSearch` is experimental upstream.** Its runtime behaviour is
   observed working (`cataloged 223 tools behind compact directory surface`) but
   upstream marks all Tool Search modes experimental. If it regresses, the prompt
   returns to roughly 40k tokens per turn and the commented `toolFilter` block is
   the lever.
13. **Per-repository authorization.** Every target shares one Pretorin key and one
   scope. A reviewer who should see one repository sees all of them.
14. **`mcp.sessionIdleTtlMs` is untuned.** Default 600000 ms — ten minutes of
   idleness before a session's `pretorin mcp-serve` child (a 23 MB binary) is
   reaped; `0` disables idle cleanup. Fine for one operator, unmeasured for a
   shared channel where each session spawns its own child.
15. **Multi-arch is blocked upstream.** `SHA256SUMS` publishes only
    `linux-x86_64` and `macos-arm64`, so there is no linux/arm64 Pretorin binary
    to build against. Not deferred by choice — blocked. Apple Silicon runs amd64
    under emulation.
16. **Upstream feedback: `pretorin preflight unbind --id <resolver-id>`.**
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
  ledger item 7 above — recorded as planned work, not quietly omitted.
