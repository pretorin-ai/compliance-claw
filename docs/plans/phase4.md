# Phase 4 — targets, onboarding, and the CWD fix

Goal: connect repositories mounted in OpenClaw to the compliance intelligence Pretorin already
provides. Phase 4 adds only that layer — a target declaration, host bootstrap, operator onboarding,
the working-directory fix, and the test/CI harness. No second "Compliance Claw" skill, no duplicated
Pretorin logic, no version bump past 0.26.14.

**Status: IMPLEMENTED and validated.** 63 of 64 checks pass, including the full credentialed
integration test against a real read-only key. The one skip needs model credentials this deployment
does not have. Results in "Validation" below.

## Established facts, discovered from the shipped 0.26.14 binary

Not from newer docs and not from the 0.26.15 tree. Offline first — everything here ran with **no API
key at all**:

| Fact | Evidence |
| --- | --- |
| `preflight init --workspace <p>` binds correct defaults for that path and **ignores CWD** | run from CWD `/app`: `code_repository` → `{marker:".git", path:"/workspace/targets/simple-crm"}`, capabilities `repository_inventory, source_configuration, commit_history` |
| It is **idempotent — upsert by resolver name** | two inits of the same workspace → one resolver |
| It **accumulates** across targets, so N targets give N symmetric resolvers | init A then B → `['simple-crm','second']` |
| `--replace` wipes the collections of every kind it detects | after `--replace`, `second` was gone — **never use it in the loop** |
| `preflight bind` **appends duplicates**, even for the same name | rejected as the binding mechanism |
| `unbind --name X` removes **every** resolver named X; an absent name exits 1 | `Unbound 2 resolver(s) named 'a'` |
| `verify` and `provision --apply` need no key | `2 kinds ● 2 ready`; `Seeded active set with 12 recipe(s)` |
| The whole sequence works against the **read-only** mount | green against a real `:ro` clone |
| `pretorin --json preflight show` emits the entire artifact | the assertion primitive for everything below |
| State is `~/.pretorin/preflight/preflight_<system>_<framework>.json` | **outside** `~/.openclaw`, which forces a second volume |
| `preflight init` with **no** `--workspace` binds the CWD unconditionally, even an empty non-git directory | at `/app` → a resolver named `app` → `/app` |

With a real read-only key (`Test system` = `7b74d8f3-…`, which exists under `cmmc-l1`,
`dod-cloud-il5` and `soc2` — three separate scopes, which is why the framework must be explicit):

| Fact | Evidence |
| --- | --- |
| A **read** key is enough for the platform profile | `Seeded platform recommendations for` 26 source kinds (soc2) |
| `init` also binds **8 `pretorin_feature` resolvers with no `params.path`** | System Specification, Policy Management, GRC, Evidence and Attestation, Scope Profile, Control Issues, Vendor Management, Evidence Repository |
| Two resolvers can **share a name** across different paths | `document_repository` held two named `docs`: `<target>/docs` and `/app/docs` |
| `code_repository` is **`degraded`, not `ready`**, and that is correct | missing `branch_protection, code_review_records, pull_request_records` — platform-side capabilities a local checkout cannot supply |
| `provision --apply` seeded 12 recipes; 17 of 26 recommended kinds are unmapped | expected for a repos-only POC, reported as coverage gaps rather than failure |
| The platform gates evidence work separately | `Scope is not approved with a confirmed scale yet; complete and approve scope setup on the platform before evidence work` — an operator prerequisite on platform.pretorin.com |
| `whoami` exposes **no scope field** | `{authenticated, api_key (masked), api_url, frameworks_available}` → key mode cannot be detected, only declared |

## The CWD fix

