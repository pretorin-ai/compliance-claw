# CLI self-update — the persistent binary, the updater, and the MCP-only image

Goal: make the Pretorin CLI movable without cutting a Compliance Claw release, and
remove the skill so MCP is the only integration surface. The image keeps shipping a
supply-chain-verified binary, but it becomes a *seed*: the CLI a deployment runs
lives in the `pretorin-state` volume, is updatable from Slack or the host, and
survives image upgrades.

Every earlier convention stands: pins in `versions.env`, write-if-absent seeding,
never-clobber, warn-never-edit, refusals that name the fix, `.env` as the single
container secret file, and CI holding zero credentials.

**Status: IMPLEMENTED, validated locally, NOT released.** Publishing and the VM
deployment follow this pass. Everything below was observed in an isolated compose
project or a throwaway container, not read from a newer doc.

Two things are deliberately **not** claimed as passed:

- **A true forward CLI update.** 0.28.7 is the newest release, so `latest` can only
  be observed reporting already-current, and an explicit reinstall is the closest
  available exercise of the full signed path. A real version-to-version update
  needs a future upstream release.
- **Slack end-to-end, and the gateway-restart activation path.** Both need
  credentials and a live workspace. The plugin's restart call is written
  defensively (feature-detected, degrading to a named manual step) but has not been
  observed completing. Recorded as blocked-on-operator, not as a pass.

## Established facts, measured against the shipped artifacts

| Fact | Evidence |
| --- | --- |
| Standalone self-update does not exist before 0.28.7 | 0.28.2: `Self-update isn't available for binary installs yet`, **exit 0**. The image installs a raw release asset, which is exactly that install kind. |
| 0.28.7 self-updates, and writes atomically | `→ Verifying release v0.28.7… ✓ Updated to 0.28.7`. Inode changed 2464929 → 2465342 in the deployed volume: rename-into-place, so a live `mcp-serve` child is never corrupted. The CLI says the same: *"Already-running processes keep the previous version until they restart."* |
| The CLI refuses the literal `latest` | *"'latest' is not an installable version. Expected X.Y.Z, optionally with a prerelease suffix such as 0.29.0-rc2."* |
| `pretorin update` with NO argument means latest-stable | `✓ Pretorin CLI is already up to date (0.28.7)` — its own release selection, verification, downgrade refusal and prerelease exclusion. |
| **Every refusal exits 0** | `version-invalid` and `not-found` both. The exit code carries no verdict. |
| A same-version reinstall runs the full path | verify → download → swap, observed at the active path. |
| `openclaw config patch` REPLACES arrays | `[/opt/a,/opt/b]` + `[/opt/slack]` → `[/opt/slack]`. It also refuses the whole write when a listed plugin path is absent. |
| A load path is not activation | with `enabledByDefault: false` the gateway banner listed 8 plugins, not 9, while `plugins inspect --runtime` still reported `Status: loaded`. |
| cosign is absent from the runtime image | so delegating verification to the CLI adds no second trust path, rather than being a shortcut. |
| Only a *login* shell drops the active dir from PATH | image `ENV PATH` starts with `/home/node/.pretorin/bin`; `bash -lc` rebuilds PATH from `/etc/profile` and loses it. |
| The anchor did not rotate | release `cosign.pub` is byte-identical to `vendor/cosign.pub`, `sha256 76ebd112…`. |

## Design 1 — one seed, one active binary

The hazard this avoids is two correct answers to one question. If a seed sat on
PATH, `docker compose run --rm cli pretorin version` would report the image's
version while MCP ran an updated one, and an operator would debug the wrong file.

```
IMAGE                                     pretorin-state VOLUME
/opt/compliance-claw/pretorin-seed/
  pretorin   root:root 0755  OFF PATH  ──copy once──►  /home/node/.pretorin/bin/
       ▲                                                  pretorin  node:node 0755
       │ last-resort restore                              ▲ FIRST ON PATH
       │                                                  │ mcp.servers.pretorin.command
       └── only ever named explicitly                     └── `pretorin` anywhere
```

Seeding is write-if-absent on **presence and liveness**: non-empty and executable
always, plus a `version` exec on gateway starts only. A plain `! -e` test keeps a
0-byte file forever and leaves MCP permanently broken; gating the exec matters
because `entrypoint.sh` runs for every `cli` invocation, which is the same reason
its Slack marker check is a fixed-string grep.

Every new entrypoint path is **warn-only**. Under `set -euo pipefail` a fatal seed
failure would abort `docker compose run --rm cli pretorin version` — the one
command left for diagnosing it. `entrypoint.sh:287`'s
`seed_slack || echo "continuing WITHOUT Slack."` is the precedent.

## Design 2 — the updater

