# Target synchronization, and a PAT fallback for private repositories

Goal: let an operator bring a review target up to date from Slack — `update the
simple-crm target` — and let a private target be synchronized from inside the
container, which the GitHub App path cannot do because the App key is host-only.

Every earlier convention stands: write-if-absent seeding, never-clobber,
refusals that name the fix, CI holding zero credentials, isolated test projects
on derived ports.

**Status: IMPLEMENTED, validated locally, NOT released.** Two things are
deliberately **not** claimed as passed, and are listed under *Blocked on
operator* at the end: a real Slack round trip, and a real private clone over
HTTPS with a fine-grained PAT.

## What was wrong

`bootstrap.sh` fetched a target and then, when `targets.yaml` declared no `ref`,
**moved nothing** — the old code only fast-forwarded inside `if [ -n "$REF" ]`.
The run still printed a SHA, so a stale target looked like a fresh one. Nothing
outside the host could move a target at all.

## Established facts, measured against the shipped artifacts

| Fact | Evidence |
| --- | --- |
| **`git` is already in the runtime image** | `/usr/bin/git`, `git version 2.39.5`, `git-remote-https` present, and a real `git clone https://github.com/pretorin-ai/simple-crm.git` succeeded — all run against the pinned digest `0.2.2@sha256:e47adba4…`. No `apt-get` was added and the runtime attack surface is unchanged. |
| The Dockerfile's "no `.git`" comment is about the **sentinel directory**, not the binary | [Dockerfile:192](../../Dockerfile#L192) — it says the `no-repo` directory contains no `.git`, so Pretorin's CWD discovery finds nothing there. |
| A missing file-secret **fails the start**, it does not warn | `up -d openclaw` with `github-readonly-pat` absent: `invalid mount config for type "bind": bind source path does not exist`. The container is never created. |
| …but `docker compose config` renders it happily | no error, no warning, exit 0. So `config` cannot stand in for that failure in a test. |
| `openclaw config patch` **replaces** arrays | already recorded in [cli-self-update.md](cli-self-update.md); re-verified here — the Slack-patched config carries `allow: [slack, pretorin-update, target-sync]` and all three `load.paths` only because both arrays name all three. |
| Object keys under `plugins.entries` **merge** rather than replace | the patch sets only `slack`; the rendered config still has all three entries. |
| A YAML merge key **replaces** a service's `volumes:` list | writing only the two new mounts on `openclaw` silently dropped both state volumes and the read-only target mount. Caught while building this; see *Mounts*. |
| `git remote get-url` applies `url.*.insteadOf` | so the origin check compares the URL git will **actually contact**, not the raw config value. It also means an `insteadOf` redirect cannot be used to fake an origin in tests. |

## Design 1 — one implementation, three callers

```
                       scripts/sync-targets.sh
                    ┌──────────────────────────────┐
 bootstrap.sh ─────►│ --bootstrap   clone-or-update│  host: GitHub App, else PAT
                    │                              │
 /target-sync ─────►│ all | <name>  fast-forward   │  container: PAT file only
 target_sync  ─────►│               only           │
                    │                              │
 --self-test  ─────►│ drives THESE functions       │  no network, no credentials
                    └──────────────────────────────┘
```

There is no second copy of the fetch/fast-forward logic, and the self-test drives
the production functions rather than a re-implementation — so a test passing is
evidence about the code that runs in Slack.

`bootstrap.sh` keeps only what is host-only by nature: deciding which credential
exists, and minting the GitHub App token.

## Design 2 — what a request can say

Exactly `all`, or the name of a target already declared in `targets.yaml`.

Validation is a **character allowlist first** (`[A-Za-z0-9._-]`, no leading `-`
or `.`), then membership via `parse-targets.py` — the same parser the host uses,
rather than YAML re-parsed in bash. A structure check alone would let
`simple-crm\n--upload-pack=x` through on the strength of its first line; that
defect was found once already by the CLI updater's self-test and is not
rediscovered here.

No URL, ref, path, flag or shell fragment is expressible. Nothing can add,
remove, rename, re-point or onboard a target — that stays an operator action on
the host.

## Design 3 — safe by construction

The only ref-moving operation in the file is `merge --ff-only`. There is no
`reset`, no force checkout, no `stash`, no `clean`, no branch switch and no
delete anywhere on the sync path.

Before a fetch, a target must satisfy **all** of: the clone exists and is a
repository root; `remote get-url origin` equals the declared URL; the tree is
clean; HEAD is on a branch; that branch is the declared `ref` when one is
declared; and its upstream is exactly `origin/<branch>`. `ref` is validated as a
*branch name* — the character allowlist plus `git check-ref-format
refs/heads/<ref>`, prefixed so the value can never be read as an option.

