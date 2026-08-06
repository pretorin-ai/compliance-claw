# Phase 5 — shippable POC: Slack, private repos, a published image, and the docs

Goal: make the Phase 1–4 deployment shippable to someone who did not build it.
Reproducible Slack from a fresh volume, private repository targets, a published
image that operators pull by immutable digest instead of building, and the
documentation pass that ties the four previous phases together.

Every earlier convention stands: pins in `versions.env`, write-if-absent seeding,
never-clobber, the runtime pin and its drift alarm, `toolSearch` directory mode,
key scopes as the authorization boundary, sweep-then-bind onboarding, and `.env`
as the single **container** secret file.

**Status: IMPLEMENTED and RELEASED.** `v0.1.0` is published to GHCR and pinned by
digest, and 7 of the 8 completion criteria were verified against that pulled image
on a fresh clone. Criterion 6 (a live private-repository read) is
**blocked-on-operator**: creating a GitHub App on the organisation needs owner
permission this operator does not hold. It is recorded as blocked with the runbook
an owner needs, never as a pass.

Six bugs surfaced by running things rather than reading them, all recorded below
with what they were and how they were found. One of them was a wrong diagnosis of
mine that contaminated the first acceptance attempt; the run was redone from a
destroyed volume rather than reported with the contamination glossed over.

## Established facts, measured against the shipped 2026.7.1 image

Everything here was observed in a throwaway container or the live deployment, not
read from a newer doc.

| Fact | Evidence |
| --- | --- |
| Slack is **not bundled**: 70 stock plugins, `slack` not among them | `openclaw plugins list`, `ls /app/dist/extensions` |
| It is an official external npm package, `@openclaw/slack@2026.7.1` | resolved install; integrity `sha512-dwVG…H4XA==` |
| The published package ships its own `npm-shrinkwrap.json` (51 KB) | which is why 103 transitive deps land **nested** under the plugin, not hoisted |
| `openclaw plugins install` writes into the **state volume** (`~/.openclaw/npm/projects/…`) | so a managed install dies with `down -v` and cannot be pinned in an image |
| **`plugins.load.paths` loads the plugin from an image path** | `plugins inspect slack` → `Status: loaded`, `Origin: config`, `Capabilities: channel: slack` |
| Slack loads **without** `plugins.allow` | probe: 50/50 plugins enabled, slack among them |
| **`plugins.allow` is EXCLUSIVE** | `allow: ["slack"]` → 2/50 enabled (`slack`, `memory-core`) |
| Runtime banner became `(1 plugin: slack; 0.6s)` | live gateway log; Phase 3/4 saw `(8 plugins: …)` |
| Agent turns, MCP, skills and toolSearch all survive the trim | live log: `cataloged 223 tools behind compact directory surface`, `[agent/embedded]`, `chatgpt.com/backend-api/codex/responses status=200` |
| Slack tokens need **no config entry** — env fallback covers the default account | upstream token model; the live config contains no token field |
| `openclaw config patch --file` works offline and validates against the schema | `Dry run successful: 9 update(s) validated` → `Config valid` |
| `config patch --dry-run` **exits 1** on a schema violation | probe with a bad `enabled` type and an unknown channel key |
| Socket Mode is outbound-only | upstream: "Public Gateway URL: **Not required**"; live deployment connects with only `127.0.0.1:18789` published |
| Channel allowlist keys must be channel **IDs** | a name key silently never routes under `groupPolicy: "allowlist"` |
| Minimal manifest is **12** bot scopes; recommended is **23** | counted from the shipped `/app/docs/channels/slack.md` |
| The plugin cannot be `import()`ed standalone | it imports the host package `openclaw`; `Cannot find package 'openclaw'` even on a good install |

## The regression this phase found

`scripts/smoke.sh` line 128 read:

```sh
PLUGIN_LINE="$(printf '%s' "$LOGS" | grep -o '([0-9]* plugins:[^)]*)' | tail -1)"
```

Against the live banner `(1 plugin: slack; 0.6s)` that returns **rc=1** —
reproduced directly. Two independent causes: the banner says `plugin` (singular)
when one plugin activates, and it now carries a `; 0.6s` timing suffix. Phase 4
had already fixed the vacuous-pass class, so this failed loudly rather than lying,
but a check that can never pass is a dead check. Fixed to
`\([0-9]+ plugins?: [^)]*\)`, with the timing suffix stripped before the name set
is compared.

## Design 1 — Reproducible Slack

### Pinning: image-baked, loaded by path

`plugins install` writes into the state volume, so it satisfies neither "pinned in
the image" nor "survives `down -v`". Instead a new `slack-plugin` Dockerfile stage
runs `npm install @openclaw/slack@${SLACK_PLUGIN_VERSION}` and **fails the build**
unless the resolved `package-lock.json` integrity equals `SLACK_PLUGIN_INTEGRITY`
— the same "never trust the resolution, compare against a pin" rule as
`PRETORIN_SHA256`. The runtime stage copies the package directory (self-contained,
because the shipped shrinkwrap nests the tree) to
`/opt/compliance-claw/plugins/slack`, node-owned, and the config points
`plugins.load.paths` at it.

The planned build-time `import()` assertion was **replaced**: the plugin imports
the host package `openclaw`, so a bare node import always fails. The build now
asserts the manifest id, the entry point, and that `@slack/bolt` and
`@slack/socket-mode` resolve from the plugin directory. Proof that OpenClaw
actually loads it lives in `smoke.sh`, which asserts `Status: loaded`.

### Config: base template untouched, Slack applied as a validated patch