One implementation, three callers, so the locking, verification, rollback,
sanitized environment and audit exist once.

```
/claw /pretorin-update X   ─┐   (command: bypasses the LLM; core checks
@Claw update Pretorin      ─┤    isAuthorizedSender BEFORE the handler)
scripts/pretorin-update.sh ─┘   (host: `run --rm cli`, so NO gateway needed)
                            │
                            ▼   /opt/compliance-claw/pretorin-update.sh
                  env -i (self re-exec)  ── no OPENAI/ANTHROPIC/PRETORIN/SLACK/
                            │               GITHUB/GATEWAY_TOKEN reaches the CLI
                  flock -n + timeout      ── refuse, never queue; a stalled
                            │               download cannot hold it forever
                  backup + digest compare ── an unverified backup is not a backup
                            │
                  pretorin update [X.Y.Z] ── the signed trust root
                            │
                  RE-READ version  ◄──────── the exit code is not a signal
                            │
                  mcp-smoke-test (liveness, credential-free)
                            │
                  ┌─────────┴──────────┐
                  ▼                    ▼
              audit + activate     restore: backup → seed → refuse
```

`latest` is passed to the CLI as **no argument at all**. That deleted a GitHub API
resolver, an unsigned-feed threat model, a no-downgrade rule we would have had to
implement *and* test, a new runtime egress dependency, and four resolution failure
modes — all of it work the CLI already does. Explicit prereleases stay refused: an
unattended, Slack-triggered update on a shared instance is the wrong place for a
release candidate.

**Activation is part of the update, not a follow-up.** Because the swap is a
rename, a running MCP child keeps the old inode, and OpenClaw keys its MCP cache
on the config object rather than the file — so "the file was replaced" is not "the
update is live". The plugin requests a gateway restart; the host script restarts
and then probes for a child whose `/proc/<pid>/exe` reads `(deleted)`. When neither
is possible the result is reported as **installed but not yet active** with the
manual step named. Forcing a re-spawn by writing config was rejected:
`slack-channel.patch.json5:88` ships `configWrites: false`, and on a non-Slack
deployment `openclaw config set` rewrites the JSON5 template as strict JSON and
deletes every comment.

**Identity comes only from authenticated invocation metadata.** The command route
reads `ctx.senderId`/`ctx.channel`. The tool route **must** use the factory form:
`execute`'s context is only `{ api, signal, toolCallId, onUpdate }`, while trusted
`requesterSenderId` lives on the factory's `PluginToolContext`. Absent identity is
literally `unavailable`; no argument can set it.

The audit line is written **twice** — a `0600` file in the volume and stderr. That
is not redundancy: the agent runs as the same user with unsandboxed exec and can
rewrite the file, and `down -v` deletes it. The container-log copy is outside both.

## Design 3 — plugin wiring, and why the Slack patch re-lists a path

`plugins.allow` is exclusive, and `config patch` replaces arrays. Both matter:

| | base template | Slack patch |
| --- | --- | --- |
| `plugins.load.paths` | `[updater]` | `[slack, updater]` — **re-listed**, or a fresh Slack seed silently drops the updater |
| `plugins.allow` | **absent** | `["slack", "pretorin-update"]` |
| `plugins.entries` | `{pretorin-update: {enabled: true}}` | `{slack: {enabled: true}}` |

Keeping `allow` out of the base template is what preserves the no-Slack profile:
with no allowlist the eight bundled plugins still load and the config-origin
updater joins them, so the profile CI runs can exercise both routes. It also keeps
`smoke.sh`'s both-or-neither invariant true and the patch's own
"remove `channels.slack`, remove `allow` too" doctrine intact.

## Changes