Every git invocation carries `core.hooksPath=/dev/null` (a reviewed repository is
untrusted input and does not get to execute code), `safe.directory=<abs dest>`
(the bind-mounted clone is owned by the host user, not the container uid), and
`http.lowSpeedLimit/lowSpeedTime` as the network timeout — git's own mechanism,
because `timeout(1)` is not on stock macOS. `GIT_TERMINAL_PROMPT=0` throughout.

### Outcomes

| Outcome | Meaning | Moves anything? |
| --- | --- | --- |
| `updated` | fast-forwarded; both SHAs reported | yes, forward only |
| `already_current` | remote equals HEAD | no |
| `dirty_refused` | working tree not clean | no |
| `detached_refused` | HEAD is not on a branch | no |
| `no_upstream_refused` | upstream missing or not `origin/<branch>` | no |
| `branch_mismatch_refused` | on a different branch than `ref` declares | no |
| `origin_mismatch_refused` | origin is not the declared URL | no |
| `diverged_refused` | local commits the remote lacks, or rewritten history | no |
| `missing_clone` | nothing there — says to run `bootstrap.sh` | no |
| `auth_failed` | remote refused the credential; names both fixes | no |
| `invalid_target` | not declared, or malformed input/ref | no |
| `targets_unreadable` | the target list could not be parsed at all | no |
| `sync_failed` | anything else (network, ref gone upstream) | no |
| `sync_already_running` | the global lock is held by a live owner | no |

`all` runs **sequentially**, continues past a failure, returns a line for every
target, and exits non-zero if any failed. No parallel git.

Output is machine-readable on stdout (`RESULT\t…`, `SUMMARY\t…`) and human on
stderr, so the plugin parses one and the operator reads the other.

### The lock

One non-blocking global lock, a `mkdir` lock directory under the targets
directory — atomic on POSIX, and `flock(1)` is absent on stock macOS. It is
global in the real sense: the host directory `bootstrap.sh` writes is the same
directory the container sees through its maintenance mount, so host and
container contend for the same lock. A held lock returns `sync_already_running`
immediately rather than waiting, because a Slack request that waits looks hung.

A lock is reclaimed **only** when its owner is provably gone: the owner file
records `pid` and a namespace token (the kernel boot id inside a container, the
hostname on macOS), and the lock is taken over only if the namespace matches
*and* `kill -0` says the pid is dead. A live owner, a different namespace, a
malformed owner file or a missing one all leave the lock alone — guessing that
another process is dead is how two gits end up in one working tree. Every
reclaim is announced in the log, never silent.

That branch exists because of a measured failure, not a hypothetical: the plugin
bounds the wrapper with a timeout, and the original SIGKILL ran no `EXIT` trap,
so **one timeout wedged synchronization permanently** — every later request, from
anyone, answered "another synchronization is in progress" against a pid that had
not existed for hours, clearable only by an operator with a shell. The plugin now
signals the whole **process group** with SIGTERM and escalates to SIGKILL only
after a grace period, so the trap normally runs and no git child outlives its
parent; the reclaim is the second line of defence for when even that is not
enough.

## Mounts, and an honest boundary

| Path | Service | Mode | For |
| --- | --- | --- | --- |
| `/workspace/targets` | both | **ro** | assessment — every evidence citation |
| `/var/lib/compliance-claw/targets` | openclaw only | rw | the synchronizer |
| `/etc/compliance-claw/targets.yaml` | openclaw only | ro | name validation |

Both target paths are the same host directory. `targets.yaml` is mounted under
`/etc/`, deliberately **not** under `/opt/compliance-claw/`, because the
`pretorin mcp-serve` child runs with cwd `/opt/compliance-claw/no-repo` and
Pretorin derives host-local source resolvers from the current directory. Smoke
asserts that no `targets.yaml` and no `.git` exist anywhere under that tree, and
that the sentinel cwd is unchanged.

> **This is not a security boundary.** It is process-level separation inside one
> container. The wrapper runs as `node`; so does the agent's unsandboxed tool
> execution. A prompt-injected agent can write to the maintenance path and read
> the PAT file directly. What the split does buy is that the *assessment* path —
> the one the agent is instructed to use, and the one every evidence citation
> comes from — stays read-only, so an accidental write fails instead of silently
> succeeding. A real boundary is a separate container with its own uid, and it is
> deliberately out of scope for the pilot.

## The credential ladder

```
public target                  → anonymous, no credential consulted
private + GitHub App           → mint an installation token.  IF THAT FAILS, STOP.
private + no App + PAT file    → use the PAT, and say so on every run
private + neither              → refuse, naming both fixes
```

