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

The previous image and both state volumes are one recovery set. The set is
compatible only with the image that last ran that state. Make and verify a set
before each OpenClaw upgrade, before an
[effort-record transfer](#transfer-existing-effort-records), and before
intentional state deletion. Use the steps below as one procedure. Run them on
the deployment host, from the repository root, in one Bash shell. They need
Docker, Compose 2.27.2 or newer, Git and Python 3. State copies use the recorded
image as root, with no network.

Each command block ends with an `OK:` line. If a block does not print its `OK:`
line, stop. Read the error and correct the cause before you continue. Do not
skip a check and do not run a later block.

### Recovery set and host inputs

A recovery set has these parts. The procedure records or copies each one, or
names the person who must keep it:

| Item | Where it is | In the recovery set | Contents or your responsibility |
| --- | --- | --- | --- |
| `openclaw-state` | Named volume | Archive and file list | Holds config, sessions, agent workspaces, model login, managed Slack package. |
| `pretorin-state` | Named volume | Archive and file list | Holds the active CLI, Pretorin context, effort records, resolvers, recipes, audit file. |
| Previous image | Docker image cache | Reference and ID in the record | Keep it cached. Do not prune it while you can need the set. |
| Compose selection | `.env` and shell | Values in the record | Keep the project name and the ordered files. |
| Declarations and private overlays | Host files | Copies in `host-inputs/`, at their full host path | Keep the originals. A changed declaration needs your review. |
| Credentials | Secret directory, or `.env` on the legacy path | Not copied | Keep current files. Get a replacement from the issuer if necessary. |
| Target clones and other customer bind mounts | Host directories | Paths only | Back them up yourself, or clone the targets again. |

Prepare the shell first, and again in each new shell. This block resolves the
saved [Compose selection](../README.md#save-deployment-settings). It defines the
state list, the selection check, the path of each saved host file, the rule for
files that Git tracks at a commit, a reader for the set record, and two copy
functions:

```sh
umask 077
BACKUP_ROOT=/var/backups/compliance-claw
STATE_LIST='find . -printf "%y %m %U:%G %p -> %l\n" | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k 2'
SELECTION_CHECK='
import json, os, sys
config = json.load(sys.stdin)
image = sys.argv[1]
want = {"/home/node/.openclaw": sys.argv[2], "/home/node/.pretorin": sys.argv[3]}
inputs = set()
for name in ("openclaw", "cli"):
    service = config["services"][name]
    mounts = service.get("volumes", [])
    state = {m["target"]: config["volumes"][m["source"]]["name"] for m in mounts if m["type"] == "volume"}
    if service["image"] != image or state != want:
        sys.exit("STOP: %s selects %s with %s" % (name, service["image"], state))
    for m in mounts:
        if m["type"] == "bind":
            inputs.add(("file" if os.path.isfile(m["source"]) else "directory", m["source"]))
for secret in config.get("secrets", {}).values():
    inputs.add(("secret", secret["file"]))
for kind, path in sorted(inputs):
    print("%s\t%s" % (kind, path))
'
saved_input() {
  python3 -c 'import os, sys; print(sys.argv[3] + os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))' \
    "$PWD" "$1" "$BACKUP_DIR/host-inputs"
}
tracked_at() {
  test -n "$(git ls-tree --name-only "$1" -- "$2" 2>/dev/null)"
}
record() { sed -n "s/^$1=//p" "$BACKUP_DIR/recovery-set.env"; }
state_sh() {
  docker run --rm -i --network none --platform linux/amd64 --user 0:0 \
    --entrypoint sh --mount "type=volume,src=$1,dst=/state${3:+,$3}" \
    "$IMAGE_ID" -euc "cd /state && $2"
}
backup_sh() {
  docker run --rm --network none --platform linux/amd64 --user 0:0 \
    --entrypoint sh --mount "type=bind,src=$BACKUP_DIR,dst=/backup,readonly" \
    -w /backup "$IMAGE_ID" -euc "$1"
}
. scripts/compose-selection.sh && compose_resolve_selection &&
echo "OK: shell prepared for project ${COMPOSE_PROJECT_NAME:-from compose.yaml}"
```

Change `BACKUP_ROOT` to a private host directory with enough space. Archives
can contain credentials, sessions and customer data. Do not put them in the
repository, the target directory or a shared directory.

### Back up the recovery set

1. Identify the gateway that last used the state. Record its project, image and
   state volumes. The selection check compares them with the saved selection for
   both services and lists the host inputs:

   ```sh
   SET_ID="$(date -u +%Y%m%dT%H%M%SZ)" &&
   BACKUP_DIR="$BACKUP_ROOT/$SET_ID" &&
   GATEWAY="$(docker compose ps -a -q openclaw)" && test -n "$GATEWAY" &&
   PROJECT="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$GATEWAY")" &&
   IMAGE_REF="$(docker inspect --format '{{.Config.Image}}' "$GATEWAY")" &&
   IMAGE_ID="$(docker inspect --format '{{.Image}}' "$GATEWAY")" &&
   OPENCLAW_VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/node/.openclaw"}}{{.Name}}{{end}}{{end}}' "$GATEWAY")" &&
   PRETORIN_VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/node/.pretorin"}}{{.Name}}{{end}}{{end}}' "$GATEWAY")" &&
   test "$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")" = "$IMAGE_ID" &&
   SOURCE_REVISION="$(git rev-parse HEAD)" &&
   (set -f; IFS="${COMPOSE_PATH_SEPARATOR:-:}"; for f in ${COMPOSE_FILE:-compose.yaml}; do
     ! tracked_at "$SOURCE_REVISION" "$f" || { git diff --quiet "$SOURCE_REVISION" -- "$f" &&
       git diff --cached --quiet "$SOURCE_REVISION" -- "$f"; } ||
       { printf 'STOP: %s is tracked by Git and differs from commit %s\n' "$f" "$SOURCE_REVISION"; exit 1; }
   done) &&
   mkdir -p "$BACKUP_ROOT" && mkdir "$BACKUP_DIR" "$BACKUP_DIR/host-inputs" &&
   docker compose --profile '*' config --format json |
     python3 -c "$SELECTION_CHECK" "$IMAGE_REF" "$OPENCLAW_VOLUME" "$PRETORIN_VOLUME" \
     > "$BACKUP_DIR/host-inputs.txt" &&
   echo "OK: $PROJECT uses $IMAGE_REF, $OPENCLAW_VOLUME and $PRETORIN_VOLUME"
   ```

   A `STOP:` message means that the saved selection is not the selection of
   that gateway. If the image reference now points to a different image ID,
   the tag changed. Give the recorded image ID a new private tag, select that tag,
   and start again. Read `host-inputs.txt`. It names each declaration, secret
   file and customer bind mount of this deployment.

   A `STOP:` message that names a Compose file means that a selected Compose
   file that Git tracks has staged or unsaved changes. The backup does not copy
   tracked Compose files, and the recorded commit cannot recreate the changed
   bytes. Do not discard the changes. Move your settings into a private overlay
   outside Git, or save the changed file separately and return it to its
   committed version. Then run this block again.

2. Stop all writers. The gateway runs the Pretorin MCP servers, so this stops
   them too. The checks stop on any running container that uses either volume,
   for example a one-off `cli` command:

   ```sh
   docker compose stop --timeout 330 openclaw &&
   test "$(docker inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$GATEWAY")" = "exited 0" &&
   test -z "$(docker ps -q --filter "volume=$OPENCLAW_VOLUME")" &&
   test -z "$(docker ps -q --filter "volume=$PRETORIN_VOLUME")" &&
   echo "OK: no running container uses the state volumes"
   ```

   An exit code other than 0 means an unclean stop. That state is not a valid
   backup point: do not archive it, and do not start an upgrade. Keep the state
   volumes and the gateway logs unchanged. Save the logs with
   `docker compose logs --no-color openclaw` to a private file, and do not
   repair, edit or delete state. Then use an earlier verified set as described
   in [Restore a compatible recovery set](#restore-a-compatible-recovery-set),
   or ask for support diagnosis with the saved logs (see
   [Troubleshooting](../README.md#troubleshooting)).

   Wait for a running one-off command to end; do not stop it while it writes.
   Do not start a container until the archives are complete.

3. Archive both volumes, their file lists and the host files. Then write the
   private record and the checksums:

   ```sh
   test "$(git rev-parse HEAD)" = "$SOURCE_REVISION" &&
   state_sh "$OPENCLAW_VOLUME" "$STATE_LIST" readonly > "$BACKUP_DIR/openclaw-state.list" &&
   state_sh "$OPENCLAW_VOLUME" 'tar --numeric-owner -cpf - .' readonly > "$BACKUP_DIR/openclaw-state.tar" &&
   state_sh "$PRETORIN_VOLUME" "$STATE_LIST" readonly > "$BACKUP_DIR/pretorin-state.list" &&
   state_sh "$PRETORIN_VOLUME" 'tar --numeric-owner -cpf - .' readonly > "$BACKUP_DIR/pretorin-state.tar" &&
   awk -F '\t' '$1 == "file" { print $2 }' "$BACKUP_DIR/host-inputs.txt" |
     while IFS= read -r f; do s="$(saved_input "$f")" &&
       mkdir -p -- "${s%/*}" && cp -p -- "$f" "$s" || exit 1; done &&
   (set -f; IFS="${COMPOSE_PATH_SEPARATOR:-:}"; for f in ${COMPOSE_FILE:-compose.yaml}; do
     tracked_at "$SOURCE_REVISION" "$f" || { s="$(saved_input "$f")" &&
       mkdir -p -- "${s%/*}" && cp -p -- "$f" "$s"; } || exit 1; done) &&
   printf '%s=%s\n' \
     SET_ID "$SET_ID" \
     SOURCE_REVISION "$SOURCE_REVISION" \
     PROJECT "$PROJECT" \
     COMPOSE_FILE "${COMPOSE_FILE:-}" \
     COMPOSE_PATH_SEPARATOR "${COMPOSE_PATH_SEPARATOR:-}" \
     COMPOSE_PROFILES "${COMPOSE_PROFILES:-}" \
     COMPLIANCE_CLAW_SECRET_DIR "${COMPLIANCE_CLAW_SECRET_DIR:-}" \
     IMAGE_REF "$IMAGE_REF" \
     IMAGE_ID "$IMAGE_ID" \
     IMAGE_DIGESTS "$(docker image inspect --format '{{join .RepoDigests " "}}' "$IMAGE_ID")" \
     OPENCLAW_VOLUME "$OPENCLAW_VOLUME" \
     PRETORIN_VOLUME "$PRETORIN_VOLUME" \
     > "$BACKUP_DIR/recovery-set.env" &&
   backup_sh 'sha256sum openclaw-state.tar openclaw-state.list pretorin-state.tar pretorin-state.list recovery-set.env host-inputs.txt &&
     find host-inputs -type f -exec sha256sum {} +' > "$BACKUP_DIR/SHA256SUMS" &&
   echo "OK: recovery set $SET_ID is in $BACKUP_DIR"
   ```

   The file lists record the type, mode, numeric owner, path and link target of
   each entry, and a SHA-256 checksum of each regular file. The record holds
   no secret value. Compose secret files and bind-mounted directories are not
   copied. Each bind-mounted single file is copied, so a private overlay that
   mounts a key file puts that key in the set. Read `host-inputs.txt` before
   this step. An overlay is copied when Git does not track it at the current
   commit, also when it is only staged. `SHA256SUMS` covers the archives, the
   file lists, the record, `host-inputs.txt` and each saved host file.

4. Verify the recovery set. The same block is the first step of a restore:

   ```sh
   grep -qx "SET_ID=$SET_ID" "$BACKUP_DIR/recovery-set.env" &&
   grep -Eq '^SOURCE_REVISION=[0-9a-f]{40}$' "$BACKUP_DIR/recovery-set.env" &&
   SOURCE_REVISION="$(record SOURCE_REVISION)" && test -s "$BACKUP_DIR/host-inputs.txt" &&
   SEPARATOR="$(record COMPOSE_PATH_SEPARATOR)" && SAVED_FILES="$(record COMPOSE_FILE)" &&
   { awk -F '\t' '$1 == "file" { print $2 }' "$BACKUP_DIR/host-inputs.txt" &&
     (set -f; IFS="${SEPARATOR:-:}"; for f in ${SAVED_FILES:-compose.yaml}; do
       tracked_at "$SOURCE_REVISION" "$f" || printf '%s\n' "$f"; done); } |
     while IFS= read -r f; do s="$(saved_input "$f")" && test -f "$s" &&
       N="${s#"$BACKUP_DIR"/}" awk 'substr($0, 67) == ENVIRON["N"] { found = 1 } END { exit !found }' "$BACKUP_DIR/SHA256SUMS" ||
       { printf 'STOP: the set has no saved copy or no checksum for %s\n' "$f"; exit 1; }
     done &&
   backup_sh "test -s host-inputs.txt &&
     grep -qx '[0-9a-f]\{64\}  host-inputs.txt' SHA256SUMS &&
     sha256sum --strict -c SHA256SUMS &&
     tar -tf openclaw-state.tar ./openclaw.json >/dev/null &&
     tar -tf pretorin-state.tar ./bin/pretorin >/dev/null &&
     mkdir /tmp/openclaw-state /tmp/pretorin-state &&
     tar --numeric-owner -C /tmp/openclaw-state -xpf openclaw-state.tar &&
     tar --numeric-owner -C /tmp/pretorin-state -xpf pretorin-state.tar &&
     (cd /tmp/openclaw-state && $STATE_LIST) | cmp openclaw-state.list - &&
     (cd /tmp/pretorin-state && $STATE_LIST) | cmp pretorin-state.list -" &&
   echo "OK: recovery set $SET_ID is complete and matches its file lists"
   ```

   This stops on a missing or changed file, an empty or unchecked
   `host-inputs.txt`, a missing or changed saved host file, a record from a
   different set, and an archive of the wrong volume. It also stops when a host
   file that the backup copies has no saved copy or no line in `SHA256SUMS`, for
   example after an interrupted transfer. The checksums find damage; they do not
   prove who wrote the set. Write down the `SET_ID` and `BACKUP_DIR`
   values outside the shell. A complete and readable set does not prove that an
   image is compatible with it. Only the recorded image is a compatible image.

### Upgrade with the original volumes

Start the new image only after the set is verified. Use the original state
volumes. Check gateway health, agent and channel settings, the managed Slack
package, and the active Pretorin CLI. Send a test request through the approved
test channel. Replace the container once more and repeat the checks. The
replacement must use the same state volumes.

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

If the upgraded gateway fails, do not select the previous image with the
original volumes. The candidate can have migrated them. Restore the verified set
into new volumes as described below.

### Restore a compatible recovery set

A restore puts the archived state into new, empty volumes. The candidate state
stays in the original volumes for diagnosis. The previous image never opens
that state.

1. In a new shell, run the [preparation block](#recovery-set-and-host-inputs).
   Then set the recovery set to restore and a stable private path for the
   restore overlay. Use the `BACKUP_ROOT` of the backup. Keep the overlay
   outside the backup directory, outside the repository and outside the target
   directory. Then read the record:

   ```sh
   SET_ID=20261029T101500Z
   BACKUP_DIR="$BACKUP_ROOT/$SET_ID"
   RESTORE_OVERLAY=/srv/compliance-claw/restored.yaml
   ```

   ```sh
   PROJECT="$(record PROJECT)" && IMAGE_REF="$(record IMAGE_REF)" && IMAGE_ID="$(record IMAGE_ID)" &&
   OPENCLAW_VOLUME="$(record OPENCLAW_VOLUME)" && PRETORIN_VOLUME="$(record PRETORIN_VOLUME)" &&
   test -n "$PROJECT" && test -n "$IMAGE_REF" && test -n "$IMAGE_ID" &&
   test -n "$OPENCLAW_VOLUME" && test -n "$PRETORIN_VOLUME" &&
   test "$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")" = "$IMAGE_ID" &&
   echo "OK: set $SET_ID needs $IMAGE_REF"
   ```

   If the previous image is not cached and `IMAGE_REF` has a digest, pull
   `IMAGE_REF`. Otherwise pull a reference from `IMAGE_DIGESTS` and give it the
   recorded name with `docker tag`. A local build has no digest reference; it
   must still be in the image cache. Run the block again. Do not use a different
   image.

2. Run the [verification block](#back-up-the-recovery-set) from step 4 of the
   backup. Continue only after its `OK:` line. Then compare the declarations and
   private overlays of the set with their saved copies. Do not stop the
   candidate before both blocks print their `OK:` lines:

   ```sh
   test -s "$BACKUP_DIR/host-inputs.txt" &&
   SOURCE_REVISION="$(record SOURCE_REVISION)" && git cat-file -e "$SOURCE_REVISION^{commit}" &&
   SEPARATOR="$(record COMPOSE_PATH_SEPARATOR)" && SAVED_FILES="$(record COMPOSE_FILE)" &&
   { awk -F '\t' '$1 == "file" { print $2 }' "$BACKUP_DIR/host-inputs.txt" &&
     (set -f; IFS="${SEPARATOR:-:}"; for f in ${SAVED_FILES:-compose.yaml}; do
       test "$f" = "$RESTORE_OVERLAY" || printf '%s\n' "$f"; done); } |
     while IFS= read -r f; do
       tracked_at "$SOURCE_REVISION" "$f" && continue
       s="$(saved_input "$f")" && cmp -s -- "$f" "$s" ||
         { printf 'STOP: %s differs from its saved copy. To copy it back: cp -p -- %q %q\n' "$f" "$s" "$f"; exit 1; }
     done &&
   echo "OK: the host inputs match set $SET_ID"
   ```

   The block skips files that Git tracks at the recorded revision, because the
   candidate revision can change them. For a tracked declaration such as
   `targets.yaml`, the verification block checked its saved copy, and step 3 of
   [Select and save the restored volumes](#select-and-save-the-restored-volumes)
   compares it after the checkout returns to that revision. A tracked overlay
   has no saved copy; that checkout restores it. A `STOP:` line
   names the first file that differs and prints the command that copies the
   saved file back. Copy it back and run the block again. Keep a changed file
   only after you check that the restored state supports it; then copy the
   current file over its saved copy, so that this block and step 3 compare with
   it.

3. Stop the candidate and keep its state. The candidate logs and container
   record go to a new private directory:

   ```sh
   RESTORE_ID="$(date -u +%Y%m%dT%H%M%SZ)" &&
   RESTORE_DIR="$BACKUP_DIR-restore-$RESTORE_ID" && mkdir "$RESTORE_DIR" &&
   CANDIDATE="$(docker compose ps -a -q openclaw)" && test -n "$CANDIDATE" &&
   test "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$CANDIDATE")" = "$PROJECT" &&
   docker compose stop --timeout 330 openclaw &&
   docker compose logs --no-color openclaw > "$RESTORE_DIR/candidate-openclaw.log" &&
   docker inspect "$CANDIDATE" > "$RESTORE_DIR/candidate-container.json" &&
   test -z "$(docker ps -q --filter "volume=$OPENCLAW_VOLUME")" &&
   test -z "$(docker ps -q --filter "volume=$PRETORIN_VOLUME")" &&
   echo "OK: candidate stopped; its state stays in $OPENCLAW_VOLUME and $PRETORIN_VOLUME"
   ```

4. Restore into two new volumes and compare them with the file lists. A volume
   name that exists already stops the step. The copy also stops if a
   destination is not empty:

   ```sh
   VOLUME_ID="$(date -u +%Y%m%dT%H%M%SZ)" &&
   NEW_OPENCLAW_VOLUME="${PROJECT}_openclaw-state-restore-$VOLUME_ID" &&
   NEW_PRETORIN_VOLUME="${PROJECT}_pretorin-state-restore-$VOLUME_ID" &&
   ! docker volume inspect "$NEW_OPENCLAW_VOLUME" >/dev/null 2>&1 &&
   ! docker volume inspect "$NEW_PRETORIN_VOLUME" >/dev/null 2>&1 &&
   docker volume create --label "compliance-claw.recovery-set=$SET_ID" "$NEW_OPENCLAW_VOLUME" &&
   docker volume create --label "compliance-claw.recovery-set=$SET_ID" "$NEW_PRETORIN_VOLUME" &&
   state_sh "$NEW_OPENCLAW_VOLUME" 'test -z "$(find . -mindepth 1 -print -quit)" && tar --numeric-owner -xpf -' \
     < "$BACKUP_DIR/openclaw-state.tar" &&
   state_sh "$NEW_PRETORIN_VOLUME" 'test -z "$(find . -mindepth 1 -print -quit)" && tar --numeric-owner -xpf -' \
     < "$BACKUP_DIR/pretorin-state.tar" &&
   state_sh "$NEW_OPENCLAW_VOLUME" "$STATE_LIST" readonly | cmp "$BACKUP_DIR/openclaw-state.list" - &&
   state_sh "$NEW_PRETORIN_VOLUME" "$STATE_LIST" readonly | cmp "$BACKUP_DIR/pretorin-state.list" - &&
   echo "OK: $NEW_OPENCLAW_VOLUME and $NEW_PRETORIN_VOLUME match set $SET_ID"
   ```

   The comparison covers content, type, mode, numeric owner and link target
   before an image starts on the new volumes. If a step fails after a volume
   was created, do not use that volume. Correct the cause and run this step
   again; it uses new names.

### Select and save the restored volumes

1. Write the restore overlay. It selects the previous image for both services
   and the restored volumes:

   ```sh
   printf '%s\n' \
     'services:' \
     '  openclaw:' \
     "    image: \"$IMAGE_REF\"" \
     '  cli:' \
     "    image: \"$IMAGE_REF\"" \
     'volumes:' \
     '  openclaw-state:' \
     '    external: true' \
     "    name: \"$NEW_OPENCLAW_VOLUME\"" \
     '  pretorin-state:' \
     '    external: true' \
     "    name: \"$NEW_PRETORIN_VOLUME\"" \
     > "$RESTORE_DIR/restored.yaml" &&
   mkdir -p "$(dirname "$RESTORE_OVERLAY")" &&
   cp "$RESTORE_DIR/restored.yaml" "$RESTORE_OVERLAY" &&
   SEPARATOR="$(record COMPOSE_PATH_SEPARATOR)" && SAVED_FILES="$(record COMPOSE_FILE)" &&
   printf 'COMPOSE_FILE=%s%s%s\nCOMPOSE_PROJECT_NAME=%s\n' \
     "${SAVED_FILES:-compose.yaml}" "${SEPARATOR:-:}" "$RESTORE_OVERLAY" "$PROJECT" &&
   echo "OK: save the two lines above in .env"
   ```

2. Save the two printed lines in the repository-root `.env`, as described in
   [Save deployment settings](../README.md#save-deployment-settings). Replace
   the old `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` lines. Keep the other
   lines. The restore overlay must be the last file. From now on, the saved
   selection names the restored volumes, so no Compose command can start an
   image on the candidate volumes. Keep the overlay at its stable path; a
   missing saved overlay stops Compose and each host script. Do not remove it to
   fall back to the original volumes.

3. Return the checkout to the recorded revision, so that the previous image
   uses the previous Compose files. Then check that a clean shell resolves the
   saved selection to the restored set, and that the host inputs did not
   change:

   ```sh
   SOURCE_REVISION="$(record SOURCE_REVISION)" && test -n "$SOURCE_REVISION" &&
   { test "$(git rev-parse HEAD)" = "$SOURCE_REVISION" ||
     (umask 022 && git switch --detach "$SOURCE_REVISION"); } &&
   unset COMPOSE_FILE COMPOSE_PATH_SEPARATOR COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPLIANCE_CLAW_SECRET_DIR &&
   docker compose --profile '*' config --format json |
     python3 -c "$SELECTION_CHECK" "$IMAGE_REF" "$NEW_OPENCLAW_VOLUME" "$NEW_PRETORIN_VOLUME" \
     > "$RESTORE_DIR/host-inputs.txt" &&
   cmp "$BACKUP_DIR/host-inputs.txt" "$RESTORE_DIR/host-inputs.txt" &&
   awk -F '\t' '$1 == "file" { print $2 }' "$RESTORE_DIR/host-inputs.txt" |
     while IFS= read -r f; do cmp -- "$f" "$(saved_input "$f")" || exit 1; done &&
   (set -f; IFS="${SEPARATOR:-:}"; for f in ${SAVED_FILES:-compose.yaml}; do
     test "$f" = "$RESTORE_OVERLAY" || tracked_at "$SOURCE_REVISION" "$f" ||
       cmp -- "$f" "$(saved_input "$f")" || exit 1; done) &&
   echo "OK: the saved selection uses $IMAGE_REF with the restored volumes"
   ```

   Git refuses the switch if local changes conflict. Keep local work; do not
   discard it to force the switch. `umask 022` keeps the usual mode on the files
   that Git writes; the gateway reads tracked files such as `targets.yaml`.
   A new login shell must give the same result. A difference in a declaration
   or a private overlay stops the step. Each saved copy is under `host-inputs/`
   at the full host path of its original; `saved_input FILE` prints that path.
   Copy the saved file back, or keep the current one only after you check that
   the restored state supports it. If the switch removed a file that was
   private at the backup, for example an overlay that the candidate revision
   added to Git, the block stops with `no such file or directory` for that
   path. Copy its verified saved copy back with
   `cp -p -- "$(saved_input FILE)" FILE` and run this block again. The
   comparison skips the restore overlay, because step 1 wrote it again for this
   restore.
   This output can contain private configuration; keep it local.

4. Reconcile credentials and access before the gateway starts. The gateway
   connects its configured channels when it starts, and the restored
   `openclaw-state` holds the grants from the backup time. A restore must not
   restore removed authority:

   - Keep the current secret files. Do not copy an old secret file back.
     Credentials that an issuer revoked stay revoked; get a new credential from
     the issuer if necessary.
   - The restored `openclaw-state` can hold an old model login. Sign in again if
     the provider rejects it.
   - List each authority removal after the backup time in `SET_ID` (UTC):
     `commands.ownerAllowFrom` entries, person links and roles. While the
     gateway is stopped, read the owner list with the `cli` service and set the
     list that is approved now:

     ```sh
     docker compose run --rm -T cli openclaw config get commands.ownerAllowFrom
     ```

     If the list is unset, the command says so and exits 1; the runtime default
     then applies. Use `openclaw config set commands.ownerAllowFrom` in the same
     way to change it. A person link or role changes only through an authenticated Gateway
     connection. If one was removed after the backup, disable Slack before the
     start:

     ```sh
     docker compose run --rm -T cli openclaw config set channels.slack.enabled false
     ```

     After step 5, remove the link or role as described in
     [Updating the Pretorin CLI](#updating-the-pretorin-cli). Then set
     `channels.slack.enabled` to `true` with `docker compose exec -T openclaw
     openclaw config set` and run `docker compose restart openclaw`.

5. Test the previous image with the restored state and no network. Then start
   the gateway and check that no running container uses the candidate state:

   ```sh
   docker run --rm --network none --platform linux/amd64 \
     --mount "type=volume,src=$NEW_OPENCLAW_VOLUME,dst=/home/node/.openclaw" \
     --mount "type=volume,src=$NEW_PRETORIN_VOLUME,dst=/home/node/.pretorin" \
     "$IMAGE_REF" pretorin version &&
   docker compose up -d --wait --wait-timeout 720 openclaw &&
   test "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q openclaw)")" = healthy &&
   docker compose exec -T openclaw pretorin version &&
   test -z "$(docker ps -q --filter "volume=$OPENCLAW_VOLUME")" &&
   test -z "$(docker ps -q --filter "volume=$PRETORIN_VOLUME")" &&
   echo "OK: $IMAGE_REF runs with the restored volumes"
   ```

   Do not rely on the exit status of the wait alone; the block checks the
   health status. If the status is still `starting`, read the gateway logs.
   When the gateway is healthy, run the lines from the health check to the end
   of the block.

   The active CLI version must be the version from the backup time, not the
   image seed. Check agent and channel settings, the managed Slack package and
   the effort records. Send a test request through the approved test channel
   before you return traffic. For effort records that moved to per-effort
   roots, use [Transfer existing effort records](#transfer-existing-effort-records).

The saved restore overlay selects the image. Do not run `scripts/update.sh`
while the overlay sets the image. To try the upgrade again later, make and
verify a new recovery set from the restored volumes. Then remove only the two
`image:` lines from the overlay; keep the volume lines. Return the checkout to
its branch with `git switch` before the update.

### What a restore does not recover

- **Changes after the backup.** The restored volumes have the state at backup
  time. Sessions, settings, model login refreshes, CLI updates, effort records
  and audit lines from a later time are not in them. They stay in the candidate
  volumes. Do not copy candidate files into the restored volumes: the candidate
  can have migrated their format.
- **External writes.** A local restore does not undo Pretorin platform writes or
  uploads. It does not delete remote copies, Slack messages or GitHub changes.
  Check the platform state before you resume a Plan from the restored records.
- **Credentials and access.** A restore does not reinstate revoked authority.
  A grant made after the backup is not in the restored config. Grant it again
  only if it is still approved. Reconcile each credential, person link and role
  with the current approval.
- **Host inputs.** Secret files, target clones and customer bind mounts are not
  in the archives. `host-inputs/` holds copies of declarations and private
  overlays, each at the full host path of its original, for comparison only.
- **Doctor captures.** At startup, OpenClaw Doctor can write a pre-repair copy
  of config and databases under `/home/node/.openclaw.update-captures/`. That
  path is in the container layer, not in a state volume. The volume backup does
  not include it, and a container recreation removes it. Do not use it for
  recovery; use the paired volume backup.
- **Image-only rollback.** The previous image with the candidate volumes is not
  a rollback. An old image cannot reverse a migration of the config or SQLite
  schema. A copy of `openclaw.json` alone is not a full state backup. Recover
  the compatible pair: the recorded image with state restored from its set.

Keep the candidate volumes and the restore directory until you finish the
diagnosis. Remove a volume only by its exact name, after you check that no
recovery set or running deployment needs it. No script renames, adopts,
catalogues or removes volumes.

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