| File | Change |
| --- | --- |
| `versions.env` | 0.28.7 + new SHA; `CONFIG_TEMPLATE_VERSION=4` with its changelog line; seed semantics and *why 0.28.7 is a floor* documented at the pin; `PRETORIN_SHA256` scoped to the seed |
| `Dockerfile` | seed to `/opt/compliance-claw/pretorin-seed` (root-owned, off PATH); `ENV PATH` puts the active dir first; `pretorin skill install` step removed; wrapper and plugin copied (plain `COPY`, never `--link`) |
| `.dockerignore` | `!plugins/` — the allowlist made the new directory invisible to the build |
| `scripts/entrypoint.sh` | warn-only seed with presence+liveness; **lock-aware** interrupted-update repair; stale-MCP-path and stale-skill warnings; `openai-responses` selection on fresh seed; four `DRIFT-WARNING:` tags |
| `scripts/pretorin-update.in-image.sh` | **new** — the implementation |
| `scripts/pretorin-update.sh` | **new** — host verb via `run --rm cli`, plus restart-and-probe activation |
| `plugins/pretorin-update/` | **new** — manifest + plain-ESM entry: one command, one factory-form tool |
| `scripts/openclaw-config.template.json` | MCP → active path; `api` adapter key; `skills` block removed; updater load path and explicit enable |
| `scripts/slack-channel.patch.json5` | both load paths, both allowlist ids, `channels.slack.slashCommand` |
| `scripts/agents-md.template` | skill instruction → `check_context` / `start_task`; target-selection and provenance kept verbatim |
| `scripts/mcp-call.py` | hardcoded CLI path → PATH-resolved |
| `scripts/smoke.sh` | derived healthz port; seed-vs-active split with sha; plugin diagnostics; key-scope regression; `--self-test`; bidirectional drift contract |
| `scripts/update.sh` | Slack grep fixed; independent drift branches; guidance rewritten; cross-references the CLI updater |
| `compose.yaml`, `scripts/onboard-targets.sh`, `slack/app-manifest.json` | dead `openclaw mcp reload` remedies replaced; manifest comment names the key that actually enables `/claw` |
| `.github/workflows/*` | `--self-test` in CI; release probes name the seed and assert the plugin shipped |
| `README.md`, `SECURITY.md` | see "Documentation truth" below |
| `compose.test.yaml` | **new** — isolated validation project |

### Deviations from the approved plan, and why

| Planned | Shipped | Why |
| --- | --- | --- |
| retarget `verify-pretorin.sh`'s `INSTALL_DIR` | left unchanged; the Dockerfile's `COPY` destination places the seed | equivalent, smaller diff, and the verifier stays a pure function of a directory |
| patch `onboard-targets.sh`'s `pcli` | not needed | PATH ordering already resolves it — as the plan predicted |
| `mcp-call.py` needs no patch | it did | it hardcoded the old absolute path, which stopped existing |
| rewrite `smoke.sh:487`'s cwd assertion | left unchanged | the new consequences got their own warnings and assertions instead of being crammed into the template-version text |
| `--self-test` before `docker compose build` | after it | it runs the shipped code inside the image, so the image must exist |

## Validation — observed results

Isolated project throughout: `COMPOSE_PROJECT_NAME=ccupd`, port **18889**, its own
`.env.test`, fresh volumes. The overlay replaces `env_file` rather than merging it,
because inheriting the operator's `.env` would have connected a **second bot with
the same tokens** to their live Slack channel.

**Deployment safety, measured:** `compliance-claw-openclaw-1` stayed `Up 12 days
(healthy)` on 18789 across every run, and `workspace/targets/simple-crm` was at
`276b5fd8` before and after the suite. The port fix is what makes this real — a
hardcoded `127.0.0.1:18789/healthz` had the test project's health probe answered
by the production gateway.

| # | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | fresh volume seeds the active path | **pass** | `node:node 755`, `pretorin version 0.28.7` |
| 1b | one meaning of `pretorin` | **pass** | bare name → `/home/node/.pretorin/bin/pretorin`; seed reachable only at its explicit path; config agrees |
| 1c | seed is off PATH and not in any std bin dir | **pass** | `ENV PATH` starts with the active dir; assertion verified to FAIL when a binary is planted |
| 4 | offline input rules, in CI | **pass** | 24 accept/refuse cases + the absolute-path invariant |
| 4b | no argument | **pass** | status + usage; never updates |
| 5 | concurrent invocation | **pass** | refused with the holder's identity, not queued |
| 5b | stale lock | **pass** | `--status` reports `lock free` once the holder is gone |
| 6 | `latest` → no argument | **pass** | `✓ Pretorin CLI is already up to date (0.28.7)`, audited `already_current` |
| 6b | same-version reinstall, full signed path | **pass** | `→ Verifying release v0.28.7… ✓ Updated`; inode 2464929 → 2465342 |
| 8 | nonexistent version → rollback | **pass** | CLI refused (exit 0); wrapper caught it by re-reading version; `outcome=rolled_back` |
| 8d | corrupt/absent backup → seed | **pass** | `The backup was unusable; restored the image seed instead` |
| 8e | truncated active binary | **pass** | warned, re-seeded, `size=25762016` |
| 3 | stale volume warnings | **pass** | all three fired; nothing edited |
| 3b | **the printed remedies actually work** | **pass** | ran them verbatim → `Updated mcp.servers.pretorin.command`, `Removed skills.load.extraDirs`; warnings then silent |
| 15 | plugin diagnostics | **pass** | `No plugin issues detected`; `Tools: pretorin_update`, `Commands: pretorin-update` |
| 15c | banner in the no-Slack profile | **pass** | `(9 plugins: … pretorin-update …)` |
| 18 | `cli` invocation during a live update | **pass** | marker preserved, no repair, no audit line |
| 19 | seed failure is warn-only | **pass** | root-owned unwritable dir → warning, container still started, exit 0 |
| tamper | same version, different bytes | **pass** | `SAME VERSION AS THE SEED BUT DIFFERENT BYTES — investigate`, in both `--status` and smoke |
| 20 | drift-warning contract | **pass** | four declared, four grepped, both directions |
| 22 | suite | **pass** | `pass 119  fail 0  skip 1  note 2`; file-secret contract PASS |
| 7 | activation via gateway restart | **not run** | needs a credentialed deployment — see the caveats at the top |
| 11/12/13 | model credentials, key scope, Slack E2E | **not run** | operator-coordinated |