There is deliberately **no fall-through from a broken App to the PAT**. An
operator who configured an App expects the App; quietly substituting a
longer-lived personal credential is a downgrade nobody notices. Smoke asserts
this with a PAT sitting right there, unused.

The PAT is a **fine-grained, selected-repositories, Contents: Read-only** token
in `secrets/runtime/github-readonly-pat`, mounted read-only on the gateway only.

**It is the one secret with no `_FILE` environment variable, and that is the
point.** Every other secret is read by the entrypoint and exported into PID 1,
which the agent's tool execution inherits. The PAT is consumed by a git
credential helper that reads the file at the moment git asks, so it never
becomes an environment variable and is deliberately absent from the entrypoint's
`load_secret_file` list. Smoke asserts that no `GITHUB_READONLY_PAT_FILE`
appears on either service.

Be honest about what that buys: it keeps the token out of `docker inspect`, out
of every child process's environment, and out of anything that dumps `env`. It
does **not** put it out of reach of a prompt-injected agent. The real containment
is on GitHub's side — fine-grained, selected repositories, read-only — and the
GitHub App remains the recommended mechanism past the pilot.

### The relaxed invariant, said out loud

`bootstrap.sh` used to open with *"GIT CREDENTIALS NEVER LEAVE THIS HOST."*
That is no longer true and the header now says so, as do README and SECURITY.
What still holds: the App private key and the tokens it mints stay host-side,
out of every container. What changed: a PAT now lives inside the container,
because synchronizing a private target from Slack requires a credential there.

## Upgrade safety

Adding a `secrets:` entry makes `up` fail for any deployment without the file —
measured, not assumed (see the fact table). So:

- `init-file-secrets.sh` creates it write-if-absent, **empty**. Empty means "no
  PAT", not "a PAT that is the empty string".
- `bootstrap.sh` already runs that on the file-secret path.
- `update.sh` runs it **after the fast-forward and before anything stops**, and
  if it cannot, it exits with the deployment still running and the exact command
  named. Smoke asserts the guard precedes `docker compose up -d` in the file.
- Smoke asserts `init-file-secrets.sh` creates exactly the set of files
  `compose.secrets.yaml` declares, read out of the overlay itself — so the next
  release to add a secret cannot reintroduce this.

## Two defects found in review, and what they cost

Both were silent, both passed a green suite, and both are now regression cases.

**1. A failing parser was reported as a clean run.** The target list was read
through a process substitution — `done < <(target_list)` — whose exit status is
unobservable, so a parser that died produced an empty stream and the loop simply
ended. `all` answered `SUMMARY total=0 failed=0 overall=ok`, exit 0: a sync that
examined nothing and called it success, leaving every target stale. A *named*
request was worse — the membership test found no names, so the operator was told
`'simple-crm' is not declared in targets.yaml` and sent to edit a file that was
perfectly fine. The list is now materialised and its status checked before
anything iterates it; failure is `targets_unreadable`, exit 1, in both modes.

**2. A timeout wedged synchronization forever.** Described under *The lock*
above. Fixed on both layers — graceful process-group termination in the plugin,
provable-death reclaim in the wrapper — with the no-steal properties (live owner,
foreign namespace, unreadable owner file) each gated separately.

A third, found while fixing the second: the stale-lock check originally read the
owner file with `sed 's/.*\bkey=…'`. `\b` is a GNU extension that **BSD sed does
not support**, so on macOS — this POC's operator platform — every field came back
empty, the check concluded "cannot judge", and it never reclaimed anything. It
looked conservative and was simply broken. Now `awk`, with whole-token matching.

## A fresh-deployment defect found while validating this branch

Not caused by target sync, but found by running a genuinely fresh deployment for
it, and fixed here because it makes Slack unusable on first install.

**Symptom.** A brand-new file-secret deployment came up with Slack credentials
present and Slack absent from the config — permanently, because seeding is
never-clobber. The only evidence was that `openclaw.json` was ~35 seconds older
than the gateway container.

**Chain.**

1. the operator exports `compose.yaml:compose.secrets.yaml:compose.build.yaml`
2. `bootstrap.sh --build` did `export COMPOSE_FILE="compose.yaml:compose.build.yaml"`
   — an unconditional replacement that dropped the overlay mounting the Slack tokens
3. its architecture check ran `docker compose run --rm -T cli uname -m`, which
   starts a container, runs the entrypoint and mounts the real state volume — so
   a question about CPU architecture **seeded the configuration**
4. that seed could not see the Slack tokens, so it wrote a Slack-less config
5. the gateway started later *with* the tokens, found a config, and correctly
   refused to overwrite it

