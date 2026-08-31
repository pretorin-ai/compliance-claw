# Effort configuration and `clawctl`

Goal: let one gateway serve many Pretorin compliance efforts. An effort is one
system + framework pair with its own targets and its own named credential, and
each effort's MCP process is pinned to its scope by `PRETORIN_SYSTEM_ID` /
`PRETORIN_FRAMEWORK_ID` in the environment.

PR 1 is the configuration layer, the operator control command (`clawctl`),
effort-aware onboarding, migration, and the credential-delivery mechanism PR 2's
generated agents and MCP configs will consume.

**Authority timeline.** PR 1 creates the format side by side; `targets.yaml`
stays runtime-authoritative. **PR 2 switches runtime authority to
`efforts.yaml`.** PR 4 removes the compatibility code. `targets.yaml` keeps
working in PR 1 because PR 2 needs a live compatibility path to switch from.

---

## Evidence row #1 — the env-pin probe (STEP 0 GATE)

Everything below rests on one claim: **`PRETORIN_SYSTEM_ID` /
`PRETORIN_FRAMEWORK_ID` govern MCP tool dispatch, and stored CLI context
(`pretorin context set`) is non-authoritative.** Nothing in this repository
exercised those variables before this PR — the only scope mechanism in the tree
was [onboard-targets.sh:286](../../scripts/onboard-targets.sh#L286)'s
`context set`. So the claim was measured before any code was written.

**Conditions.** Pretorin CLI **0.28.7** (the `PRETORIN_VERSION` pin), the active
binary at `/home/node/.pretorin/bin/pretorin`. Image
`0.3.2@sha256:e63bacb…`. File-backed credential path. The deployment key
(`4HBTslGu…4TRQ`, `platform.pretorin.com`) — **write-enabled**, established the
hard way during a later probe (see *Correction*, below), not read-only as this
document first recorded. Two scopes visible to the key, both
on system `13c1f44e-…` ("Fathom"): **`soc2`** and **`hipaa`** — the same system
under two frameworks, which is precisely two separate compliance efforts.

**Stored context throughout: `Fathom / soc2`.** It was never modified; `context
set` was not run at any point. It was still `soc2 / valid` after every probe.

### R1 — the read tool reports the ENV-PINNED scope (decisive)

```
$ mcp-call.py check_context                       # no env pin
  "active_system":        { "id": "13c1f44e-…", "name": "Fathom" }
  "active_framework_id":  "soc2"                  <- matches stored context

$ PRETORIN_FRAMEWORK_ID=hipaa mcp-call.py check_context
  "active_system":        { "id": "13c1f44e-…", "name": "Fathom" }
  "active_framework_id":  "hipaa"                 <- ENV WINS over stored soc2
```

Stored context re-read immediately after: still `soc2`. **The env pin governs
dispatch and does not mutate stored state.**

### R2 — the WRITE GUARD reads the env pin, not stored context

This is the load-bearing measurement. Stored context is `soc2`; the process is
env-pinned to `hipaa`; the write targets `soc2`. If the guard were reading stored
context it would see `soc2`, find the write aligned, and permit it.

```
$ PRETORIN_SYSTEM_ID=13c1f44e-… PRETORIN_FRAMEWORK_ID=hipaa \
    mcp-call.py create_risk '{"system_id":"13c1f44e-…","framework_id":"soc2",…}'

Error: Active context is 'Fathom (13c1f44e-…) / hipaa'; refusing write to
       '13c1f44e-… / soc2' without explicit scope override.
```

The guard names **`hipaa`** — the environment — while stored context said
`soc2`. **Env pinning governs the write guard. Stored CLI context is
non-authoritative.** The gate passes.

### R3 — `allow_scope_override` supplied by the caller is IGNORED

The same call, with `"allow_scope_override": true` added to the arguments,
produced a **byte-identical** refusal:

```
Error: Active context is 'Fathom (13c1f44e-…) / hipaa'; refusing write to
       '13c1f44e-… / soc2' without explicit scope override.
```

An agent cannot talk its way out of its own scope pin by setting the flag.

### Correction — the key is write-enabled, and two records were created

This document originally described the probe key as read-only. It is not. A later
probe for the friendly-name issue ran `create_risk` twice with the pin and the
target ALIGNED, and both **succeeded**, creating real records on Fathom / soc2:
`03f9ea1b-fd0c-4d89-9721-016991ab4e00` and
`9942495b-04cc-4442-9d84-81e2cd782d8f`, both titled
`scope-name probe - do not action`. No MCP delete tool exists (`update_risk` is
the only mutator), so they must be removed in the Pretorin UI.

That is exactly what [smoke.sh](../../scripts/smoke.sh)'s `WRITE_POSTURE=unstated`
rule exists to prevent, and it was defeated by treating "read-only key" as
established rather than measured. The rule stands unchanged: **no write is
attempted on an undeclared posture.** The R1–R3 probes below remain valid — every
one of them was refused client-side by the scope guard before reaching the
platform, which is why they created nothing.

### R4 — the cross-scope refusals are client-side, so they created no record

Every refusal in R2 and R3 names the active context and declines before
contacting the platform, so those created nothing. The repo's own rule
applies — [smoke.sh](../../scripts/smoke.sh)'s `WRITE_POSTURE=unstated` means no
write is ever attempted on an undeclared posture, because an undeclared
write-enabled key once created a real risk record. The positive control (the same
write succeeding in its own scope with a declared write-enabled key) stays in the
credentialed acceptance rows, behind an explicit flag.

### Two findings that CHANGE the plan

**F1 — `check_context` is not a platform-access probe. `clawctl validate` must
not use it alone.** Pinned to a system UUID that does not exist, it still
returned `"connected": true`, and worse, `active_system.name` still read
**"Fathom"** — the id came from the environment while the name lagged from cached
state:

```
$ PRETORIN_SYSTEM_ID=00000000-dead-4beef-8000-000000000001 mcp-call.py check_context
  "connected": true
  "active_system": { "id": "00000000-dead-4beef-…", "name": "Fathom" }   <- stale name
```

A real platform read rejects the same system properly:

```
$ mcp-call.py get_compliance_status '{"system_id":"00000000-0000-4000-8000-000000000001"}'
Error: Not found: System '00000000-…' not found
```

And `get_compliance_status` **ignores `framework_id` entirely** — a nonsense
framework returns the identical system-wide payload — so on its own it proves the
SYSTEM only:

```
$ mcp-call.py get_compliance_status '{"system_id":"13c1f44e-…","framework_id":"not-a-real-framework"}'
  { "system_id": "13c1f44e-…", "frameworks": [ { "framework_id": "hipaa", … } ] }   <- unchanged
```

What it does carry is the system's **attached** frameworks, and that is the pair
check. This key can see seven frameworks; only two are attached to Fathom. So
`validate` asserts `check_context`'s **`active_system.id` and
`active_framework_id`** (never `active_system.name`, which lags the pin), then
requires the declared framework to appear in the attached list. A framework that
merely exists is not enough.

**F2 — the scope guard covers WRITES, not READS.** With the process env-pinned to
Fathom, a read naming a different system was not refused by the guard at all; it
went to the platform and failed only because that system does not exist. Reads
are governed by their arguments and by the key's own scopes, not by the env pin.

This does not weaken PR 1 — the architecture's claim is about write containment,
and R2/R3 establish it. But it must be stated plainly rather than left for
someone to assume: **an agent pinned to effort A can read another system's data
if its key has access to that system and the agent knows the id.** The
authorization boundary for reads is the key's scopes, which is the standing
principle. `docs/efforts.md` says so, and it is an argument for per-system keys
where read isolation between efforts actually matters.

### Summary

| Claim | Verdict | Evidence |
| --- | --- | --- |
| Env pin governs MCP dispatch | **HOLDS** | R1 |
| Write guard reads env pin, not stored context | **HOLDS** | R2 |
| Caller-supplied `allow_scope_override` ignored | **HOLDS** | R3 |
| Stored CLI context is non-authoritative | **HOLDS** | R1, R2 |
| Stored context unmodified by pinning | **HOLDS** | R1, post-probe re-read |
| `check_context` alone proves platform access | **FALSE** | F1 — probe design changed |
| Reads are scope-guarded | **FALSE** | F2 — writes only; documented |

**Gate result: PASS.** Implementation proceeds.

---

## Design 1 — the schema, and what it refuses

`efforts.yaml` is a list of efforts; each is one system + framework pair, its
targets, and a **named** credential.

```yaml
efforts:
  - name: crm-soc2
    system_id: 13c1f44e-…
    framework_id: soc2
    credential_ref: default        # a NAME. No token ever appears in this file.
    targets:
      - name: simple-crm
        url: https://github.com/pretorin-ai/simple-crm.git
        ref: main
```

Three rules are new, and each exists because of a specific failure:

**`system_id` + `framework_id` must be unique across efforts.** One preflight
artifact is keyed on that pair. Two efforts sharing it are one compliance effort
wearing two names, and they would sweep and bind over each other's resolvers
forever.

**Target names are a GLOBAL namespace, with an equal-definition exemption.**
Every target is cloned to the one directory `workspace/targets/<name>`, and
Pretorin derives resolver names from the directory basename — so the name cannot
be per-effort. But sharing a repository between efforts is the *point* (the same
code under SOC 2 and HIPAA), so the same name in two efforts is accepted when
`url`, `ref` and `private` are identical: one clone, bound into each scope. Two
*different* definitions under one name is refused, naming both efforts and the
field that differs. Without that, whichever effort synchronised last would
silently decide what every other effort is reviewing.

**`system_id` must be the canonical UUID, never a friendly name.** Pretorin
accepts either in many places, but the CLI resolves a write's target to a UUID
BEFORE comparing it against the environment-pinned scope, and that comparison is
literal. Measured on 0.28.7 — with `PRETORIN_SYSTEM_ID=Fathom`, a write to that
same system's own UUID is refused:

```
Error: Active context is 'Fathom / soc2'; refusing write to
       '13c1f44e-b66d-417c-8604-4ac7b988b411 / soc2' without explicit scope override.
```

So a name here rejects legitimate writes to the system it names, and it also
defeats the duplicate-pair check, which compares literals: `Fathom` and its UUID
are one system and would not be seen as one. It is **refused, not resolved** —
resolving would mean a credentialed name lookup on every parse, turning an
offline validator into something that needs a key. Uppercase is accepted and the
pair check compares case-insensitively.

**Every identifier is charset-checked, including for a leading dash.** These
values become directory names, container paths, credential file paths and process
environment. The character class refuses `/`, `$`, backticks, `;`, `|`, quotes and
spaces. A **leading `-`** gets its own rule because it does not look dangerous and
is: `system_id: --system` becomes an argv element in a command `clawctl` builds.

Per-target rules are **not restated**. `parse-efforts.py` loads `parse-targets.py`
by path and calls its `validate_target()`, so https-only, the strict `private`
boolean and the github.com restriction have exactly one definition across both
formats. The alternative — a second copy — has a known dangerous direction: a
private repository parsed as public fails with an authentication error that reads
like a network fault.


## Design 2 — per-effort credentials

The gateway process has **one** environment. The config template resolves
`env: { PRETORIN_API_KEY: "${PRETORIN_API_KEY}" }` from it at config-load time, so
every MCP child receives the same key. Writing per-effort key *values* into
`openclaw.json` would put secrets into the state volume, which the whole
file-backed secret design exists to prevent.

So: **a mounted credential directory plus a trusted launcher.**

```
  host                                container                        process
  ────                                ─────────                        ───────
  secrets/runtime/pretorin-api-key ─► /run/secrets/pretorin_api_key ─┐
      (already mounted, = "default")                                 │
  secrets/runtime/pretorin/<name>  ─► /run/compliance-claw/           ├─► pretorin-mcp-launch <effort>
      (compose.efforts.yaml)            credentials/<name>   :ro      │     asks parse-efforts.py
  efforts.yaml                     ─► /etc/compliance-claw/           │     for scope + credential path
                                        efforts.yaml         :ro     ─┘     exports, then exec mcp-serve
```

`compose.efforts.yaml` adds those two read-only mounts to **both** services.
Volume lists merge across compose *files* keyed on the container path — unlike the
YAML-merge-key case inside one file that `compose.yaml` warns about, where writing
only the extra mounts once dropped both state volumes. Verified rather than
assumed: `docker compose config` shows `openclaw` at 7 mounts (5 base + 2) and
`cli` at 5 (3 base + 2), with secrets unchanged.

**One credential ladder, one copy.** `parse-efforts.py` owns the mapping in both
host and container modes; the launcher asks it rather than reimplementing the
table in bash. Two copies of a security-relevant mapping drift, and the direction
they drift in is "the launcher reads a different file than the validator checked".

**`default` resolves to the credential the deployment already had.** A migrating
single-effort deployment therefore needs no new secret file, nothing is copied,
and there is no second authoritative copy of one key to rotate. The name is
reserved: a file at `secrets/runtime/pretorin/default` would shadow the legacy one
with no way to tell which a process read, so it is refused.

**The launcher fails closed.** Missing python3, missing parser, missing
`efforts.yaml`, unknown effort, missing/empty/unreadable credential — each exits
non-zero with a named cause. That matters more than it looks: PID 1 exports the
legacy `PRETORIN_API_KEY` container-wide, so a launcher that carried on after
failing to resolve its own credential would run one effort's agent on another
effort's key, writing to the wrong compliance scope with a perfectly valid
credential. `scripts/test-effort-credentials.sh` proves it cannot.

**python3 is inherited, not installed.** The runtime stage adds no apt package;
python3 comes from the OpenClaw base image, and three things now depend on it.
The Dockerfile asserts it at build time (`RUN python3 --version`) so a base image
that ever drops it breaks the build rather than production.

## Design 3 — `clawctl`

```
scripts/clawctl validate        [--schema-only] [--effort NAME]
scripts/clawctl migrate         [--name NAME]
scripts/clawctl credential add  NAME
scripts/clawctl plan            [--effort NAME]
scripts/clawctl apply           [--effort NAME]
scripts/clawctl --self-test
```

**No `context set` anywhere on this path.** Stored context is a single global and
cannot describe more than one effort. Scope is pinned per process, which evidence
row #1 shows overrides it.

**`validate` collects all, never fails fast.** With N efforts, stopping at the
first problem means N edit-run cycles. One run prints a row per effort and exits
non-zero if any failed. It short-circuits *within* a row — schema, file, mode,
probe — and **the mode check precedes the probe** because probing a credential the
container cannot read produces an authentication error that blames the key.

**The probe is two calls, because one is not enough.** See finding F1:
`check_context` reports the pin but is not a platform-access probe, and its
`active_system.name` lags the pin. So the scope assertion reads
`active_system.id` and `active_framework_id` and never the name, and a real scoped
platform read must also succeed.

**`plan` and `apply` cannot drift.** Both go through `ol_pcli` in
`scripts/onboard-lib.sh`, which renders each command from the same arrays it then
executes. The printed line *is* the command, shell-quoted so it can be pasted
back. The self-test asserts every echoed line is byte-identical to recorded argv —
in that direction, because printing a line you do not run is the lie that makes
`plan` worthless.

**`plan` starts zero containers**, makes zero network calls and reads zero
credential values. It does `stat` the resolved paths — existence only.

**One container per Pretorin command, and that is a known cost.** `apply` keeps
`onboard-targets.sh`'s shape so every command is echoed and rerunnable by hand;
that auditability is load-bearing for a compliance tool. It costs roughly 30
container starts for three efforts of three targets, minutes under amd64 emulation
on Apple Silicon and much less on the native-amd64 VM this is headed for.
Recorded here as an accepted cost, not a TODO.

### The lock

`apply` mutates the Pretorin state volume; so does `scripts/pretorin-update.sh`,
which replaces the active CLI binary, and the entrypoint's interrupted-update
repair. Those already coordinate on **one** lock: `flock` over
`/home/node/.pretorin/.update.lock`, inside the named volume.

A host-side lock cannot see that — the volume has no stable host path. So the
holder lives in a container: a detached `cli` sidecar takes the same `flock` and
waits. That puts `apply` in the one namespace that already governs this volume,
**with no edit to the updater or the entrypoint**.

It buys a second property. `entrypoint.sh` probes this exact lock on every
container start, so for the whole apply window the interrupted-update repair is
suppressed and cannot fire mid-sequence. That closes a known hazard by
construction rather than by timing.

`flock` records no holder identity, so a refusal names the two things it could be
— another `apply`, or an in-flight CLI update — rather than pretending to know.
**No lock-file deletion, ever**: `flock` releases on process death, so a killed
sidecar frees it by itself.

### The audit record

`apply` is the most audit-relevant mutation in the product: it changes which
repositories feed which compliance scope. The repo already establishes the
convention twice (the sync record and the update record), so `apply` follows it —
one line per effort per run, append-only in the state volume **and** echoed to
stderr so the container logs hold a copy. Fields: timestamp, effort, system,
framework, credential **name**, targets, outcome. The canary sweep proves the
value never lands there.

## Design 4 — extraction, not duplication

| File | Role |
| --- | --- |
| `scripts/onboard-lib.sh` **(new)** | sweep → bind → verify → provision → assert, with the command renderer. Two callers. |
| `scripts/onboard-targets.sh` | now a thin caller for the legacy path. Behaviour unchanged, `context set` included. |
| `scripts/preflight-artifact.py` **(new)** | the artifact analyser, lifted out of a heredoc into a real file because it now has two callers. |
| `scripts/parse-efforts.py` **(new)** | the effort schema **and** the credential ladder. |
| `scripts/parse-targets.py` | one surgical change: `validate_target()` extracted so both formats share it. Output byte-identical to before. |
| `scripts/pretorin-mcp-launch.sh` **(new)** | thin wrapper over the ladder; fails closed. |

`preflight-artifact.py` gained one check while being extracted: the set of bound
in-mount `code_repository` paths must **equal** the declared set. The old version
proved every declared target was bound but could not see a target that was bound
and *not* declared — and with several efforts sharing one mount, that is now a
real shape. An undeclared target keeps feeding evidence into a compliance effort
that no longer claims it. Verified firing.

## Migration

```sh
scripts/clawctl migrate --name crm-soc2
```

`targets.yaml` is **not modified** — it is still what the running deployment
reads, and the 0.3.2 image parses it with its own baked-in copy of
`parse-targets.py` for `/target-sync`. Rewriting it in place would have broken the
live route the moment migrate ran. Every target carries over verbatim; the scope
becomes effort #1 with `credential_ref: default`, so no secret is copied and no
new file is created. A second `migrate` refuses cleanly.

`--name` is required: `system_id` is always a UUID here, so a derived name would
be `13c1f44e-…-soc2` — unreadable, and it is the stable identifier for the effort
and its agent. Asking is cheaper than living with it.

---

## Acceptance

### Credential-free (what CI runs)

| # | Gate | Result |
| --- | --- | --- |
| 1 | `parse-efforts.py --self-test` | **70/70**. Schema, duplicate effort names, duplicate system+framework pair, bad `credential_ref`, the reserved-`default` collision, **friendly-name `system_id` rejected**,
shared-target-identical **accepted**, shared-target-conflicting **rejected** on url/ref/private, every injection shape (`$(…)`, backticks, `;`, `|`, `../`, absolute paths, spaces, quotes, **leading `-`**), the credential ladder in both modes, and a real-bash field-order check. |
| 2 | `parse-targets.py --self-test` | **37/37**, unchanged. `list` and `scope` output byte-identical to the base commit — verified by diff, since `bootstrap.sh` depends on it. |
| 3 | `clawctl --self-test` | **38/38** against a stub `docker` that records argv. |
| 4 | `test-effort-credentials.sh` | **18/18** against a locally built amd64 image. |
| 5 | `efforts.example.yaml` | Valid and credential-free, asserted the same way `targets.yaml` already is. |
| 6 | `compose.efforts.yaml` merge | `docker compose config`: `openclaw` 7 mounts (5 base + 2), `cli` 5 (3 base + 2), secrets unchanged. Volume lists **merge** across files. |
| 7 | Existing suites | `sync-targets --self-test` 96/96, `pretorin-update --self-test` pass, `lint-heredocs` clean, `smoke.sh --no-creds` 168 pass / 1 fail — **that failure is pre-existing and environmental** (see below). |

**The one red row, and why it is not this change.** `smoke.sh --no-creds` fails
`bootstrap re-run succeeds`, because this host's working-tree `targets.yaml`
marks `fathom` `private: true` and the local PAT is refused by `git` (the same
PAT authenticates fine against the GitHub *API*). Established rather than
assumed: `bootstrap.sh` and `sync-targets.sh` are unmodified by this branch, the
refactored `parse-targets.py` produces byte-identical output to `master` for this
file, and **the identical failure reproduces on an unmodified `master`
worktree** with the same PAT. CI is unaffected: the committed `targets.yaml`
declares only the public `simple-crm`.

### Credentialed (isolated project, locally built amd64 image, real key)

Own Compose project (`cceffort`), own volumes, derived port `18993`, `down -v` at
the end. The operator's real deployment was never a target and was verified
untouched afterwards, stored context and all.

| # | Row | Result |
| --- | --- | --- |
| 8 | `clawctl validate` green against real efforts | **PASS**. Two efforts (`Fathom/soc2`, `Fathom/hipaa`), one table, all columns ok. |
| 8b | **Unattached framework rejected** | **PASS**. A third effort declaring `iso-27001` — a real framework this key can see, but not attached to Fathom — produced a `FAIL` row naming `attached here: hipaa soc2`, while the other two stayed green. Under the previous probe that row was green. |
| 9 | The CLEAR permission error | **PASS**. A third effort naming a system the key cannot reach produced a `FAIL` row naming the effort, the credential, the scope, what the platform said, and what to check in Pretorin — while the other two still reported ok in the same run. |
| 10 | `apply` onboards end to end with env pinning | **PASS**. Both efforts swept, bound, verified, provisioned and asserted clean. |
| 11 | A shared target binds into two scopes | **PASS**. One clone of `fathom`, **two distinct preflight artifacts**, each asserting `bound targets are exactly the declared set (1)`. |
| 12 | Effort A's sweep spares effort B | **PASS**. After re-applying `crm-soc2` alone, `crm-hipaa` still asserts `0 failure(s), 0 warning(s)` and both artifacts remain. |
| 13 | **THE WRITE GUARD** | **PASS** — evidence row #1, R2 and R3. Cross-scope write refused naming the ENVIRONMENT's scope; `allow_scope_override` byte-identically ignored. The positive control (the same write succeeding in its own scope with a declared write-enabled key) is **NOT run here** and stays behind an explicit flag, per the repo's `WRITE_POSTURE=unstated` rule. |
| 14 | Stored context is non-authoritative | **PASS, and more strongly than planned.** In the isolated project `context show` reported `active_system_id: null, valid: false` throughout — **both efforts onboarded completely with no stored context at all.** `clawctl` never runs `context set`. |
| 15 | A second `apply` refuses | **PASS**. Names the lock path and both plausible holders; `flock` carries no identity, so it does not pretend to know which. |
| 16 | The updater sees the same lock | **PASS**. Unmodified `pretorin-update.sh --status` reported `lock  HELD by a live update` while `clawctl`'s sidecar held it. One namespace, no edit to safety-critical code. |
| 17 | `kill -9` self-heals | **PASS**. After killing the sidecar, `--status` reported `lock  free` and a fresh `apply` proceeded. No lock-file deletion anywhere. |
| 18 | Suppressed repair | **PASS, with a control.** With a staged interrupted-update marker: lock held → no repair message and the **marker intact**; lock free → repair message and marker consumed. |
| 19 | The audit record | **PASS**. One line per effort per run, in the volume and in the logs, carrying the credential **name**; a grep for the real key value found nothing. |

### Four defects this testing found, which unit tests had missed

**1. `docker compose run` swallowed the loop's stdin, silently skipping every
effort after the first.** A real two-effort `validate` reported `1 effort(s)
checked`. This is the exact failure `onboard-targets.sh` documents — compose
attaches the caller's stdin even with `-T` — and `clawctl` reintroduced it in five
places. Fixed with `< /dev/null` on every invocation, and the self-test fixture
now carries **two** efforts. That regression test was itself wrong at first: a
stub `docker` that ignores stdin cannot reproduce the bug, and reported 38/38 with
the defect deliberately reintroduced. The stub now drains stdin exactly as compose
does, and the test was verified in **both** directions — 37/1 with the guard
removed, 38/0 restored.

**2. The lock-contention refusal printed the wrong message.** `--rm` removed the
busy sidecar before its logs could be read, so a genuine "someone else holds this"
surfaced as "the lock container exited before reporting". The lock container no
longer uses `--rm`; every path removes it explicitly.

**3. The credential-containment harness reported false passes.** With the image
unresolvable, every `docker run` printed a daemon error and three *absence*
assertions passed on a command that never executed. It now reads the image's real
platform, proves the launcher reached the probe before trusting any absence check,
and requires the launcher's own refusal text rather than mere silence.

**4. The credentials DIRECTORY was `chmod 700`, making every named credential
invisible inside the container — on Linux only.** `compose.secrets.yaml` mounts
individual *files*, so the directory above them never mattered.
`compose.efforts.yaml` mounts the *directory*, and a 0700 directory owned by the
host user cannot be traversed by the container's uid-1000 user: each credential
inside then reports "does not exist", which reads like a missing file rather than
a permission problem. It is the file-mode footgun one level up.

**Docker Desktop hid it.** macOS bind mounts are presented as owned by the
container user, so 0700 worked locally and every local run passed. **CI caught
it**, on the first push. The directory is now 0701 when the host uid is not 1000
— traverse only, since the launcher opens a known path and never enumerates — and
the self-test asserts the directory mode next to the file mode. A local macOS run
cannot verify this fix; Linux CI is the only place it is meaningful.

None of these would have been caught by the schema self-test alone. They are the
argument for the credentialed and runtime rows existing at all — and #4 is the
argument for CI running on Linux rather than trusting a developer's laptop.