### Bugs the gate found

Each of these looked fine until something executed it.

1. **The repair raced every `cli` invocation.** `entrypoint.sh` runs for all of
   them and `pretorin-state` is on both services, so an unguarded repair would
   restore a backup over a download still in flight — during a *legitimate* update.
   Now takes the same `flock` non-blockingly and stays silent when held.
2. **The Slack patch would have deleted the updater's plugin path**, because
   `config patch` replaces arrays. Verified by applying the patch and reading back
   both paths.
3. **The plugin loaded but never activated.** `enabledByDefault: false` meant the
   banner showed 8 plugins while `plugins inspect --runtime` said `loaded`.
4. **`smoke.sh` sent its health probe to the wrong deployment.** Hardcoded 18789.
5. **`! ls a b c` is not an absence check** — `ls` exits non-zero when *any* path
   is missing, so a release assertion passed with a seed sitting in
   `/usr/local/bin`. Replaced with explicit `-e` tests and verified to fail.
6. **Multiline input slipped past validation.** `grep -E '^…$'` matches per line,
   so `0.28.7\n0.28.8` passed on its first line. Found by `--self-test`, which is
   the entire reason it exists.
7. **The seed-vs-active comparison could never say "unmodified"**, because it
   compared whole `pretorin version` output whose third line is `path:`.
8. **`mcp-call.py` pointed at a path that no longer exists**, which would have made
   the two checks that prove key posture test the wrong binary.

## Documentation truth

| # | Item | Landed |
| --- | --- | --- |
| 1 | `PRETORIN_SHA256` governs the **seed** only; post-update trust is the CLI's signed update | `SECURITY.md` §"The Pretorin CLI trust root", stating the cost plainly: a compromised upstream key now reaches deployments on the next update with no repo-side pin failing closed. Ledger item 3. |
| 2 | smoke NOTE, never FAIL, for active vs seed | version **and** sha256; `note()` at `smoke.sh:40` |
| 3 | an image upgrade no longer changes the CLI | `README` "Updating an existing deployment" rewritten; CLI row added to the survives table including `down -v` reverting to the seed and image-downgrade behavior; `update.sh` header and closing hints updated; each script names the other |
| 4 | shared-instance consequence | README **and** the Slack acknowledgement |
| 5 | audit-record format | `README` §"The update audit record": field table, outcome vocabulary, both read paths, and its limits |
| 6 | troubleshooting rows | five added; the `plugins list` row corrected from 8→9 |
| 7 | the dead Slack warning string | fixed in **both** `update.sh` and `README` |
| 8 | the updater is not a boundary | `SECURITY.md` §"The updater is an audited path"; exec hardening is ledger item 4, marked required before production |

### File-backed model credentials

The API-key path needs the `openai-responses` request adapter; the default
`openai-chatgpt-responses` is correct for device-code login. Shipping either
unconditionally breaks the other, and shipping it only in a test overlay would
prove a configuration nobody deploys. So the **entrypoint selects it on a fresh
seed** when it sees `OPENAI_API_KEY` or `OPENAI_API_KEY_FILE`, through the same
seeding path as everything else, using a targeted `sed` rather than
`openclaw config set` — which would rewrite the JSON5 template as strict JSON and
delete every comment in it.

Never-clobber still applies, so an existing volume is untouched and gets the
documented one-liner. `ANTHROPIC_API_KEY` is already wired, and selecting an
`anthropic/…` model at runtime remains `openclaw models set` with no rebuild.
Both are gate rows awaiting the credentialed run.

## Accepted limitations

- **No repo-side pin stands behind an updated CLI.** Stated in SECURITY.md rather
  than papered over. Ledger item 3.
- **The model-visible route is prompt-injectable**, deliberately, in this
  trusted-repository pilot. Its blast radius is which *signed* version installs.
  The command route is the deterministic recovery path and cannot be model-reached.
- **The audit file is not tamper-evident.** The agent can rewrite it; the container
  log copy is the part that survives. Said plainly in the README.
