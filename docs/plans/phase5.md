# Phase 5 — shippable POC: Slack, private repos, a published image, and the docs

Goal: make the Phase 1–4 deployment shippable to someone who did not build it.
Reproducible Slack from a fresh volume, private repository targets, a published
and signed image that operators pull instead of build, and the documentation pass
that ties the four previous phases together.

Every earlier convention stands: pins in `versions.env`, write-if-absent seeding,
never-clobber, the runtime pin and its drift alarm, `toolSearch` directory mode,
key scopes as the authorization boundary, sweep-then-bind onboarding, and `.env`
as the single **container** secret file.

**Status: IMPLEMENTED.** Design, implementation and the no-credential half of the
verification gate are complete and recorded below. The criteria that need operator
prerequisites — a GitHub App, a Slack app created from the committed manifest, and
a pushed release tag — are recorded as blocked-on-operator with exactly what is
missing, never as passes.

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

## Design 3 — GHCR publish, scan, SBOM, signature

### Two cosign pins, deliberately

`COSIGN_VERSION=v2.4.1` stays frozen: cosign v3 removed `verify-blob --signature`
and cannot verify the Pretorin release at all. Image signing gets its own
`COSIGN_CI_VERSION=v2.6.5` with its own checksum. Keyless signing transacts with
the live Fulcio/Rekor trust root and cannot be exercised outside CI, so reusing a
2024-line build would surface the failure on the release tag — the most expensive
possible moment. Both pins carry a comment naming the job that uses them.

### Pipeline

```
1. assert release.yml references no secret but GITHUB_TOKEN   (self-check)
2. assert the git tag equals v${IMAGE_VERSION} from versions.env
3. install cosign / trivy / syft, each checksum-verified
4. docker build --platform linux/amd64
5. in-image smoke: pretorin, openclaw, arch, Slack plugin present
6. trivy: FAIL on fixable CRITICAL; a second non-blocking run reports HIGH
7. syft SPDX SBOM, refused if it contains zero packages
8. push, then read the digest from RepoDigests
9. cosign sign the DIGEST (keyless); cosign attest the SBOM
10. job summary prints the digest and the operator verify command
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
| `targets.yaml` | `crm-deploy` as the private example, `ref: master` |
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
| A4 gateway + seeding | pass | `/healthz` ok; config, `AGENTS.md` and marker seeded at v3 |
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

### Release tooling, verified offline

The tag gate, the pin extraction and the three checksum-pinned downloads were
exercised on the host rather than assumed:

```
tag v0.1.0 -> ACCEPT      tag v0.2.0 -> REJECT      tag 0.1.0 -> REJECT
cosign-linux-amd64 (v2.6.5)            : OK
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

## Completion criteria

| # | Criterion | Status | Evidence / what is missing |
| --- | --- | --- | --- |
| 1 | Fresh clone, clean directory | **not yet run** | Deferred until the image is published, so the run exercises the real pull path |
| 2 | Configure secrets from `.env.example` | **partial** | `.env.example` documents all eight variables; the operator's `.env` has the Pretorin key and gateway token, and lacks the Slack channel id, the GitHub App and `PRETORIN_KEY_MODE` |
| 3 | Pull the released GHCR image | **blocked-on-operator** | Needs `feat/poc` and tag `v0.1.0` pushed. Workflow implemented; tag gate, pins and downloads verified offline |
| 4 | `docker compose up -d` | pass | Gateway healthy throughout the smoke run |
| 5 | Slack connects automatically, reply from Slack | **mechanism pass, round-trip blocked** | A12 proves a fresh volume comes up Slack-configured with zero manual JSON and the plugin loads. The live round-trip needs a Slack app created from the committed manifest and a working model login |
| 6 | Claw reads a selected PRIVATE repo | **blocked-on-operator** | Needs the read-only GitHub App on `crm-deploy`. Refusal paths, parser contract and credential hygiene all verified (A11) |
| 7 | Read workflows on a read-only key; write workflow after opt-in, all four provenance fields | **partial / blocked-on-operator** | Read paths pass (B1–B3, B5). The write half needs the formal recipe run and a model login; note the accidental write in bug 3 above was a bare `create_risk`, **not** the recipe workflow, and does not count |
| 8 | Zero manual container modification | pass | Every state change in the run came from `bootstrap.sh`, `onboard-targets.sh`, the entrypoint or `smoke.sh` |

Nothing above is marked pass on the strength of an argument. The four incomplete
rows each name the specific artifact that does not exist yet.

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
