# OpenClaw upgrade and recovery

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

The [CLI update commands](../README.md#updating-the-pretorin-cli) share the signed
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