- **`latest` cannot be observed upgrading** until upstream publishes past 0.28.7.
- **`--flag` gets usage rather than a refusal audit line.** Conventional for an
  unknown flag, but it means that one input class is not recorded.

## Future work

- Run the credentialed gate: activation-by-restart, Slack both routes, the
  read-only/write-enabled key regression, and an agent turn on a file-backed key
  against the shipped template.
- Route 1 from a non-allowlisted channel and from a DM, to establish which of
  `dmPolicy`/`groupPolicy` a slash command bypasses. `requireMention` cannot apply
  to one, so at least one existing gate is bypassed by construction.
- Exec hardening (ledger item 4) before production. The provenance workflow in
  `AGENTS.md` depends on `git`, so neither an exec allowlist nor the sandbox can
  simply be switched on without replacing that path.
- The optional skill install, as a separate restricted feature.

---

# Addendum — correction pass (PR #12 follow-up)

Goal: enforce one principle that the first pass muddled. **The Pretorin API key's
server-side scopes are the sole authorization boundary.** Compliance Claw applies no
local permission filtering, ships no local "mode", and must not have a setting that
reads like one. Two adjacent problems came with it: the secret story was inconsistent,
and the documented fresh-deployment order did not actually work.

**Status: IMPLEMENTED and validated locally. Not released.** The credentialed
acceptance run is operator-coordinated and is recorded as outstanding below, not as
a pass.

## 1. `PRETORIN_KEY_MODE` was never configuration

It existed because `pretorin whoami` reports authentication but not scopes, so the
harness cannot discover whether the key it holds can write — and the probe is
irreversible when it succeeds. Putting that in `.env`, `compose.secrets.yaml` and the
operator docs turned a test declaration into something that reads like a deployment
setting, and one that *defaulted to `read-only`*, implying an enforcement this
repository does not perform.

Removed from every runtime and operator surface. `docs/plans/*` keeps the old name so
this history stays traceable; nothing current mentions it, which makes the gate a plain
`git grep` with no exceptions to remember.

Replaced by explicit harness flags:

| Invocation | Write probe |
| --- | --- |
| *(neither flag)* | **not attempted** |
| `--expect-read-only` | runs it, requires a server-side rejection |
| `--test-write-enabled` | runs it, requires success, announces that it creates a real record |

**The safety property moved to where CI runs.** Asserting "no flag means no write"
only inside the credentialed section meant the run most likely to catch a regression
never checked it. It is now a Section A row, plus one proving an unknown argument is
refused rather than silently selecting a posture.

## 2. Delivery is least privilege, asserted as an exact set

Two over-deliveries to the `cli` service removed: the model keys (it runs no agent
turns) and the gateway token (the entrypoint needs it only for gateway invocations, and
`cli` is one-off by profile — without it, `cli` cannot start a second gateway against
the same volumes).

The old assertion used a subset test, which catches under-delivery and is **blind to
over-delivery** — the exact failure being fixed. Both `smoke.sh` A4d and
`test-file-secrets.sh` now pin each service's secret set in both directions, and the
canary harness proves at runtime that a `cli`-shaped container sees its allowed set
and nothing more.

## 3. The adapter defect, and the regression the fix introduced

```
BEFORE
  onboard-targets.sh (documented, runs before `up`)
        └─► docker compose run --rm cli …   ← FIRST container start; seeds the config
                └─► cli has NO model key ──► adapter = device-login value
                        └─► never-clobber ──► frozen wrong, for the life of the volume
                                └─► gateway later: key authenticates, every turn fails

AFTER
  config on disk holds a MARKER:  api: "${OPENAI_REQUEST_ADAPTER}"
        ├─► gateway (has the key)   ──► exports openai-responses        ──► correct
        └─► cli     (has no key)    ──► exports the device-login value  ──► harmless
```

Observed on the secrets path, following the documented order exactly: the on-disk
`api:` line holds the marker, the gateway process resolves `openai-responses`, and the
`cli` service resolves the device-login value from the same file.

**The fix broke something, and the gate caught it.** `docker compose exec` does not go
through the entrypoint, so an exec'd `openclaw …` found the marker unset — and an unset
`${VAR}` does not fall back to a default, it makes the whole config invalid. That broke
`docker compose exec openclaw openclaw agent`, which the README documents as the way to
run a turn. The Dockerfile now declares the device-login value as an image-level default
so any process in the container can parse the config, and the entrypoint refines it for
PID 1. This is safe for exec'd clients specifically because `openclaw agent` talks to
the gateway over loopback: inference happens in PID 1, which holds the right value.