```
      ┌─ config ABSENT (fresh seed) ─────────────────────────────────────────┐
      │  seed base template (byte-identical to Phase 4)                      │
      │  all three vars set? ─ yes ─► validate ^C[A-Z0-9]{6,}$   (gate 1)    │
      │       │                       substitute into a TEMP copy            │
      │       │                       config patch --dry-run      (gate 2)   │
      │       │                       config patch                (apply)    │
      │       │                       assert the marker landed     (gate 3)  │
      │       ├─ some ─► warn, name the MISSING vars, do not patch           │
      │       └─ none ─► silent                                              │
      └──────────────────────────────────────────────────────────────────────┘
      ┌─ config PRESENT (never-clobber) ────────────────────────────────────┐
      │  template-version drift warning (unchanged)                          │
      │  NEW: 3 vars set AND no channels.slack ─► Slack-specific warning     │
      │       naming both fixes. Warn only; nothing is edited.               │
      └──────────────────────────────────────────────────────────────────────┘
```

Two things made this shape necessary. The channel allowlist entry is a config
**key**, and OpenClaw's `${VAR}` substitution only works on **values** — so the
channel id must be interpolated before the file is applied, which is why it gets
a character check *and* a schema dry-run rather than trust. And Slack is optional:
a config naming `channels.slack` with no tokens retries a websocket forever, so
the base template must stay Slack-free.

The present-config branch is the critical gap the engineering review found. Without
it, every Phase 3/4 operator who adds Slack tokens gets silence, because the
existing drift warning talks about template versions and never mentions Slack.

**No Slack token reaches disk.** The shipped block names neither `botToken` nor
`appToken`; OpenClaw reads both from the environment. That is stronger than the
`PRETORIN_API_KEY` arrangement, which at least leaves a `${VAR}` marker.

### The trim, and the two-profile drift alarm

`plugins.allow` is exclusive, so trust-pinning `slack` also removes `browser`,
`canvas`, `device-pair`, `file-transfer`, `ollama`, `phone-control` and
`talk-voice`. Adopted deliberately — it shrinks what unsandboxed tool execution can
reach — with the escape hatch documented in the patch file itself, including the
warning that removing `channels.slack` without removing `allow` leaves an orphaned
allowlist that trims the bundled set for nothing. `smoke.sh` asserts the two move
together.

| Slack | Expected banner | `codex` |
| --- | --- | --- |
| configured | `(1 plugin: slack; …)` | absent |
| not configured | `(8 plugins: browser, canvas, device-pair, file-transfer, memory-core, ollama, phone-control, talk-voice)` | absent |

The `agentRuntime` pin keeps an independent signal through `[agent/embedded]` in
the log, because the allowlist would now mask `codex` on its own.

### Manifest

`slack/app-manifest.json` — upstream's minimal socket-mode set, 12 bot scopes,
renamed to Compliance Claw. Committed as JSON so it is a byte-faithful copy of the
supported manifest rather than a hand-translation. `im:*` stays because it is part
of the supported minimal set while DMs are closed one layer up by
`dmPolicy: "disabled"`; granted-but-unused is stated in SECURITY.md rather than
hidden.

Reusing an existing Slack app is fully supported and needs no manifest at all —
any app with Socket Mode, `connections:write` on its app-level token, and a bot
token works. The manifest earns its place on a *new* app, where it removes the
hand-picking of scopes and the over-granting that follows. **It was not imported
during this phase**; see the completion-criteria notes.

## Design 2 — Private repositories via a read-only GitHub App

### The credential is host-only, and that is a deliberate carve-out

`.env` is handed to the container wholesale by `env_file`. A private key there
would be a git credential **inside** the container by construction, which is
exactly what the requirement forbids. So `.env` names the key's *path*; the key
lives outside it, and both `secrets/` and `*.pem` are gitignored. The
single-secret-file convention governs container secrets; this one is host-only and
documented as a carve-out the same way the `FROM`-digest pins are.

### Flow

```
1. JWT   RS256 over {iat: now-60, exp: now+480, iss: APP_ID}, openssl-signed
2. GET   /app/installations         resolve, or use GITHUB_APP_INSTALLATION_ID
3. POST  /app/installations/<id>/access_tokens
         { permissions: {contents: read, metadata: read}, repositories: [...] }
4. on refusal ONLY: mint a broad token, diff /installation/repositories,
   and name the missing repository plus its installation URL
5. write the token to a 0600 file — never stdout, never argv
```

`exp` is `now+480`, not `now+540`: with `iat` backdated 60s for clock skew the
latter would make `exp - iat` exactly 600, sitting precisely on GitHub's limit.
Verified end to end with a throwaway key — 3 segments, correct header,
`exp-iat = 540`, base64url clean, and `openssl dgst -verify` → `Verified OK`.

The repository pre-check runs only on the error path, so the happy path mints
exactly one down-scoped token and nothing broader.

### Cloning without persisting a credential

```sh
git -c credential.helper='!f() { ... cat "$TOKEN_FILE" ...; }; f' clone <clean-url>
```

Three properties, each chosen against a specific alternative: the token is not in
the URL (so `git clone` cannot write it into `.git/config`), not in `argv` (so it
is not in `ps` for other users), and `git -c` sits **before** the subcommand, which
makes it a one-shot override — `git clone -c` would persist it into the new
repository. Every private clone and fetch is then checked for
`x-access-token|ghs_|github_pat_` in its `.git/config`, and `smoke.sh` re-checks
every clone independently.

`origin` stays the clean URL, so Phase 4's origin-mismatch refusal keeps working.

### `targets.yaml` stays declarative

