# Repository access and synchronization

This guide owns how review targets are declared, how private repositories are
reached, and how clones are kept up to date. Run every command from the
repository root. Effort declarations themselves are in the
[effort guide](efforts.md); credential files are in the
[secret guide](file-secrets.md).

## Declaring targets

Each effort in `efforts.yaml` declares its targets with the same per-target
fields shown in the legacy format below: `name` (becomes the directory name),
`url`, an optional `ref`, and an optional `private` flag. `scripts/bootstrap.sh`
clones each target into `workspace/targets/<name>`, which Compose bind-mounts
**read-only** at `/workspace/targets`. Adding, removing or re-pointing a target
is a host action: edit `efforts.yaml`, then run `scripts/clawctl apply`.

## Legacy `targets.yaml` (single effort)

> This is the single-effort format. It is still the shape `scripts/clawctl
> migrate` reads, and the per-target rules below are unchanged in `efforts.yaml`,
> but `efforts.yaml` takes precedence on the multi-effort path. `targets.yaml`
> remains mounted for the legacy target-sync fallback. A multi-effort deployment
> declares its targets under each effort in `efforts.yaml`.

```yaml
system_id: 7b74d8f3-d77c-49e4-8792-c372dd154d38   # UUID or system name
framework_id: soc2                                # the same system under two
                                                  # frameworks is two scopes
targets:
  - name: simple-crm                              # becomes the directory name
    url: https://github.com/pretorin-ai/simple-crm.git
    ref: main                                     # optional
  # - name: crm-deploy                            # shipped commented out
  #   url: https://github.com/pretorin-ai/crm-deploy.git
  #   ref: master
  #   private: true                               # needs a GitHub App
```

One system and framework for the whole file; one or many targets. `bootstrap.sh`
clones each into `workspace/targets/<name>`, which compose bind-mounts
**read-only** at `/workspace/targets`.

`ref` is a **branch name** — not a tag and not a SHA. Synchronization
fast-forwards a branch to its upstream, and a detached checkout at a tag has no
upstream to fast-forward to. Without `ref`, a target follows whatever branch the
clone is on, which after a fresh clone is the remote's default.