A measurement error worth recording, because it looked identical to a bug: reading the
adapter with `docker compose exec` showed it empty. That is the file-secret design
working — the entrypoint exports into PID 1's tree and deliberately not into the
container's configured environment. The correct observation is `/proc/1/environ`.

## 4. One overlay could not serve both credential paths

- `compose.test.yaml` is port-only, and the port is a **variable**. Hardcoding it just
  moved the collision from the live deployment to the next isolated project; the symptom
  was a container stuck in `Created` with no logs.
- `compose.test-env.yaml` carries the `.env` isolation, which belongs to the legacy path
  alone. Stacked on `compose.secrets.yaml` it re-added a `.env` gateway token beside the
  mounted one and tripped the entrypoint's dual-source refusal — correct refusal, wrong
  overlay, found by stacking them and watching the gateway decline to start.

## Validation — observed results

Isolated projects on derived ports (legacy path 18889, file-secret path 18991), canary
values only. **All secret values, tokens and identifiers are redacted here by
construction: every credential used was a fake canary, and no real key, token, channel
id or org-internal URL appears in this record.**

| Check | Result | Observed |
| --- | --- | --- |
| the variable is absent from all current files | **pass** | `git grep` clean outside `docs/plans/` |
| no posture flag → no write probe | **pass** | asserted positively in the section CI runs |
| unknown argument refused | **pass** | does not fall through to a default posture |
| `--expect-read-only` / `--test-write-enabled` select correctly | **pass** | all three postures exercised without credentials |
| delivery matrix, exact set per service | **pass** | `openclaw` 6, `cli` 3; gateway token and model keys absent from `cli` |
| runtime containment | **pass** | a `cli`-shaped container sees its allowed canaries and none of the excluded ones |
| adapter derives from the credential | **pass** | no model key → device value; OpenAI key → `openai-responses` |
| documented order produces the right adapter | **pass** | seeded by `cli`, resolved correctly by the gateway |
| exec'd commands parse the config | **pass** | regression found and fixed via the image-level default |
| suite | **pass** | `smoke --no-creds`: 121 pass, 0 fail, 1 skip, 2 notes; file-secret contract pass |
| live deployment untouched | **pass** | healthy on its own port throughout; shared target clone unchanged |
| credentialed acceptance (§4 end to end, both key postures) | **not run** | operator-coordinated |

## Still outstanding

The credentialed sequence: populate one model key and the Pretorin key, onboard, start,
then a **real agent turn with no device-code login and no manual config patching**,
Slack round trip, provider actually serving, and both key postures via the new flags —
`--expect-read-only` with a read-only key, `--test-write-enabled` with a write key. When
recorded, redact every value and identifier.

# Addendum — credentialed local acceptance run

Run on 2026-08-25 against branch `chore/cli-self-update` at `217b9fe`, in an
isolated Compose project. **All secret values, key fragments, tokens, record ids
and org-internal identifiers are redacted.** Nothing was merged, tagged,
published or deployed.

## Isolation, and the one deliberate omission

| | |
| --- | --- |
| project | `ccacc` (own `COMPOSE_PROJECT_NAME`, fresh volumes) |
| port | `127.0.0.1:18991`, derived — never 18789 |
| repo | a scratch copy of `HEAD`, because `bootstrap.sh` writes `.env` and the operator's `.env` carries live legacy credentials |
| secrets | a throwaway dir; real Pretorin key, **freshly generated** gateway token |
| image | built locally (`compose.build.yaml`), since the branch is unreleased |
| Slack tokens | **left empty on purpose** — see below |

The Slack tokens were left empty as the isolation lever. The entrypoint gates the
Slack patch on all three of `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` and
`SLACK_CHANNEL_ID`, so empty files mean no socket-mode client is ever started and
the shared Slack app is untouched. This was necessary, not convenient: see
"What could not be run".

Live deployment verified before, during and after — `Up 12 days (healthy)` on
18789, shared target clone unchanged at `276b5fd`, operator `.env` digest and all
six `secrets/runtime/` files unchanged.

## What the run proved

Fresh flow, in the documented order, with no manual config editing and no
device-code login:

```
bootstrap.sh --build  ->  onboard-targets.sh  ->  up -d
```

