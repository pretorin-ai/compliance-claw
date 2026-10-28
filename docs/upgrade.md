# Update, upgrade and recovery

This guide covers the routine deployment update, the Pretorin CLI update, the
OpenClaw image upgrade with state backup, recovery, and the destructive reset.
Run every command from the repository root with the deployment's saved
[Compose selection](../README.md#save-deployment-settings).

## Routine deployment update

```sh
scripts/update.sh
```

One command: fast-forward the checkout, pull the image this checkout pins, restart
the selected gateway, then report anything you have to act on. Compose waits up
to 720 seconds for the gateway to report healthy (15-second probe interval,
720-second startup grace). Your own Compose overlays still take precedence over
these values. The wait covers gateway startup only: the Git fetch, the image
pull and the 330-second stop grace add their own time. The script then checks
that the running container is healthy and runs the pinned image, with your
overlays applied, and checks the gateway again after diagnostics. A second run
changes nothing.

Use Docker Compose 2.27.2 or newer, with `--wait` and `--wait-timeout` support,
and Python 3. Keep the deployment's `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE`, and
profiles selected. Only the gateway and its Compose dependencies are started;
the one-shot `cli` service is used for diagnostics.

Exit 0 means gateway image and health verification and the configuration
diagnostic succeeded. Configuration-drift warnings are reported but do not fail the run.
Startup, wait, inspection, image mismatch, and diagnostic failures return nonzero
without a completion report. A failed diagnostic reports configuration status as
unknown. Inspect the reported error and `docker compose ps -a` with the same
deployment selection. No automatic recovery is attempted. Gateway health does
not prove that Slack or Pretorin MCP calls succeed.

On `master` the digest pin and `IMAGE_VERSION` are already set to the current
release, so updating means pulling `master` rather than editing anything. To move
to a *specific* release instead, point `compose.yaml` at that digest and set the
matching `IMAGE_VERSION` in `versions.env` before running it — `smoke.sh` asserts
the two agree.

`update.sh` refuses rather than guessing, and names the exact command each time:
a dirty working tree, a detached HEAD, a branch with no upstream, a branch that has
diverged from its upstream, or a deployment selection that includes the local build
overlay (that is a rebuild, not an update).

### What survives an update, and what does not

| | Survives `update.sh` | Survives `down -v` |
| --- | --- | --- |
| The image | replaced — that is the point | n/a |
| **The Pretorin CLI** (`pretorin-state`) | **yes — `update.sh` does not touch it** | **no — reverts to the image seed** |
| Model login (`openclaw-state`) | **yes** | **no** |
| Seeded config, sessions, `AGENTS.md` | **yes** | **no** |
| Pretorin context, resolvers, recipes (`pretorin-state`) | **yes** | **no** |
| `.env` | **yes** | **yes** — never touched by either |
| `workspace/targets` clones | **yes** | **yes** — bind-mounted, not a volume |

OpenClaw can migrate the stored configuration and databases at startup. Before
an upgrade, stop the gateway and back up both state volumes and deployment
files. See [OpenClaw image upgrade and state backup](#openclaw-image-upgrade-and-state-backup).
An older image can require
the matching pre-upgrade state; changing the image alone is not a full rollback.

**Two notes on the CLI row.** `down -v` deletes
`pretorin-state`, so the next start re-seeds the CLI from the image and every
update you had applied is gone. Reserve this command for intentional state
deletion; it is not routine configuration repair. And rolling the *image* backwards
does **not** roll the CLI backwards: the volume keeps whatever version it has.
The CLI moves in exactly one way, `scripts/pretorin-update.sh`.

Re-run
`scripts/clawctl apply` only after `down -v`, or when `efforts.yaml` changes; it
is idempotent either way.

`smoke.sh` also reports this state on its own:

```
NOTE  deployment is behind the repo pin: run scripts/update.sh
      running sha256:58690e31...
      pinned  sha256:e123bf53...
```

A warning, not a failure — being mid-update is not being broken.

**The image does not decide which Pretorin CLI you run.** It ships a *seed*;
the CLI a deployment actually uses lives in the `pretorin-state` volume, and
`update.sh` does not touch volumes. So pulling a newer image gives you a newer
seed and the same CLI. Move the CLI with:

```sh
scripts/pretorin-update.sh --status     # what is installed, and what the image seeds
scripts/pretorin-update.sh latest       # update to the latest stable release
```

**Templates do not replace an existing configuration.** OpenClaw can migrate its
schema; other template changes require administrator review. The container
reports a template revision difference:

```
compliance-claw: WARNING — this volume's config predates the image.
  volume template version 2, image ships 3.
```

For a template change, merge the change by hand — diff your
`~/.openclaw/openclaw.json` against
`/opt/compliance-claw/openclaw-config.template.json` in the image, then
`echo 3 > ~/.openclaw/.compliance-claw-templates`. Back up the state before
repair. Do not delete volumes to apply a template change.

There is a second, Slack-specific version of this warning, because the
template-version message says nothing about Slack:

```
compliance-claw: WARNING — Slack credentials are supplied but NOT in this volume's config.
```

That means the Slack credentials this deployment requires — both tokens on the
multi-effort path, all three variables on the legacy one — are set while the
existing config predates them. It names the managed install and configuration
steps. It does not replace the existing configuration.

## Updating the Pretorin CLI

The active CLI is `/home/node/.pretorin/bin/pretorin` in `pretorin-state`.
It survives image upgrades. A CLI update affects **every agent and user of this
instance** and does not require an image release. The shared installer verifies
signatures and refuses downgrades and prereleases.

From the deployment host:

```sh
scripts/pretorin-update.sh              # installed version, seed, and last update
scripts/pretorin-update.sh latest       # latest stable release
scripts/pretorin-update.sh 0.28.7       # exact version
scripts/pretorin-update.sh --dry-run    # inspect without changes
```

From Slack, use the command name registered for your app:

```
/compliance-claw /pretorin-update latest
/compliance-claw /pretorin-update 0.28.7
/compliance-claw /pretorin-update status
@Compliance Claw update Pretorin
```

**Both Slack update routes require native administrator authority.** For individual
sign-in, use the person's existing Gateway profile and a role whose effective
scopes include `operator.admin`. Browser-only users do not need a Slack link.
For Slack users, an administrator calls `users.linkChannelIdentity` with:

```json
{
  "profileId": "<existing-person-profile-id>",
  "identity": {
    "channelId": "slack",
    "accountId": "default",
    "senderId": "U0123456789"
  }
}
```

Use the exact configured Slack account ID and verified native user ID. Use
`users.listChannelIdentities` with `profileId` to check the link. Display names,
message text, and channel membership do not grant administrator authority.
The shared Owner profile cannot receive a person link. These methods require
an authenticated administrator Gateway connection; they do not create users
or configure individual sign-in.

To remove Slack authority, call `users.unlinkChannelIdentity` with the same
`profileId` and `identity`, or remove the person's administrative role through
`users.setRole`. Check the resulting effective role: clearing an assignment can
restore a configured default. Remove any matching `commands.ownerAllowFrom`
entry too; these legacy owner grants remain independent of profile links.
Previously selected tools check current authority before starting an installer.
An accepted installation keeps its normal verification and cleanup. Revocation
prevents a new installation or automatic restart; it does not undo accepted work.

**Automatic restart applies only to the owner Slack command.**
The first reply reports installation and pending activation. The gateway restarts
inside the running container. A final Slack message reports completion only after
the expected CLI version, executable bytes, and real MCP calls are verified.

**The conversational model tool requires an operator restart.** Disabled restart
and unsupported reply routes also return **OPERATOR RESTART REQUIRED**. With the
deployment's Compose project and overlays selected, run:

```sh
docker compose restart openclaw
docker compose exec -T openclaw pretorin version
```

The version command checks the installed file. Confirm that the restart and next
Pretorin MCP call succeed before treating the update as complete. Failed automatic
verification reports installation success with unverified activation.

Automatic verification supports the pinned OpenClaw `2026.10.5` Linux container,
the canonical Pretorin MCP command, and the shipped effort launcher. See
[activation, pending results, and recovery limits](#pretorin-cli-activation-and-results)
and the [update audit record](#pretorin-cli-update-audit).

## OpenClaw image upgrade and state backup

The build pins OpenClaw 2026.10.5 and Pretorin CLI seed 0.30.4. A fresh
installation uses this seed. An image upgrade keeps the active CLI in the
Pretorin state volume. Use the CLI update command to change that active copy.

Build pins can change before an image is published. Use the published image
digest in `compose.yaml` for deployment. The release workflow must pass before
the post-release PR changes that digest and `IMAGE_VERSION` together.

Before an OpenClaw upgrade, record the running image digest, the checkout
revision, the Compose files, and the names of both state volumes. Keep the
previous image available. The image and both state volumes are one recovery
set.

Stop the gateway before you archive its state:

```sh
docker compose stop --timeout 330 openclaw
docker compose ps -a openclaw
```

Check that the container stopped with exit code 0. If shutdown was interrupted,
check its logs before you continue. Archive both `openclaw-state` and
`pretorin-state`. Store the archives in a private directory. These archives can
contain credentials, sessions, and customer data. Verify each archive by
restoring it into a new test volume. Check the restored files against the
archive. Test the previous image with the restored state and no network access.

Only then start the new image with the original state volumes. Check gateway
health, agent and channel settings, the managed Slack package, and the active
Pretorin CLI. Send a test request through the approved test channel. Replace
the container once more and repeat the checks. The replacement must use the
same state volumes.

The gateway service has `stop_grace_period: 330s`. OpenClaw 2026.10.5 allows
325 seconds for shutdown and 5 more seconds for its supervisor. Compose uses
this limit for a service stop or replacement. A stop can take several minutes
when work is active.

If startup reports `Another Gateway owner lease is still active`, first check
that no other gateway uses this state. Stop the failed container. After an
interrupted stop, the lease can remain valid for five minutes after the last
heartbeat. Wait for natural expiry before you retry. A running owner renews
the lease every 30 seconds. Do not delete or edit a lease to bypass its owner.
Do not delete a state volume to clear this error.

For rollback, stop the candidate with the same shutdown limit. Keep its state
for diagnosis. Restore both verified archives into new volumes and select the
previous image digest with the previous Compose files. Check restored files
and gateway health before you return traffic. An image rollback alone cannot
reverse changes to the config or SQLite schema. A copy of `openclaw.json`
alone is not a full state backup.

After a manual restore, keep the final native Compose overlay at a stable private
path outside the temporary backup directory. Retain the exact external names of
both restored volumes and the previous image references for both services. Save
the ordered files and project in the existing `.env`, as described in
[Save deployment settings](../README.md#save-deployment-settings). Include that
overlay last, for example:

```dotenv
COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.efforts.yaml:/private/path/restored.yaml
```

Run `docker compose --profile '*' config` and check the image and both state mounts
by destination before startup. This output can contain private configuration;
keep it local. A missing saved overlay must stop the command; do not remove it
to fall back to the original volumes. No script renames or adopts volumes.

`scripts/update.sh` retains the volumes. It does not create a backup or perform
state recovery. The OpenClaw container adapter runs Doctor before the gateway
and can migrate retained state. Stop and verify the backup before you use the
update script for an OpenClaw upgrade.

Slack preparation also runs the pinned OpenClaw Doctor command before it
inspects or changes configured Slack state. This pass allows supported retained
configuration to migrate even when the obsolete Slack load path is absent. A
Doctor failure stops preparation. The final upstream adapter still runs Doctor
after plugin preparation, because the installed plugin set can change. This adds
one Doctor pass for configured Slack state without the obsolete path; it does
not add migration rules or replace upstream activation.

Initial fresh Slack installation still installs the package before it applies
the channel patch. That initial step has no Slack configuration and does not run
the extra Doctor pass. Ordinary retained CLI commands do not run Slack
preparation during startup. Unused Slack skips its operations and early Doctor
pass.

`clawctl apply` validates and applies its configuration patch inside the gateway
container when that service is running. OpenClaw verifies the state owner in the
same PID namespace. The command uses the existing entrypoint to load file
credentials inside the container. Before the gateway exists, it uses the CLI
container. Do not remove state ownership locks to make a separate container read
live state.

## Pretorin CLI activation and results

The [CLI update commands](#updating-the-pretorin-cli) share the signed
installer. Only the owner Slack command requests automatic activation. It uses
`openclaw gateway restart --safe --json`, the `gateway_start` hook, and the public
Slack outbound adapter. It does not use restricted Gateway RPC or delegated
restart. The conversational model tool requires an operator restart.

Before restart, the updater creates `~/.pretorin/update-activation.json` with mode
`0600`. It records the expected version and executable hash, request time, and
original Slack account, channel, and thread. A restart request is a pending state,
not proof of activation.

After a new gateway startup, verification checks the configured CLI path, version,
and installed bytes. It calls `check_context` through each configured Pretorin MCP
server and checks loaded executable bytes, including retained file descriptors
under emulation. It keeps successful probe processes alive until these checks
finish, then closes them. A plugin reload alone does not count as a restart.

The final message reports completion only after verification. An activation
failure reports installation success, unverified activation, and the operator
restart command. Delivery uses the original Slack destination and requires an
acknowledged message ID. It tries at most three times. An unconfirmed delivery or
interrupted startup keeps the receipt for the next startup; another chat update
is blocked while it is pending, but status remains available. Do not remove a
receipt while an update is pending. A lost Slack acknowledgement can cause a
duplicate final message on retry.

If the original Slack account or channel is removed or disabled, the receipt can
remain pending and block further chat updates. This is a known recovery limit.
The updater does not redirect the result or clear the receipt automatically.

## Pretorin CLI update audit

The installer writes `/home/node/.pretorin/update-audit.log` with mode `0600` and
copies each record to stderr. Chat routes send stderr to the gateway container
log; the host updater sends it to the operator terminal. These records describe
installation, not verified activation. Read the file with
`scripts/pretorin-update.sh --status`, or in full:

```sh
docker compose run --rm cli cat /home/node/.pretorin/update-audit.log
docker compose logs openclaw | grep 'outcome='
```

Each record includes the format version (`v`), requested and normalized version,
previous and resulting version, outcome, requester, and route. Outcomes include
`installed`, `already_current`, `refused_input`, `rolled_back`, `timeout`,
`backup_failed`, `backup_mismatch`, and `interrupted`. Routes are `command`,
`tool`, or `repair`.

Requester identity comes from the authenticated command or trusted tool context,
never a model argument. If unavailable, the record says `unavailable`. The log
shows who changed the CLI, when, and to which version. It is not tamper-evident:
the agent uses the same container user, and deleting the state volume removes the
file. Chat routes also keep a copy in the gateway container log. See the limits
in [SECURITY.md](../SECURITY.md).

## Transfer existing effort records

Do this **before** starting an image that selects per-effort Plan/preflight roots
or running its `clawctl apply`. The runtime does not move or adopt old records.
Keep the same HOME, active CLI, credentials and `pretorin-state` volume.

1. Stop the gateway with the shutdown limit above. Stop any one-off CLI/MCP
   writer too. Record the old image, Compose selection, volume names, declarations
   and active CLI version/hash. Back up matching host inputs and both stopped
   volumes as described above. Keep the old image and protected originals.
2. Inventory **all** entries in the old Plan and preflight directories, normally
   `/home/node/.pretorin/plans` and `/home/node/.pretorin/preflight`. Check any
   previously configured root overrides. A recent Plan list is not an inventory:
   it has a limit and skips corrupt files. Report links, corrupt files, duplicate
   scope records, Campaign records, and unknown formats for manual resolution.
3. Validate each supported Plan with the current native CLI's `--json plan show
   PLAN_UUID`, using its old root. Validate a preflight record with `--json
   preflight show --system SYSTEM_UUID --framework FRAMEWORK_ID`, using its old
   root. Require the expected record/scope, not just exit 0: an absent preflight
   can return `exists: false`. Use explicit roots in the container, for example:

   ```sh
   docker compose run --rm -T \
     -e PRETORIN_PLANS_DIR=/home/node/.pretorin/plans \
     -e PRETORIN_PREFLIGHT_DIR=/home/node/.pretorin/preflight \
     cli pretorin --json plan show PLAN_UUID
   ```

   Compare every record's scope with the declarations. Assign a record only when
   its owner is confirmed. If two efforts share that scope, the pair alone is
   insufficient: stop for an explicit operator ownership decision. Never guess,
   delete, silently archive or copy a shared record into every effort. Resolve
   unsupported/corrupt/conflicting records before activation. Keep that decision
   and the inventory private; they can contain customer data.
4. Select the validated effort and copy each approved **original** regular record
   to its corresponding subdirectory. Do not import displayed JSON: preflight
   output can redact stored values. Do not copy old indexes, journals or locks.
   Set the source/target filenames from the checked inventory; keep each Plan UUID
   and the preflight filename. For example, after replacing `PLAN_UUID`:

   ```sh
   EFFORT=crm-soc2
   EFFORT_RECORD_ROOT="$(python3 scripts/parse-efforts.py state-root "$EFFORT")"
   RECORD_SOURCE=/home/node/.pretorin/plans/PLAN_UUID.json
   RECORD_TARGET="${EFFORT_RECORD_ROOT}/plans/PLAN_UUID.json"
   docker compose run --rm -T cli sh -eu -c '
     test -f "$1"
     test ! -L "$1"
     test ! -e "$2"
     test ! -L "$2"
     umask 077
     mkdir -p "$(dirname "$2")"
     cp -p "$1" "$2"
     cmp "$1" "$2"
   ' sh "$RECORD_SOURCE" "$RECORD_TARGET"
   ```

   Use the same guarded copy for each approved preflight file, with its target
   under `${EFFORT_RECORD_ROOT}/preflight/`. Inspect parents for links first;
   keep existing record modes/owner and protect new directories. An existing
   target or a failed comparison is a conflict, not permission to overwrite it.
5. With explicit new root overrides, use native Plan show/list and preflight show
   to verify IDs, content, steps, history, source bindings and active recipes.
   Resume a known nonterminal Plan through its effort MCP and check that only its
   own records are offered. Native resume lookup rebuilds a missing index from
   the validated Plan files; do not hand-edit or copy a global index. Reapply
   onboarding only after record ownership/validation is complete. It can update
   derived source bindings, so compare the resulting profile deliberately.
6. Start the gateway and verify own-effort reads, other-effort denials, restart
   and container replacement with the same volumes. Keep protected originals
   until the transfer and recovery checks pass. The CLI/config/recipe library,
   Campaign orchestration and platform data remain shared; this is not OS or
   person isolation.

On a failed validation/copy/resume or interrupted transfer, stop. Do not start
writers against a partial transfer. Keep the failed state for diagnosis, restore
the matching stopped backup into new volumes, and select the previous image and
Compose route as described above. Verify the original Plan/profile before
returning work. Restoring only config or starting old and new writers against
one volume is not rollback. Keep current issuer/person revocations effective;
restoring a backup must not restore removed authority. No migration command,
adoption flag or separate state registry is required by this procedure.

## Resetting (destructive)

`docker compose down` retains the named volumes. Adding `-v` deliberately deletes
both: OpenClaw config, sessions, agent workspaces, model login, and the managed
Slack installation; and Pretorin context, resolvers, recipes, active CLI, and
volume audit files. Bind-mounted target clones and host files such as `.env`
and secret files remain.

Do not use `down -v` for routine setup or troubleshooting. Before intentional
state deletion, select the correct Compose project and files and follow the
[backup procedure](#openclaw-image-upgrade-and-state-backup) to preserve verified backups. Bootstrap
and `clawctl apply` can create initial state; they cannot restore deleted sessions
or prior configuration. Restore from a verified recovery set when state matters.