`private: true` is a flag; no token, no path, no secret. The parser accepts only
the exact strings `true`/`false` — `yes`, `True` and `1` are rejected, because a
value that quietly parses as "not true" turns a private repo into a public one and
produces an auth error that reads like a network fault. A private target must be
on `github.com`, since that is where the App token works.

## Design 3 — build, scan, SBOM, publish by immutable digest, pull it back

### No signing. The digest is the guarantee, and it is verified rather than asserted

Signing was designed in — keyless cosign, a second pinned cosign, `id-token:
write` — and then deliberately removed. Keyless signing writes a permanent,
publicly searchable Sigstore transparency-log entry naming the repository, and
this repository is internal; that is a disclosure decision, not only a technical
one. The alternative, a signing key held in CI, contradicts the standing rule that
CI holds zero credentials.

What stands in its place is a content address, plus a proof that it round-trips:

| | Guarantees | Does **not** guarantee |
| --- | --- | --- |
| `@sha256:...` | **Integrity** — these exact bytes, the ones that were scanned | **Authenticity** — nothing attests who built them |

The release job deletes the built image locally so the pull cannot be served from
cache, pulls the published digest back from the registry, runs it, and regenerates
the SBOM from the pulled bytes to compare package counts against the SBOM taken
from the build. A digest nobody pulls back is an assertion; this makes it a
measurement.

Two things were removed rather than left lying around, because both would have
implied a guarantee that no longer exists: `id-token: write`, which exists solely
to mint OIDC tokens for keyless signing, and the second cosign pin — a pin no job
consumes advertises a verification that does not happen.
`COSIGN_VERSION=v2.4.1` stays, because the Dockerfile still uses it to verify the
Pretorin release blob, which is a different job with a different constraint.

The integrity-versus-authenticity distinction is stated in `README.md`,
`SECURITY.md`, `compose.yaml` and the job summary, rather than left for a reader
to infer from the absence of a `cosign verify` command. Signing is a
hardening-ledger item.

### Pipeline

```
1. assert release.yml references no secret but GITHUB_TOKEN   (self-check)
2. assert the git tag equals v${IMAGE_VERSION} from versions.env
3. install trivy / syft, each checksum-verified against versions.env
4. docker build --platform linux/amd64
5. in-image smoke: pretorin, openclaw, arch, Slack plugin present
6. print the .trivyignore.yaml exceptions and their remaining lifetime
7. trivy: FAIL on fixable CRITICAL; a second non-blocking run reports HIGH
8. syft SPDX SBOM, refused if it contains zero packages
9. push, then read the digest from RepoDigests
10. rmi, PULL THE DIGEST BACK, run it, re-generate the SBOM, compare
11. job summary prints the digest, the compose pin line, and the exceptions
```

Scanning precedes the push, so a failing image is never published.
`--ignore-unfixed` on the blocking scan is deliberate: an unfixable base-image CVE
would otherwise make every release unshippable, and an unsatisfiable gate gets
disabled. Unfixed criticals are printed rather than dropped.

### Compose pulls; the digest pin is a follow-up commit

`docker compose up` builds whenever a `build:` section exists and the image is
missing locally, so `compose.yaml` has **no** `build:` section at all —
`compose.build.yaml` is the documented dev overlay, selected through docker
compose's own `COMPOSE_FILE`, which every other script inherits with no code
change. A local build is tagged `compliance-claw:local` so it cannot be mistaken
for the released image.

The tag is mutable and the digest is the artifact, so `compose.yaml` carries the
pin instruction and the release job prints the digest. That pin lands as a second,
one-line commit after publishing — the one deliberate exception to the one-commit
rule, recorded here so it is not forgotten.

## Changes

| File | Change |
| --- | --- |
| `versions.env` | `SLACK_PLUGIN_VERSION` + `SLACK_PLUGIN_INTEGRITY`, `IMAGE_REPO` + `IMAGE_VERSION`, `COSIGN_CI_*`, `TRIVY_*`, `SYFT_*`; `CONFIG_TEMPLATE_VERSION` 2→3; the carve-out note now names three places |
| `Dockerfile` | `slack-plugin` stage with the integrity gate and structural assertions; runtime copies the plugin and the Slack patch |
| `scripts/slack-channel.patch.json5` | New. The Slack config fragment, `@SLACK_CHANNEL_ID@`, and the escape-hatch block |
| `scripts/entrypoint.sh` | Fresh-seed Slack patch behind three gates; all-or-nothing on the three variables; the Slack-specific warning for an existing config |
| `scripts/openclaw-config.template.json` | Comment only — points at the Slack fragment and warns that it sets an exclusive allowlist |
| `slack/app-manifest.json` | New. Minimal socket-mode manifest with setup steps in its header |
| `scripts/github-app-token.sh` | New. Host-only JWT → installation → down-scoped token → 0600 file, with a repository pre-check on the error path |
| `scripts/bootstrap.sh` | `.env` moved before targets; private clone path; credential assertion; `--build`; pull by default; build-overlay auto-detect |
| `scripts/parse-targets.py` | `private` key with strict boolean validation and a github.com restriction; 4th TSV column; 29 → 36 self-test cases |
| `scripts/smoke.sh` | Drift-alarm regression fix + two-profile assertion; A4b image/version agreement; A4c extended secret canary; A11 private negatives; A12 Slack fresh-seed section |
| `scripts/agents-md.template` | One line: do not switch system/framework in chat |
| `targets.yaml` | `crm-deploy` as the private example, **commented out** — see the CI failure below |
| `compose.yaml` | GHCR image, `build:` removed, digest-pin instruction |
| `compose.build.yaml` | New dev overlay |
| `.env.example` | Slack and GitHub App blocks; the shared-channel warning |
| `.gitignore` | `secrets/`, `*.pem` |
| `.github/workflows/release.yml` | New. Tag-triggered publish, scan, SBOM, keyless signature |
| `.github/workflows/build.yml` | Build overlay via `COMPOSE_FILE`; credential guard widened to four variables and a PEM check; checkout pinned by SHA |
| `README.md`, `SECURITY.md` | Full documentation pass |