Once cloned, targets are brought up to date with **[Keeping targets up to date](#keeping-targets-up-to-date)** — from the host or from Slack.

The private example ships **commented out**, and deliberately: the committed file
has to work for a fresh clone that has nothing but a Pretorin key, and for CI,
which holds zero credentials. A private target with **no credential at all** —
neither a GitHub App nor a PAT — is a hard failure, which is correct behaviour
and the wrong default. Uncomment it once you have configured one of the two.

List the scopes your key can see:

```sh
docker compose run --rm cli pretorin --json context list
```

### Public repositories

Nothing to configure. Any `https://` remote that clones anonymously works.

### Private repositories

`private: true` is a flag only — **no token, no credential and no path to one ever
appears in the declaration**, in either format.

The supported path is a **read-only GitHub App**. Creating one on an organisation
requires **organisation owner** permission; a member cannot do it. If you are not
an owner, everything below is the request to hand to one — steps 1–5 are theirs,
steps 6–8 are yours once they give you the App ID and the `.pem`.

#### 1. Create the App (org owner)

`https://github.com/organizations/<ORG>/settings/apps/new`
— or Organisation settings → Developer settings → GitHub Apps → **New GitHub App**.

| Field | Value |
| --- | --- |
| GitHub App name | `Compliance Claw <org>` (must be globally unique) |
| Homepage URL | your repo URL — unused, but required |
| **Webhook** | **UNCHECK "Active"**. Compliance Claw pulls; it receives nothing. |
| Where can this be installed | **Only on this account** |

#### 2. Permissions — exactly one

Repository permissions → **Contents: Read-only**. Nothing else. Leave every other
permission at *No access*, and grant **no** organisation or account permissions.

`Metadata: Read-only` will be selected for you automatically — that is a GitHub
requirement and is expected. Do not add write access anywhere: this agent reviews
code and never pushes.

#### 3. Generate a private key (org owner)

On the App's page after creation: **Private keys → Generate a private key**. GitHub
downloads a `.pem` once and never shows it again.

#### 4. Install it on selected repositories only (org owner)

App page → **Install App** → the organisation → **Only select repositories** →
choose exactly the repositories to be reviewed. Not "All repositories".

#### 5. Hand over two things (org owner → operator)

- The numeric **App ID** — top of the App's settings page, e.g. `1234567`. This is
  *not* the Client ID and *not* the App name.
- The **`.pem` file**, over a secure channel. It is a private key.

#### 6. Place the key (operator)

```sh
mkdir -p secrets
mv ~/Downloads/<app-name>.<date>.private-key.pem secrets/compliance-claw.private-key.pem
chmod 600 secrets/compliance-claw.private-key.pem
```

`secrets/` and `*.pem` are both gitignored, and `.dockerignore` is an allowlist, so
the key can reach neither git nor a Docker build context.

#### 7. Point `.env` at it (operator)

```sh
GITHUB_APP_ID=1234567
GITHUB_APP_PRIVATE_KEY_FILE=secrets/compliance-claw.private-key.pem
GITHUB_APP_INSTALLATION_ID=          # leave empty; discovered automatically
```

Only fill `GITHUB_APP_INSTALLATION_ID` if the App is installed on more than one
account, in which case bootstrap lists the candidates and asks you to pick.

#### 8. Declare the target and run (operator)

Add the target with `private: true` to the relevant effort in `efforts.yaml`
(`efforts.example.yaml` documents the shape), then:

```sh
scripts/bootstrap.sh        # mints the token, clones, deletes the token
scripts/clawctl apply       # registers it with Pretorin like any other target
```

Bootstrap mints an installation token scoped to `contents:read` on exactly the
private targets you declared, clones with it, and deletes it. Verify afterwards:

```sh
git -C workspace/targets/<name> log --oneline -1        # the clone worked
git -C workspace/targets/<name> remote get-url origin   # a clean https URL
grep -c x-access-token workspace/targets/<name>/.git/config   # must print 0
```

#### If something is wrong

| Message | Meaning |
| --- | --- |
| `GITHUB_APP_ID is not set` | Step 7 not done, or `.env` not saved |
| `GITHUB_APP_ID must be numeric` | You used the Client ID or the App name |
| `cannot read the GitHub App private key` | Wrong path in step 6/7; paths are relative to the repo root |
| `is not a usable RSA private key` | Not the `.pem` — probably the manifest or a certificate |
| `the App JWT was rejected` | App ID and key are from different Apps, or the host clock is off |
| `the App is installed on 0 or several accounts` | Set `GITHUB_APP_INSTALLATION_ID` to the one listed |
| `the GitHub App installation does not include:` | Step 4 missed that repository; the message links the installation page |
| `needs Repository -> Contents -> Read-only` | Step 2 permission missing, or the org owner has not accepted a permission change |

**The GitHub App credential never leaves this host.** The private key is
host-only, the installation token it mints lives in a 0600 temp file for one
`bootstrap.sh` run, both reach git through a credential helper rather than the
URL or `argv`, neither is ever written into a clone's `.git/config` (asserted
after every clone, and independently by `scripts/smoke.sh`), and neither is ever
mounted into a container.

#### The PAT fallback, and the invariant it relaxes

Earlier releases said the container never holds a git credential at all. **That
is no longer true**, and this section says so rather than leaving the old
sentence standing.

Synchronizing a private target from Slack happens *inside* the container, and the
App private key deliberately never goes there — so that path uses a
**fine-grained PAT** instead, delivered as a mounted file:

```sh
scripts/init-file-secrets.sh                     # creates it empty if absent
$EDITOR secrets/runtime/github-readonly-pat      # paste the token, no newline needed
```

The token must be:

- **fine-grained** (not classic),
- limited to **only the selected repositories** you review,
- with **Repository permissions → Contents: Read-only** and nothing else.