`mcp.servers.<name>.cwd` is a **native OpenClaw property** (`openclaw mcp add --cwd` → "Working
directory for stdio server"), so no launch wrapper and no primary-target workdir convention were
needed. Proven by reading `/proc/<pid>/cwd` of the live child, with a control:

```
with    cwd:"/tmp/norepo"   →  pid=87 cwd=/tmp/norepo   cmd=[/usr/local/bin/pretorin mcp-serve]
without (the Phase 3 config) →  pid=86 cwd=/app          cmd=[/usr/local/bin/pretorin mcp-serve]
```

One line is not enough, because a bare `preflight init` binds whatever the CWD is — even an empty
directory. Three layers:

```
  1. REDIRECT   mcp.servers.pretorin.cwd = /opt/compliance-claw/no-repo
                image-baked, node-owned, one .txt notice: no .git, no .md, no code.
                Anything CWD-derived now lands somewhere obviously wrong and named
                `no-repo`, instead of somewhere plausible and named `app`.

  2. NEVER RELY on it — onboarding always passes --workspace /workspace/targets/<name>.

  3. SWEEP + ASSERT   every run removes foreign path resolvers and then proves none
                remain. /app cannot survive an onboarding run, and a run that cannot
                clean it fails loudly instead of reporting success.
```

### Onboarding order is load-bearing: sweep, THEN bind

`unbind --name` removes every resolver with that name, and names come from the directory basename — so
a target's own `<target>/docs` resolver and a stray `/app/docs` resolver are both called `docs`.
Binding first and sweeping second deletes the legitimate one as collateral. Sweeping first makes that
impossible by construction: nothing that belongs here exists yet when the blunt instrument runs, and
step 4 re-creates it.

The sweep considers **only resolvers that have `params.path` pointing outside `/workspace/targets`**.
This is not a refinement, it is the difference between working and destructive: with a real key the
artifact holds 12 resolvers, **8 of which have no path at all**. A path-blind sweep destroys every
`pretorin_feature` resolver the platform profile just bound.

```
1. pretorin --json whoami                                      fail fast on a bad key
2. pretorin context set --system <sid> --framework <fid>        platform read; what the AGENT reads
3. SWEEP    --json preflight show → unbind each (kind,name) owning a foreign params.path
4. BIND     per target: preflight init --workspace /workspace/targets/<name> --no-verify
5. pretorin preflight verify                                   probes run locally
6. pretorin preflight provision --apply                        seed the active recipe set
7. ASSERT   per resolver, never per kind
```

Assertions are **per resolver** — path exact, `last_result.status == "connected"` — and never
`kind.status == "ready"`, because `degraded` is the correct steady state for a local checkout. The
`--verify-only` output says so in words, so an operator does not read it as breakage.

**Sequencing against a live gateway.** Onboard before `up`. The artifact carries `ttl_seconds: 3600`
and each session keeps its own `pretorin mcp-serve` child (`mcp.sessionIdleTtlMs`, 10 minutes), so
onboarding under a running gateway can be served the older view. Remedy, documented in three places:
`openclaw mcp reload`, or restart.

## Changes

| File | Change |
| --- | --- |
| `targets.yaml` | New. `system_id` + `framework_id` for the whole file, then one or many `{name, url, ref?}`. Committed with working values so a fresh clone is reproducible; comments say both are deployment-specific. `simple-crm` is the example, named nowhere else. |
| `scripts/parse-targets.py` | New. Strict parser for the documented YAML subset, **stdlib only** — Apple's `/usr/bin/python3` has no PyYAML (a local `import yaml` that works is a user site-install). `--self-test` runs 29 cases. |
| `scripts/bootstrap.sh` | New. Host preflight, clone/update targets, write `.env` if absent, build, confirm the built image is x86_64. |
| `scripts/onboard-targets.sh` | New. The sequence above, driving `docker compose run --rm -T cli` and echoing every command. `--verify-only` is the single implementation of the invariant; `--local-only` skips the platform steps. |
| `scripts/mcp-call.py` | New, in-image. One MCP tool call over `pretorin mcp-serve` stdio, with exit 3 reserved for "the server returned isError" so a rejection can be told apart from a transport failure. |
| `scripts/smoke.sh` | New. Section A no-credential (what CI runs), Section B credentialed and self-skipping. |
| `scripts/openclaw-config.template.json` | Adds `cwd`; a comment on `mcp.sessionIdleTtlMs` (default 600000, milliseconds, 10 min, `0` disables idle cleanup, untuned). `toolFilter` still commented out. |
| `scripts/agents-md.template` | One target at a time, provenance on every piece of evidence, resolvers are operator-owned. Nothing about compliance behaviour. |
| `scripts/entrypoint.sh` | Writes the template-version sidecar on a fresh seed; warns on stderr when the volume is behind. Never overwrites. |
| `Dockerfile` | Creates the `no-repo` sentinel and `/home/node/.pretorin` node-owned, copies `mcp-call.py`, bakes `CONFIG_TEMPLATE_VERSION`. |
| `compose.yaml` | `pretorin-state` volume on both services via the existing anchor; reset semantics in the header. |
| `versions.env` | `CONFIG_TEMPLATE_VERSION=2`. |
| `.env.example` | Read-only is the default and is sufficient; write-enabled is an explicit opt-in. Adds `PRETORIN_KEY_MODE`. |
| `README.md` | New. Minimal operator quickstart; Phase 5 owns full docs. |
| `.github/workflows/build.yml` | New. Native amd64 build, `bootstrap.sh` then `smoke.sh --no-creds`, plus a guard that fails if `.env` ever contains a key. |

`.dockerignore` needed no change, and it correctly keeps `targets.yaml` out of the build context —
deployment config must not be baked into an image.

### Why `~/.pretorin` needs its own volume

Onboarding runs in `docker compose run --rm cli`, a container that exits. Pretorin's active context,
resolvers and active recipe set live in `~/.pretorin`, which is **outside** the `openclaw-state`
volume, so without a second volume every onboarding run would evaporate with the container that
performed it and the gateway would never see it. The directory is created node-owned in the Dockerfile
for the same reason `/workspace/targets` is: Docker creates a missing mount point as root.

### Stale-template handling (warn only)

A sidecar `~/.openclaw/.compliance-claw-templates` holding an integer, compared against
`CONFIG_TEMPLATE_VERSION` baked into the image. Chosen over a JSON5 comment in the config because it
needs no parsing, covers `AGENTS.md` too, and is not an OpenClaw config property that could be
rejected as unknown. A fresh seed writes it; an existing config with a missing, older or non-numeric
marker warns on every invocation and nothing is ever edited. Escape hatch after a manual merge:
`echo 2 > ~/.openclaw/.compliance-claw-templates`. A volume with no marker reads as 0, which is every
Phase 3 deployment — observed live during this phase, warning and all.

### Reset semantics — the exact claim

> `docker compose down -v` deletes **both** named volumes: the OpenClaw state volume (config,
> sessions, agent workspace, custom `AGENTS.md`) **and** the Pretorin state volume (active context,
> preflight resolvers, active recipe set). It does **not** touch the bind-mounted target repositories
> under `workspace/targets`. Recovery is re-running `scripts/bootstrap.sh` and
> `scripts/onboard-targets.sh`; both are idempotent.

Verified directly: after `down -v`, `.env` and `workspace/targets/simple-crm` at `276b5fd` were both
still present, and the next `bootstrap.sh` re-seeded config and `AGENTS.md` with no warning.

## Validation — observed results

`docker compose down -v` first, so every seeding path ran fresh. `scripts/smoke.sh` → **63 pass,
0 fail, 1 skip**.

### Section A — no credentials (what CI runs): 51 checks

| Group | Result | Observed |
| --- | --- | --- |
| A1 versions | pass | `pretorin version 0.26.14`, `OpenClaw 2026.7.1`, image `x86_64` |
| A2 MCP surface | pass | `mcp-smoke-test` → `PASSED` |
| A3 parser | pass | `parse-targets self-test: all 29 cases pass` |
| A4 gateway + seeding | pass | `/healthz` ok; `8 plugins` with `codex` absent; config and `AGENTS.md` seeded; marker written at v2; config contains the `cwd` line |
| A5 mount posture | pass | targets `ro`, both state volumes writable, uid `node` |
| **A6 the CWD fix** | **pass** | live child: `CHILD_CWD=/opt/compliance-claw/no-repo`, never `/app`; sentinel holds no `.git` and no `.md` |
| A7 stale-template | pass | older / corrupt / missing marker each warn; current marker silent; the command still works with a corrupt marker; config md5 unchanged across all of it |
| **A8 onboarding, no key** | **pass** | `/app` present before, absent after; both foreign resolvers swept; target bound; the `cli_tool` resolver survived; `--verify-only` clean; re-run idempotent at 3 resolvers |
| A9 bootstrap refusals | pass | origin mismatch refused naming both URLs; broken clone refused, explicitly not deleted, and still present afterwards |
| A10 bootstrap idempotency | pass | re-run keeps `.env` byte-identical, fetches instead of cloning, mode 600 |

### Section B — credentialed, read-only key: 12 checks

| Check | Result | Observed |
| --- | --- | --- |
| B1 onboarding completes | pass | `Seeded platform recommendations` for 26 kinds; `active context set and valid` |
| B2 state is exactly `targets.yaml` | pass | `simple-crm: /workspace/targets/simple-crm connected`; `no resolver points outside /workspace/targets/`; `degraded — EXPECTED for a local workspace`; 12 active recipes; `0 failure(s), 0 warning(s)` |
| B3 read tool through MCP | pass | `list_frameworks` → `{"total": 28, …}` |
| **B4 write tool rejected server-side** | **pass** | `Error: Authentication failed: Access denied: Missing required scopes: write` — the request was otherwise valid, so only authorization can explain it. Also independent proof the key really is read-only. |
| B5 mount posture with credentials | pass | targets still `ro` |
| B6 agent turn provenance | **skip** | no model credentials in this deployment; classified as a provider-auth skip rather than a failure |

### Fresh-clone gate

Tracked files copied to a clean directory with no `.env` and no `workspace/`, isolated with
`COMPOSE_PROJECT_NAME` (documented to override the file's `name:`), then the CI sequence exactly:

```
bootstrap.sh   → exit 0 in 7.4s: emulation probe ok, cloned simple-crm at 276b5fd,
                 wrote .env mode 600 with a generated token, built, image reports x86_64
smoke.sh --no-creds → 51 pass, 0 fail, credentialed section skipped cleanly
```

### Four bugs found by running the gate, not by reading the code

Worth recording because three are general shell hazards, not project quirks:

1. **`docker compose run` inside `while read` ate the loop's own stdin.** The sweep unbound only the
   first of two foreign resolvers — `/app` went away, `/app/docs` silently stayed. `-T` does not
   detach stdin; `< /dev/null` on the wrapper is what fixes it. This is the bug the phase exists to
   prevent, surviving inside the fix for it.
2. **`python3 - <<'EOF'` cannot also receive piped data.** With `python3 -` the interpreter reads the
   *program* from stdin, so the artifact JSON never arrived and every assertion reported "no preflight
   artifact". The analysis program is now written to a temp file and run as `python3 FILE`. The
   accompanying fix matters more: unparseable input is now a loud error, because treating it as "no
   artifact" turns a broken pipeline into a confident, wrong verdict about the deployment.
3. **`git rev-parse --git-dir` searches parent directories.** An empty `workspace/targets/<name>`
   inside this repository answered with *compliance-claw's* `.git`, so a broken clone looked like a
   valid clone with the wrong remote. The test is now `--show-toplevel` equal to the directory itself,
   which is the documented question being asked.
4. **Merging stderr into a captured value.** Compose writes lifecycle lines and the entrypoint writes
   its messages to stderr; `2>&1` on a value capture compared a version number against a container
   id. Split into `cli` (assert on output) and `val` (extract a value).

Also fixed while validating: a quoted scalar with a trailing comment kept the comment (the parser
unquoted at end-of-line instead of at the closing quote), and an apostrophe inside a heredoc nested in
`$( )` breaks bash 3.2's parse of the enclosing substitution.

## Acceptance

A fresh clone reaches a running, onboarded deployment with one script and one key. Bootstrap is
idempotent and never clobbers a clone or a `.env`. Every target in `targets.yaml` is bound to
`/workspace/targets/<name>` with an explicit workspace, `/app` is provably absent from the artifact,
and nothing depends on the MCP process's working directory. A read-only key is sufficient throughout,
and a write tool is refused by the platform. Targets stay read-only in-container. CI proves all of the
above with no credentials.

## Accepted limitations

- **`code_repository` stays `degraded`.** `branch_protection`, `code_review_records` and
  `pull_request_records` are platform-side; a local checkout cannot supply them. Connected Sources is
  the fix, and it is future work.
- **Document resolvers collide by basename.** Two targets that both own `docs/` produce two resolvers
  named `docs`, and one silently replaces the other. Onboarding warns; the real fix needs explicit
  `--name` binding with hand-authored capability metadata.
- **The sweep is name-scoped, not id-scoped**, because 0.26.14 has no `unbind --id`. Sweep-then-bind
  makes that safe rather than merely tolerable, but it does mean a foreign resolver sharing a name
  with a legitimate one is removed and re-created rather than left alone.
- **Onboarding is one container per command** (three fixed plus one per target plus two reads). Under
  emulation that is roughly 30–50 seconds for a single target. A generated in-container loop would be
  several times faster and much less transparent; transparency wins at POC scale.
- **`PRETORIN_KEY_MODE` is a declaration, not a check**, because `whoami` reports no scopes. It only
  gates whether the smoke test attempts a write, so a mislabelled write key means that one probe is
  skipped, never that a record is created by accident.
- **Evidence work needs platform-side scope approval** (`Scope is not approved with a confirmed scale
  yet`), which is outside this repository.
- **The credentialed agent-turn check is unproven here.** It is implemented and self-skipping; it needs
  an OpenAI device-code login in the state volume.

## Future work

- **Connected Sources (`source_admin`)** as the eventual source of truth for repository bindings, and
  the only path to `branch_protection` — i.e. the thing that resolves `degraded`. Requires a scope this
  POC deliberately does not use. No platform-side source management was built here.
- **Upstream feedback:** `pretorin preflight unbind --id <resolver-id>` would make sweeps precise and
  retire the sweep-then-bind ordering constraint entirely.
- **Write opt-in**, explicitly: evidence upload and platform record changes stay behind an operator
  decision to use a write-enabled key, and need user-level attribution and RBAC before any shared
  channel.
- **Private and SSH target repositories** — `bootstrap.sh` is https-only and fails closed with
  `GIT_TERMINAL_PROMPT=0` rather than hanging on a prompt.
- **Per-repository authorization.** Every target currently shares one key and one scope.
- **Docker file-based secrets** instead of `env_file`, to keep both credentials out of
  `docker inspect`.
- **Config reconciliation** rather than warn-and-`down -v`.
- **Per-target document-resolver naming**, per the limitation above.
- **GHCR publish and attestation verification** for the image itself.