`onboard-targets.sh` needed no behavioural change: by the time it runs, a private
target is an ordinary directory.

## Validation — observed results

`scripts/smoke.sh` against a locally built image
(`COMPOSE_FILE=compose.yaml:compose.build.yaml`, because the pull path needs a
published image that does not exist yet), after `docker compose down -v` so every
seeding path ran fresh: **113 pass, 0 fail, 2 skip.**

The run used a **public-only target set**. `crm-deploy` is declared `private: true`
in the committed `targets.yaml`, and cloning it needs a GitHub App that is not
provisioned yet, so the private path is exercised through its refusals (A11) and
its parser contract rather than a real private clone. That is recorded as
blocked-on-operator below, not as a pass.

### Section A — no credentials (what CI runs)

| Group | Result | Observed |
| --- | --- | --- |
| A1 versions | pass | `pretorin 0.26.14`, `OpenClaw 2026.7.1`, image `x86_64` |
| A2 MCP surface | pass | `mcp-smoke-test` → `PASSED` |
| A3 parser | pass | `all 37 cases pass` (was 29) |
| A4 gateway + seeding | pass | container `running/healthy`, then `/healthz` on the published port; config, `AGENTS.md` and marker seeded at v3 |
| **A4 drift alarm** | **pass** | fixed grep matches; no-Slack profile asserts all 8 bundled plugins by name; `codex` absent |
| A4 allowlist coupling | pass | `plugins.allow and channels.slack are both-or-neither (allow=0 slack=0)` |
| **A4b image/version** | **pass** | `compose.yaml` matches `versions.env`; `compose.yaml` has **no** build section; the overlay restores it |
| **A4c secret containment** | **pass** | no Slack token value or `${…}` marker in the config; 0 canary hits across both state volumes; no `.env`, no PEM, no `secrets/` in the image; no PEM visible in a running container; 0 canary hits in the logs |
| A5 mount posture | pass | targets `ro`, both state volumes writable, uid `node` |
| A6 the CWD fix | pass | `CHILD_CWD=/opt/compliance-claw/no-repo`, never `/app` |
| A7 stale-template | pass | older / corrupt / missing marker each warn; config md5 unchanged throughout |
| A8 onboarding, no key | pass | `/app` swept; target bound; non-path resolver survived; re-run idempotent |
| A9 bootstrap refusals | pass | origin mismatch and broken clone both refused, neither deleted |
| A10 bootstrap idempotency | pass | `.env` byte-identical, mode 600, fetch instead of clone |
| **A11 private refusals** | **pass** | no App → refusal naming `GITHUB_APP_ID`; missing key → refusal naming the path; **no clone attempted**; parser rejects a non-github private target and a non-boolean `private`; no clone carries a credential in `.git/config` |
| **A12 Slack fresh seed** | **pass (18/18)** | see below |

A12 in full, because it is the phase's headline claim:

```
PASS  fresh volume + 3 vars -> Slack is in the config
PASS    and the patch reports success
PASS    and no token value reached the config
PASS    and the plugin loads from the image path
PASS  channel NAME instead of ID is refused
PASS    and Slack is left unconfigured
PASS    and the container still works
PASS  a channel id carrying JSON is refused before substitution
PASS    and Slack is left unconfigured
PASS  2-of-3 Slack vars warns instead of half-configuring
PASS    and names what is missing
PASS    and Slack is left unconfigured
PASS  no Slack vars is silent (no warning)
PASS    and the config is the Phase 4 baseline
PASS  existing config + Slack env warns specifically
PASS    the warning offers the down -v reset
PASS    the warning offers the by-hand patch
PASS    and never-clobber still holds (config untouched)
```

The seeded config, read off a throwaway container with canary tokens in the
environment:

```json
"plugins": { "allow": ["slack"], "entries": { "slack": { "enabled": true } },
             "load": { "paths": ["/opt/compliance-claw/plugins/slack"] } },
"channels": { "slack": { "enabled": true, "mode": "socket",
              "dmPolicy": "disabled", "configWrites": false,
              "groupPolicy": "allowlist",
              "channels": { "C0BNXD05X6U": { "requireMention": true } } } }
```

`grep -c CANARY` on that file returns **0**, and `openclaw plugins inspect slack`
reports `Status: loaded`, `Source: /opt/compliance-claw/plugins/slack/dist/index.js`,
`Origin: config`, `Version: 2026.7.1`.

### Section B — credentialed

| Check | Result | Observed |
| --- | --- | --- |
| B1 onboarding completes | pass | `Seeded platform recommendations`; `active context set and valid` |
| B2 state is exactly targets.yaml | pass | resolver connected; no resolver outside the mount; `degraded` reported as expected |
| B3 read tool through MCP | pass | `list_frameworks` returned |
| B4 write tool rejected | **skip** | `PRETORIN_KEY_MODE` absent → fail-safe skip. See the incident below |
| B5 mount posture with credentials | pass | targets still `ro` |
| B6 agent turn provenance | **skip** | no model credentials in the volume |

### A sixth bug: the release gate would have blocked the first release