| Property | Observed |
| --- | --- |
| `.env` holds no secret on the file-secret path | 0 non-empty secret assignments |
| bootstrap names only what is *actually* empty | named `openai-api-key OR anthropic-api-key`, correctly silent about the populated Pretorin key |
| seed is off PATH and root-owned | `/opt/compliance-claw/pretorin-seed/pretorin`, `root:root` |
| active binary is first on PATH | `command -v pretorin` -> `/home/node/.pretorin/bin/pretorin`, `node:node` |
| seed copy is byte-identical to the pin | both `sha256` = `f7ae0bb5…dea711` = `PRETORIN_SHA256` |
| MCP command points at the persistent path | `mcp.servers.pretorin.command: /home/node/.pretorin/bin/pretorin` |
| adapter resolves per process | PID 1: `OPENAI_REQUEST_ADAPTER=openai-chatgpt-responses` (no OpenAI key present — the correct branch) |
| onboarding against the real platform | 0 failures, 0 warnings; 13 recipes; `code_repository` degraded as expected |
| a read tool through MCP | `list_frameworks` returned 26 frameworks through `pretorin mcp-serve` |
| updater plugin activates | gateway banner: 9 plugins including `pretorin-update`; `plugins inspect --runtime` -> `Tools: pretorin_update`, `Commands: pretorin-update` |
| gateway restarts and MCP survives | healthy after restart; `list_frameworks` still returned 26 |
| `smoke.sh --test-write-enabled` | **137 pass, 0 fail, 2 skip, 2 note** |
| `smoke.sh --no-creds`, legacy path, separate project | **123 pass, 0 fail, 1 skip, 1 note** |

Key posture: the operator's key is **write-enabled**. `whoami` reports
authentication but not scopes, so posture is only discoverable by attempting a
write. Three probe risk records were created and are safe to delete; they are
titled `compliance-claw smoke probe - key scope regression` and
`compliance-claw acceptance probe - key posture discovery`. A fourth, older
record titled `compliance-claw smoke probe - read-only key must be rejected`
dates from 2026-08-06 and is a stale artifact of an earlier session.

## Updater behaviour, including the paths that are meant to fail

`0.28.7` is simultaneously the latest upstream release **and** the floor for
self-update, so there is currently no legal `(from, to)` pair. Attempting
`0.28.6` surfaced why, and the wrapper handled it exactly as designed:

```
✗ Update refused (manifest-cutoff): release v0.28.6 predates self-update
  metadata (its signed manifest has no RELEASE-TAG entry)
pretorin-update: the update did not take effect.
  requested 0.28.6   previous 0.28.7   now 0.28.7
pretorin-update: restored the previous binary from backup (verification failed).
v=1 … outcome=rolled_back requester=unavailable route=unknown
```

That answers the open §A question: **the verify flow does consume `RELEASE-TAG`**,
and pre-0.28.7 releases are not installable targets at all — a stronger statement
than the "cannot self-update" floor already recorded in `versions.env`.

Three things this confirms, none of which needed a newer release:

- the CLI **exits 0 on refusal**, and the wrapper caught it anyway by re-reading
  the version rather than trusting the exit code
- rollback restored the previous binary, digest-verified
- the audit line carries `requester=unavailable` — correct for a host CLI
  invocation, which has no authenticated metadata — and no secret value

The already-current path is classified separately and does **not** produce a
spurious rollback:

```
✓ Pretorin CLI is already up to date (0.28.7).
v=1 … outcome=already_current requester=unavailable route=unknown
pretorin-update: activating 0.28.7: restarting the gateway so MCP picks it up
```

`--self-test` passed all 22 input cases offline, including the multiline
`0.28.7\n0.28.8` case and the shell-metacharacter set.

## Five defects found and fixed

The run existed to find these; all five are fixed on the branch.

**1. An operator message was being executed instead of printed.**
`onboard-targets.sh`'s completion text named the command you must *not* run,
in backticks, inside an unquoted `cat <<EOF`. The shell ran it:

```
scripts/onboard-targets.sh: line 334: openclaw: command not found
```

and the sentence came out as `(Not  from the cli service:` — the one word it
existed to say had been deleted by the shell. Two conventions broken at once:
name-the-fix, and never execute what you mean to display. Fixed by escaping;
gated by the new `scripts/lint-heredocs.py` and smoke row **A3d**, which also
re-introduces the defect in a copy each run so the checker cannot go vacuously
green.

**2. `toolFilter` false positive.** B4's "no local tool filter is configured"
failed against a config that configures none: the template *documents* the option
as `// toolFilter: {`, and the check grepped the raw JSON5. Same defect class as
the absolute-path invariant that once matched its own comment. Fixed with a
comment-stripped `CFG_LIVE` view (whole-line comments only — `http://` contains
`//` too).

**3. The `.env` gateway-token assertion contradicted the recommended path.**
A10 required `^OPENCLAW_GATEWAY_TOKEN=.+` unconditionally, but on the file-secret
path a value in `.env` is a *defect* and bootstrap deliberately writes the key
empty. The assertion is now path-aware, and both arms were verified non-vacuous
(legacy `.env`: 1 matching line; file-secret `.env`: 0).

