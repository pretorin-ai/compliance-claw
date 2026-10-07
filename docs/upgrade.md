# OpenClaw upgrade and recovery

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

The gateway service has `stop_grace_period: 330s`. OpenClaw 2026.9.8 allows
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