**Fix, both halves minimal.** `--build` now appends `compose.build.yaml` only
when absent and never rebuilds the variable; the architecture check is
`docker image inspect` on the image `docker compose config` names — no
entrypoint, no container, no volume, no seed, no network. The entrypoint is
unchanged: never-clobber was behaving correctly and is not the thing to loosen.

**Why nothing caught it.** `test-file-secrets.sh` points bootstrap at an
unreachable target, so it dies at the clone and never reaches the image phase;
smoke's Slack rows invoke the image with `docker run`, bypassing bootstrap,
Compose and `COMPOSE_FILE`. Each was right about its own subject; the defect
lived in the interaction. `scripts/test-fresh-slack-seed.sh` now covers exactly
that region, plus two static guards in smoke.

## Validation

**`scripts/sync-targets.sh --self-test` — 96 checks, offline, no credentials.**
Runs in CI as its own step and twice in smoke (host copy and image copy).

- 22 refused inputs: option-shaped, injection-shaped, traversal, embedded
  newline, URLs, `all extra`, empty
- 17 branch-name cases including `--upload-pack=x`, `a..b`, `a@{1}`, `a.lock`
- `updated` with correct previous/resulting SHAs; `already_current` as a true
  no-op; **no-`ref` follows the tracked upstream** (the regression above); a
  non-default branch (`release/1.x`) honoured
- every refusal outcome, each asserting HEAD did not move — and for `dirty`,
  that the local edit still exists
- credential canary: the helper does hand the token to `git credential fill`,
  and the token then appears in no output, no message, no `.git/config`, no
  remote URL, no audit line, nowhere under `.git`
- the global lock: taken, refused on re-entry, reusable after release
- `all`: 3 targets, 2 updated, 1 refused, all three reported, the failure not
  stopping the ones after it
- a failing parser and an empty list both refused, with the parser's own words
  carried through
- the stale lock: reclaimed when the owner is provably dead; **never** stolen
  from a live owner, from another namespace, or when the owner file is missing

**`scripts/smoke.sh --no-creds` — 159 pass, 1 fail, 1 skip, 1 note.**
Isolated project `ccsync`, derived port 18993, live deployment untouched.

The single failure is `.env carries a gateway token (legacy path)` — **pre-existing
and environmental**, not caused by this change: the check is byte-identical to
`origin/master`, and it fails only because this machine's `.env` belongs to the
file-secret path while the overlay under test selects the legacy one. It passes
in CI, where `bootstrap.sh` writes a fresh `.env` with a generated token, and it
passed here on the file-secret path.

New rows include: both plugins active in both profiles (`10 plugins` without
Slack; exactly `pretorin-update, slack, target-sync` under the exclusive
allowlist); the sync plugin loading with its tool registered; the mount matrix
asserted in both directions; the gateway refusing option/injection/unknown input
through the real container; the sentinel invariant; the full credential ladder
including the no-silent-downgrade case; and the upgrade repair.

**End to end, in the running gateway container:**

```
$ docker compose exec openclaw /opt/compliance-claw/sync-targets.sh simple-crm
RESULT   simple-crm  already_current  276b5fd8…  276b5fd8…  simple-crm is already at 276b5fd on main.
SUMMARY  total=1  updated=0  failed=0  overall=ok            exit 0

$ …with the lock held by another owner
RESULT   all  sync_already_running  -  -  another synchronization is in progress …
SUMMARY  total=0  updated=0  failed=0  overall=busy          exit 3
```

The audit line lands in `docker compose logs` and in
`/home/node/.pretorin/target-sync-audit.log`, carrying target, outcome, both
SHAs, credential *source* (never the value), requester and route.

## Blocked on operator

- **A real Slack round trip.** Needs credentials and a live workspace. Push a
  commit to a public target, `/target-sync simple-crm`, confirm the reply shows
  `old → new`, then ask the Claw to read the new HEAD content — which should
  work with **no gateway restart**, since the resolvers bind paths and the mount
  is live. Repeat in plain language to exercise the tool route.
- **A real private clone over HTTPS with a fine-grained PAT.** The self-test
  proves the credential path and the absence of leaks against a local remote; it
  cannot prove GitHub's side of the handshake. Sweep afterwards for the token in
  logs, `git remote -v`, every `.git/config`, the audit file and `openclaw.json`.

## Deferred, deliberately

A sidecar or separate-uid container for the synchronizer (the only thing that
would make the mount split a real boundary); adding or onboarding targets from
chat; any restart/reload on sync (not needed — measured); parallel git; a
watcher, poller or scheduler.