**4. The Slack canary probe never ran on the file-secret path.** It injected
canaries as `-e SLACK_BOT_TOKEN=…` while compose also mounted
`SLACK_BOT_TOKEN_FILE`. The entrypoint correctly refused the dual source, the
container exited before the grep, and the check then reported
`N file(s) contain a canary token` about a probe that had not executed. Correct
refusal, wrong injection, and a message describing the opposite of what happened.
Canaries now go into files on that path, and the outcome is three-way:
hits / clean / **probe did not run**.

**5. `docker compose exec` cannot resolve the gateway token.** The entrypoint
exports secrets in PID 1; an `exec`'d process is a child of the daemon, so on the
file-secret path `OPENCLAW_GATEWAY_TOKEN` is unset and `openclaw agent` dies with
`GatewaySecretRefUnavailableError` **before** model resolution. This read as "no
model key" and was not — same defect class as the adapter marker. B6 now re-reads
the token from `/run/secrets` *inside* the container (never through the docker CLI
argument list, which `ps` can see), the secret-ref failure has its own branch so
it can never masquerade as a credential problem again, and the footgun is
documented in `docs/file-secrets.md`.

## A sixth: the activation probe was blind on this platform

Not in the original list because it only appears under emulation. The probe
looked for `(deleted)` in `/proc/<pid>/exe`, which works on the amd64 deployment
target — but this image runs linux/amd64 on Apple Silicon, where `exe` resolves
to `/run/rosetta/rosetta` and can never contain `(deleted)`. So the probe printed
the reassuring `No MCP child is running a replaced binary` having observed
nothing at all: assert-by-absence, the exact trap this repo keeps re-learning.

It now uses a second, platform-independent observable — a child that started
before the active binary's mtime cannot be running the new bytes — and reports
three outcomes rather than two, including an explicit **UNVERIFIED** when the
inspection itself fails. All three branches were driven:

```
FRESH  /proc/9   started-after-binary(1787686140>=1787685976)
STALE  /proc/131 started-before-binary(1787686188<1787686193)
NONE   no mcp-serve child running
```

The STALE case was produced by advancing the binary's mtime with `touch` while a
child was held open; `sha256` was confirmed unchanged either side, so this
exercised the detector without touching the signed-update path.

## What could not be run, and why

**A real agent turn — blocked, no OpenAI API key exists on this machine.**
`secrets/runtime/openai-api-key` and `anthropic-api-key` are both 0 bytes, and
neither key is in `.env` or the environment. The only OpenAI credential present
is `~/.codex/auth.json`, which is the device-login path the brief excludes. The
tooling diagnosed this itself — bootstrap printed *"still empty, and needed before
an agent turn"* — and B6 correctly skips rather than passing. Everything the turn
would depend on is proven: the adapter resolves per process, the persistent CLI
serves MCP, and the gateway-token path is fixed. Only "a real key serves a turn"
is unobserved.

**Slack message/reply and both Slack update routes — blocked, and this one is a
safety decision rather than a missing credential.** The live gateway logs:

> socket mode reports **10 active connections for this Slack app**; Slack may
> deliver each event to any one connection

Slack delivers each event to exactly one of the connections on an app. A second
gateway on the same tokens would therefore (a) receive events intended for the
operator's live deployment and answer them in the real channel, and (b) hand my
test messages to whichever gateway won the race. That is a change to the working
deployment's behaviour even though none of its containers are touched, so I did
not connect. It needs **a separate Slack app** (its own app/bot tokens) — the
same remedy the upstream warning names.

Route 1 is *registered and loaded* — `plugins inspect --runtime` reports
`Commands: pretorin-update` — but it is dispatchable only from a channel
provider. There is no local or HTTP dispatch path in 2026.7.1: `openclaw message`
has no command verb, and `/commands` on the gateway is the control-UI SPA
catch-all, not an API. So both routes wait on the Slack app.

**`smoke.sh --expect-read-only` — blocked, no read-only key.** The operator's key
is write-enabled, so this invocation would fail by design and prove nothing. The
write half passed. Covering the read-only half needs a second, read-scoped key;
until then the read-only branch of B4 has never executed.

## Still outstanding

1. A second Slack app, then: Slack round trip, route 1 (command, LLM-bypass) and
   route 2 (agent tool, needs a model key). Route 1 will also settle which of
   `dmPolicy`/`groupPolicy` a slash command bypasses.
2. An OpenAI API key, then a real agent turn with provenance.
3. A read-only Pretorin key, then `--expect-read-only`.
4. `0.28.8`, then the update **success** path: bytes actually change, MCP recycles
   onto the new binary, `outcome=updated`.
5. Exec hardening (SECURITY.md ledger item 4) before production.
6. Housekeeping: three probe risk records from this run, one stale record from
   2026-08-06, and orphaned `ccaccept_*` volumes from an earlier session.