`release.yml` cannot be rehearsed — GitHub only offers `workflow_dispatch` for
workflows on the **default branch**, and this one lives on the feature branch, so
its first execution is the first tag push. That made rehearsing its stages by hand
worth the effort, and running the Trivy gate locally against the built image found
this:

```
CVE-2026-33845       libgnutls30      3.7.9-2+deb12u6 -> 3.7.9-2+deb12u7
CVE-2026-42010       libgnutls30      3.7.9-2+deb12u6 -> 3.7.9-2+deb12u7
GHSA-p63j-vcc4-9vmv  @vitest/browser  4.1.9 -> 4.1.10        app/node_modules/...
CVE-2026-59873       tar              7.5.13 -> 7.5.19       npm/node_modules/...
CVE-2026-59873       tar              7.5.15 -> 7.5.19       corepack/pnpm/...
TOTAL BLOCKING: 5
```

Five fixable CRITICALs, **every one of them in the OpenClaw base image**. Verified
that nothing this repository adds contributes any: scanning by path, the Pretorin
binary and the Slack plugin tree produce zero CRITICALs, and the plugin's single
HIGH (`axios 1.16.0`) is the exact version OpenClaw's own managed installer pins
through its `overrides` block.

That check answered a second question worth recording. The Dockerfile stage runs a
bare `npm install`, which does **not** apply the 28 `overrides` OpenClaw's managed
installer uses. Comparing the two trees package by package, every override-affected
package present resolves identically — `axios 1.16.0`, `follow-redirects 1.16.0`,
`form-data 2.5.6`, `path-to-regexp 8.4.0`, `qs 6.15.2`, `typebox 1.3.3` — because
the published `npm-shrinkwrap.json` already pins them. Skipping the overrides costs
nothing, which is now a measurement rather than an assumption.

The gate itself was the defect. Its own comment said an unsatisfiable gate is one
people disable, and then it shipped unsatisfiable, because `--ignore-unfixed` does
nothing about CVEs that *are* fixed upstream but not in the base image we pin.

The fix is not a weaker gate. `.trivyignore.yaml` carries one entry per
vulnerability id — never a package wildcard, never a severity-wide exclusion — each
with a written justification and a **90-day `expired_at`**. A new fixable CRITICAL
still blocks the release; these come back for review on 2026-11-04 rather than
being forgiven permanently. The release job prints every exception and its
remaining lifetime into the job summary before the gate runs, so nobody approving a
release has to open the file to know what is being shipped past it.

The honest part of that file is the `libgnutls30` pair: unlike the others it sits
on a live TLS path, and it is deferred because it cannot be patched without an
unpinned `apt upgrade` over a digest-pinned base — not because it is unreachable.
Bumping `OPENCLAW_VERSION` and the runtime `FROM` digest is the real fix for all
five, and is tracked in SECURITY.md.

One self-inflicted detail, since it cost two runs: `paths:` in a Trivy ignore entry
matches a finding's `PkgPath`, and Debian package findings have none. Adding a
`paths:` filter to the two OS entries made them match nothing and the gate kept
failing.

### Release tooling, verified offline

The tag gate, the pin extraction and the checksum-pinned downloads were exercised
on the host rather than assumed:

```
tag v0.1.0 -> ACCEPT      tag v0.2.0 -> REJECT      tag 0.1.0 -> REJECT
trivy_0.73.0_Linux-64bit.tar.gz        : OK
syft_1.50.0_linux_amd64.tar.gz         : OK
```

`release.yml` and `build.yml` both parse, every `uses:` is pinned to a 40-character
commit SHA, and the workflow's own credential self-check passes — `secrets.` appears
exactly twice and both are `secrets.GITHUB_TOKEN`.

### Bugs the gate found, all in shipped code

Worth recording because none were found by reading, and two fail toward *less*
safety.

1. **`bootstrap.sh` exited 1 on every successful run with no private targets.**
   The EXIT trap ended on `[ -n "$GH_TOKEN_FILE" ]`, and a trap's exit status
   becomes the script's. Same family as Phase 4's "fallback chain keyed off exit
   status", one layer up. Fixed with an explicit `return 0`.

2. **A private target was cloned ANONYMOUSLY, skipping the GitHub App entirely.**
   The TSV was `name/url/ref/private`, and **tab is an IFS *whitespace*
   character**, so `name⇥url⇥⇥true` collapses to three fields: `true` landed in
   `ref` and `private` came back empty. A private repository was therefore treated
   as public, failing later with an authentication error that reads like a network
   fault. Fixed by reordering to `name/url/private/ref` so only the optional field
   is ever last, with the rule stated in the parser docstring.

   The test that should have caught it **passed for the wrong reason** — the clone
   failed because the probe URL did not exist, not because the App check fired.
   That is the Phase 1 lesson recurring: a gate no test truly drives is not a gate.
   The self-test now pipes the exact shape through real bash, because no
   pure-Python assertion can catch a shell word-splitting bug:

   ```
   PASS  bash reads private correctly when ref is absent
   ```

3. **The undeclared-key default was inverted, and it created a real record.**
   `smoke.sh` treated a missing `PRETORIN_KEY_MODE` as `read-only` and then ran the
   write probe. The operator's `.env` predates that variable — and never-clobber
   means an existing `.env` never gains it — while the key in it is actually
   write-enabled. `create_risk` succeeded and created a live risk on the platform
   (`compliance-claw smoke probe - read-only key must be rejected`, system
   `7b74d8f3…`, framework `soc2`), which had to be deleted by hand. Absence of a
   declaration now skips the probe and says so; only an explicit
   `PRETORIN_KEY_MODE=read-only` authorizes it.

