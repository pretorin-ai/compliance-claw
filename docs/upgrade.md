# OpenClaw upgrade and recovery

The build pins OpenClaw 2026.10.3 and Pretorin CLI seed 0.30.3. A fresh
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

The gateway service has `stop_grace_period: 330s`. OpenClaw 2026.10.3 allows
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

`scripts/update.sh` retains the volumes. It does not create a backup or perform
state recovery. The OpenClaw container adapter runs Doctor before the gateway
and can migrate retained state. Stop and verify the backup before you use the
update script for an OpenClaw upgrade.

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