Then select `compose.secrets.yaml` in the [saved deployment settings](../README.md#save-deployment-settings)
and restart. The PAT is only available on the file-secret path; the legacy `.env` path has no PAT and
a private target there reports `auth_failed` naming the fix.

**Status: internal-pilot acceptable, not recommended.** The GitHub App is the
recommended mechanism for any customer or production deployment. A PAT carries a
person's identity, expires on a human's schedule, is harder to scope, and —
unlike the App — is a git credential that lives inside the container. It is never
an environment variable, never in a URL, `.git/config`, a log, an audit line or a
Slack message; but tool execution in that container is unsandboxed, so a
prompt-injected agent can read the file. Read
[SECURITY.md](../SECURITY.md#the-pat-is-a-deliberately-relaxed-invariant-not-an-oversight)
before enabling it.

`bootstrap.sh` prefers the App whenever `GITHUB_APP_ID` is set, and **will not
fall back to the PAT if minting fails** — a broken App stops the run rather than
silently substituting a longer-lived credential.

## Keeping targets up to date

Targets do not move on their own. Three ways to advance them, all running the
**same implementation** (`scripts/sync-targets.sh`) so they cannot disagree:

```sh
scripts/bootstrap.sh                  # host: clone what is missing, update the rest
scripts/sync-targets.sh all           # host: update only, never clone
scripts/sync-targets.sh simple-crm    # host: one target
```

and from Slack, once the gateway is running:

```
/compliance-claw /target-sync all                # deterministic; bypasses the model
/compliance-claw /target-sync simple-crm
@claw update the simple-crm target    # the target_sync tool, same wrapper
```

The reply names every target it touched:

```
simple-crm updated: 276b5fd → 918ac42
```

**Fast-forward only.** It never resets, force-checks-out, stashes, discards local
changes, switches branches, rewrites history, deletes anything, or creates a
merge commit. A target it cannot move safely is reported and left exactly as it
is, with a message naming the remedy:

| Outcome | What it means |
| --- | --- |
| `updated` | fast-forwarded; both SHAs reported |
| `already_current` | nothing to do |
| `dirty_refused` | the working tree has local changes |
| `detached_refused` | HEAD is not on a branch |
| `no_upstream_refused` | the branch does not track `origin/<branch>` |
| `branch_mismatch_refused` | checked out on a branch other than `ref` |
| `origin_mismatch_refused` | the clone tracks a different remote than `efforts.yaml` declares |
| `diverged_refused` | local commits the remote lacks, or upstream rewrote history |
| `missing_clone` | not cloned yet — run `scripts/bootstrap.sh` |
| `auth_failed` | the remote refused the credential |
| `invalid_target` | not declared at all, or a malformed request |
| `out_of_effort` | a real target, but not one this effort declares — ask in that effort's channel |
| `targets_unreadable` | `efforts.yaml` could not be parsed — nothing was examined |
| `sync_already_running` | another sync holds the global lock |

A lock left behind by a killed process is reclaimed automatically once its owner
is provably gone, and the reclaim is announced in the log. A lock held by a live
process, or by one this container cannot see (the host, or an earlier container),
is never taken — clear that by hand with `rmdir` on the path the message names.

`all` processes targets one at a time, keeps going after a failure, reports every
target, and exits non-zero if any failed.

**What it cannot do.** Only `all` or the name of a target declared **for the
calling agent's own effort** is accepted — no URL, ref, path, flag or shell
fragment is expressible on any route, and `all` means all of that effort's
targets, never every repository on the deployment. A target belonging to another
effort is refused by name. Which effort is calling comes from the OpenClaw agent
id, which the host resolves from the routed session before the tool runs, so a
prompt cannot name a different one. Adding, removing, re-pointing or onboarding a
target stays an operator action on the host: edit `efforts.yaml`, then run
`scripts/clawctl apply`.

Ordinary synchronization does **not** re-run onboarding and does **not** restart
the gateway. Source resolvers bind paths rather than commits, and
`/workspace/targets` is a live bind mount, so the new bytes are visible
immediately.

### Where the writable mount is, and what it is not

Assessment reads `/workspace/targets`, **read-only on both services**. The
synchronizer writes through a second mount of the same host directory,
`/var/lib/compliance-claw/targets`, on the **gateway service only**.

That is process-level separation inside one container, **not a security
boundary**: the wrapper and the agent's unsandboxed tool execution run as the
same uid, so an agent can reach the writable path directly. What it buys is that
the assessment path — the one every evidence citation comes from — stays
read-only, so an accidental write fails instead of silently succeeding. See
[SECURITY.md](../SECURITY.md#the-sandbox-boundary--say-it-plainly).

### The sync audit record

One line per target, to `docker compose logs openclaw` **and** to
`/home/node/.pretorin/target-sync-audit.log`:

```
v=1 ts=2026-08-26T00:01:53Z op=target-sync target=simple-crm outcome=already_current previous=276b5fd8… resulting=276b5fd8… credential=none requester=slack:U123 route=command
```

`credential` records the *source* (`none`, `github-app`, `pat`) and never a
value. The log copy is the one that matters: the agent can rewrite anything in
the state volume, so a file it can edit is not evidence on its own.