Two test-side bugs were fixed alongside them: the Slack section overrode
`--entrypoint`, which skips the very seeding it was testing, and the
"no token substitution" check matched the template's own explanatory comment
rather than a real `${SLACK_BOT_TOKEN}` reference.

### The fourth bug, found by CI in 21 seconds

The local gate ran against a public-only target set, so it never exercised the
committed `targets.yaml`. CI did, and failed immediately:

```
bootstrap: 1 private target(s): pretorin-ai/crm-deploy
github-app: ERROR — GITHUB_APP_ID is not set.
bootstrap: ERROR — could not mint a GitHub App token for the private target(s).
```

Every individual behaviour here is correct — the refusal is exactly what a private
target with no App should produce. The defect is the **default**: shipping
`crm-deploy` enabled put a credential requirement into the committed file, and two
readers can never satisfy it. CI holds zero credentials by design, and a fresh
clone is supposed to reach a running deployment "with one script and one key"
(Phase 4's acceptance property). The private example now ships commented out.

The general shape is worth keeping: a correct refusal in the wrong default is
still a broken first run, and a local gate that substitutes its own fixture for
the committed configuration cannot see it. `build.yml` now asserts the committed
`targets.yaml` parses with no `private: true` target, so this cannot regress
silently:

```yaml
- name: Assert the committed targets.yaml needs no credentials
```

### A fifth bug, found by the fresh-clone rehearsal of that fix

Re-running the CI path in an isolated `COMPOSE_PROJECT_NAME` surfaced a check that
lied, in the same family as the two Phase 4 recorded:

```sh
docker compose up -d >/dev/null 2>&1          # error discarded
curl -fsS http://127.0.0.1:18789/healthz      # answered by SOMEONE
```

The isolated project could not start at all — `Bind for 127.0.0.1:18789 failed:
port is already allocated`, because another compose project already held the
published port. `up -d` swallowed that, and the readiness probe was then answered
by the **neighbouring deployment's** gateway. `gateway answers /healthz` passed
while this project had **zero containers**, and every gateway-dependent check
after it was measuring something else.

Two fixes, both about attributing a signal to the thing that produced it:

- `up -d` output is captured and a failure is reported with the daemon's own
  message, rather than discarded.
- Readiness is asserted on **this project's container** —
  `docker compose ps` reporting `running/healthy`, which is Docker's own
  healthcheck already probing `127.0.0.1:18789/healthz` from inside the
  container. The published-port check still runs, but only after that, and it
  **skips** rather than passes when our container is absent, since a reply from
  another deployment would mean nothing.

This never affects CI, which runs one project on a clean runner. It affected the
verification, which is worse: it is the tooling that is supposed to catch
problems quietly reporting success.

### The dead check that finally ran, and the documented command that never worked

`smoke.sh` B6 asserts that an agent turn carries provenance. It had reported `skip`
on every run since Phase 4 — no model credentials — so nobody noticed that the way
it invoked the agent could not have worked either:

```sh
TURN="$(cli openclaw agent --agent main -m "...")"     # cli = docker compose run --rm cli
```

`openclaw agent` reaches the gateway over `127.0.0.1:18789`. The `cli` service is a
**separate container** with nothing on its own loopback, so the command silently
falls back to the embedded agent. Embedded model resolution is stricter and dies:

```
FailoverError: Unknown model: openai/gpt-5.6-sol. Found agents.defaults.models[...],
but no matching models.providers["openai"].models[] entry.
```

Two things worth knowing about that error. `agents.defaults.models` is written into
the config by **OpenClaw itself** — it is not in our template — and it is what makes
the embedded path demand a provider `models[]` entry. And setting
`OPENCLAW_GATEWAY_URL=ws://openclaw:18789` does **not** help: the URL is accepted
(`Source: env OPENCLAW_GATEWAY_URL`) but resolution happens before dispatch.

The same wrong command was in **README.md** as the documented way to drive the
agent. Both are fixed to `docker compose exec openclaw openclaw agent ...`, which
works because inside the gateway container the gateway *is* on localhost:

```
$ docker compose exec -T openclaw openclaw agent --agent main -m "Reply with exactly: OK"
OK
```

B6 then passed for the first time in its existence. The prompt contains neither the
SHA nor the URL; the turn returned the repository URL, `276b5fd8716636…` matching
the host-read HEAD, and a repository-relative path:

```
- Repository URL: https://github.com/pretorin-ai/simple-crm.git
- HEAD commit SHA: 276b5fd871663605138fce5486831a422368b130
- File read: .dockerignore
```

Fixing the invocation then exposed a second flaw in the same check, one that had
been latent for the same reason. Its path assertion was:

```sh
for f in README.md docker-compose.yml dev.env; do   # "did the agent guess one of these?"
```

That asks whether the agent happened to pick one of three filenames, not whether it
reported a repository-relative path. It failed a completely correct answer of
`backend/app/auth.py`. The assertion now resolves whatever path-shaped token the
reply contains against the checkout on disk — so a real path passes regardless of
which file the agent chose, a fabricated one cannot, and an absolute
`/workspace/targets/...` path is rejected as not repository-relative and separately
noted, since AGENTS.md asks for the relative form and evidence carrying a container
path is not reviewable by anyone who did not run this container.

Both flaws were invisible for the same reason: the check had never executed.

Everything else — `pretorin ...`, `openclaw mcp ...`, `openclaw config ...` — is
correct under `run --rm cli`, because none of it needs the gateway. Only agent turns
do. This is the third dead check this phase found, after the plugin-banner grep and
the `/healthz` cross-project pass, and all three shared a shape: a check that could
never pass, kept invisible by a skip or a coincidence.

### The config I patched for no reason

Recorded because the acceptance run had to be redone because of it.

When the CLI probe above failed with `Unknown model`, the conclusion drawn was that
the shipped config template was broken — that it set `agents.defaults.model` without
registering the model under `models.providers.openai.models[]`. Two
`openclaw config patch` calls then added this to the **running deployment**:

```json
"models": [{ "id": "gpt-5.6-sol", "name": "gpt-5.6-sol", "api": "openai-chatgpt-responses" }]
```

That diagnosis was wrong, in two ways that a single check would have caught. The
gateway had been serving Slack turns with `status=200` **before** the first patch —
the deployment was working the whole time. And the template needs no such entry:
after destroying the volume and re-seeding from the image alone, Slack turns return
`status=200` with `models[] present: False`.

A second wrong conclusion followed the first. When the patched config produced
`401 Missing scopes: api.responses.write`, that was reported as the operator's
OpenAI account lacking a permission. It was a transient cooldown from the earlier
failed attempts (`cooldown until 07:48:30` on the profile); the same account was
returning 200s minutes later.

The cost was evidential, not functional: nothing broke, no volume was lost, and the
added block was inert for the gateway path. But criterion 8 is "zero manual
container modification", and that had been violated, so the run could not be
recorded. The volumes were destroyed and every criterion above was re-observed on a
config seeded only by the image.

The lesson is narrow and worth keeping: **check whether the system works before
concluding it is broken.** The probe was new; the deployment was not.

### Operator prerequisite destroyed during validation

Running `docker compose down -v` to force a fresh seed deleted the OpenClaw state
volume of the **live** deployment, including the ChatGPT device-code login at
`~/.openclaw/agents/main/agent/openclaw-agent.sqlite`. That is why B6 skips. It
should have been isolated with `COMPOSE_PROJECT_NAME`. Recovery, which needs a
TTY:

```sh
docker compose run --rm cli openclaw models auth login
```

The hand-configured Slack block in that volume went with it; it is superseded by
the reproducible path this phase adds.

## Completion criteria — the release run

Run against the **published image pulled by digest**
(`ghcr.io/pretorin-ai/compliance-claw:0.1.0@sha256:58690e31…d188da8b`), from a
fresh clone of `feat/poc` in a clean directory, with an isolated
`COMPOSE_PROJECT_NAME`.

The volume was destroyed and re-seeded before the criteria below were recorded,
because an earlier attempt had been hand-patched — see "The config I patched for no
reason". Everything here is from the untouched re-run.

| # | Criterion | Status | Observed |
| --- | --- | --- | --- |
| 1 | Fresh clone, clean directory | **pass** | clone at `0852759`; no `.env`, no `workspace/` |
| 2 | Configure secrets from `.env.example` | **pass** | 6 variables set; `PRETORIN_KEY_MODE=write` declared for the write half |
| 3 | Pull the released GHCR image | **pass** | `docker compose pull` resolved the pinned digest; `compose.yaml` has no `build:` section, so a local build cannot substitute. CI additionally deleted the built image and re-pulled the digest, matching the SBOM at 1099 packages both ways |
| 4 | `docker compose up -d` | **pass** | `running/healthy` |
| 5a | Slack connects automatically | **pass** | `channels resolved: C0BNXD05X6U→compliance-claw-test`, then `socket mode connected` — on a volume where `models[] present: False`, i.e. seeded entirely by the image with **zero manual JSON** |
| 5b | Message the agent from Slack, get a reply | **pass** | `Inbound app_mention … user:U0B35SD3PT2 -> bot:U0BN3549K5G`, followed by `model-fetch … status=200`; operator confirmed the replies in-channel |
| 6 | Claw reads a selected PRIVATE repo | **BLOCKED-ON-OPERATOR** | Creating a GitHub App on the org needs owner permission this operator does not have. See below |
| 7 | Read workflows on the key; write workflow via the recipe, four provenance fields | **pass** | see the evidence record below |
| 8 | Zero manual container modification | **pass** | in the recorded re-run, every state change came from `bootstrap.sh`, `onboard-targets.sh`, the entrypoint, or an agent turn. The operator's device-code model login is a documented operator command, not a container modification |

### Criterion 7 in full — the signed attestation, not the agent's summary

The agent was asked to use the `code-evidence-capture` recipe against `simple-crm`
and to report what it submitted. What makes this a pass is not that report but the
**signed DSSE attestation** read back from the platform
(`get_evidence_attestation`), whose payload carries all four fields:

```
uri      https://github.com/pretorin-ai/simple-crm/blob/276b5fd871663605138fce5486831a422368b130/backend/app/auth.py
version  276b5fd871663605138fce5486831a422368b130
label    backend/app/auth.py password hashing and verification
locator  lines 42-51
```

| Required field | Where it appears |
| --- | --- |
| repository URL | in `uri`, as a permalink pinned to the commit |
| commit SHA | `version`, and again inside `uri` |
| repo-relative path | `backend/app/auth.py` — **not** the `/workspace/targets/...` container path |
| line range | `locator: "lines 42-51"` |

Two independent reasons this is not self-reported:

- `producer` records `{kind: "recipe", id: "code-evidence-capture", version: "0.1.0"}`
  with a `recipe_context_id` and `capture.method: "repository_file_read"`. The
  evidence went **through the recipe workflow**, not through a bare
  `create_evidence` call.
- The attestation's `excerpt` matches, byte for byte, what `sed -n '42,51p'` returns
  from the checked-out file on the host — the bcrypt `verify_password` /
  `get_password_hash` pair. The agent could not have fabricated the citation.

Evidence id `ad893583-2af0-4b0d-ab54-cdd6148cf8e5`, attestation
`089881cc-0b85-47c4-a42a-73ccfd0d9622`, signed `ECDSA_P256_SHA256` via Azure Key
Vault. The read half of the criterion is covered by B1–B3 and by the provenance
turn recorded under "The dead check that finally ran".

Note that `search_evidence` returns a summary projection **without** the `code_*`
fields. Reading the attestation is what proves provenance; the summary view alone
would have looked like the fields were missing.

### Criterion 6 — BLOCKED-ON-OPERATOR, and what that does and does not mean

**Why.** Creating a GitHub App on the `pretorin-ai` organisation requires
**organisation owner** permission. The operator running this phase is a member,
not an owner, so no App exists and no private repository can be cloned. This is an
access-control fact about the organisation, not a defect in the implementation and
not a decision to descope.

**What is shipped and unaffected.** The whole private path is implemented and in
the tree: `scripts/github-app-token.sh`, the `private` key in the parser, the
private clone path in `bootstrap.sh` with its non-persisting credential helper,
and the post-clone credential assertion. Nothing about it is stubbed.

**What is verified without an App**, all in Section A11 and the parser self-test:

- a private target with no App configured → refusal naming `GITHUB_APP_ID`,
  **no clone attempted**, and no hang on a credential prompt
- a missing key file → refusal naming the path
- `private: true` on a non-github host → rejected by the parser
- a non-boolean `private` (`yes`, `True`, `1`) → rejected
- no clone under `workspace/targets/` carries a credential in `.git/config`
- the RS256 JWT construction, proven end to end against a throwaway key
  (`Verified OK`, `exp-iat = 540`, base64url clean)

**What is NOT verified**, and will not be until an owner acts: a live
authenticated clone, and therefore the agent reading a private repository with
provenance. No amount of local testing substitutes for that.

**The deliverable for this criterion is therefore documentation**, and it is
written to be executed by an org owner who was not part of this work:
`README.md` → *Private repositories* is an eight-step runbook — App creation with
`Contents: Read-only` and the webhook disabled, installation on selected
repositories only, App ID and `.pem` handover, key placement and mode, `.env`
wiring, uncommenting the target, `bootstrap.sh` + `onboard-targets.sh`, and three
commands to verify the clone carries no credential. It ends with a table mapping
every refusal message the tooling can emit to its cause.

`crm-deploy` stays commented out in `targets.yaml`, so the committed default still
clones with no credentials at all.

### Slack — the existing app is reused, and the manifest is not exercised

The acceptance run uses the Slack app that already exists in this workspace, whose
app-level token, bot token and channel id are already in `.env` (all three
confirmed to reach the container, including the final unterminated line, which
compose's `env_file` parser handles correctly).

Two honest consequences:

- **Criterion 5 is still fully verified.** What it asserts is that a *fresh volume*
  auto-configures Slack with zero manual JSON or plugin editing. That property
  depends on the entrypoint, the pinned plugin and the patch — not on which Slack
  app the tokens belong to. A12 already proves it in throwaway containers, and the
  release run repeats it against the pulled image.
- **`slack/app-manifest.json` ships documented but NOT imported.** No Slack app in
  this run was created from it, so its import path is unverified: an error in the
  manifest — a malformed scope, a field Slack rejects on import — would not have
  been caught here. It is a faithful copy of upstream's minimal socket-mode
  manifest with the display name and slash command changed, and it parses as JSON
  with 12 bot scopes and no `request_url`, but that is a review, not a test.
  **Flagged for verification the next time an app is created from it.**

## Accepted limitations

- **The Slack app manifest grants `im:*` while DMs are disabled in config.** The
  scopes are part of upstream's supported minimal set; closing DMs one layer up is
  the control. Removing them is untested against the plugin.
- **`plugins.allow` and `channels.slack` must move together.** Documented in the
  patch file and asserted by `smoke.sh`, but nothing prevents an operator editing
  one and not the other in a live volume.
- **The published image is referenced by tag until the digest pin lands.** One
  follow-up commit, carried in the release checklist.
- **A GitHub App installation token lasts one hour.** Long enough for bootstrap;
  a later manual `git fetch` in a private clone fails closed rather than
  prompting, because `GIT_TERMINAL_PROMPT=0` remains set.
- **`config patch` rewrites the config as strict JSON**, so the JSON5 comments
  never reach a Slack-enabled volume. Phase 4 already established that the
  comments are documentation for whoever reads the image, not a durable feature of
  a running deployment.
- **First seed logs `Config observe anomaly: size-drop-vs-last-good`.** Benign:
  OpenClaw compares against a baseline that predates our smaller seeded config.
  It is stderr noise, not a failure, and nothing asserts on it.
- Everything carried forward from Phases 1–4 still applies, in particular
  `code_repository` reporting `degraded`, basename-colliding document resolvers,
  the name-scoped sweep, and one container per onboarding command.

## Future work

The full hardening ledger now lives in `SECURITY.md` rather than here, so there is
one place to look. It covers Docker file-based secrets, RBAC and user attribution
before shared channels, fail-closed runtime-pin validation, OpenClaw base-image
attestation, Connected Sources and the `branch_protection` resolution, config
reconciliation, `toolSearch`'s experimental status, per-repository authorization,
`mcp.sessionIdleTtlMs`, multi-arch being blocked upstream, and the upstream
`unbind --id` request.
