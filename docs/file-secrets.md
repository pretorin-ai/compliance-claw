# File-backed runtime secrets

`compose.secrets.yaml` is the cloud-compatible credential path. It mounts
credentials as files under `/run/secrets` and the image entrypoint exports them
only inside the running process tree. Docker therefore does not receive secret
values in the container's configured environment, keeping them out of
`docker inspect .Config.Env`.

This protects secret delivery, not a compromised running process. OpenClaw must
still use the values, and provider errors may log a masked credential fingerprint
(an OpenAI invalid-key response was observed to include the key's prefix and
suffix). Protect and redact runtime logs accordingly.

The existing `.env` path remains available for backward compatibility. Do not
combine the two: the entrypoint refuses a secret supplied both directly and by a
`*_FILE` variable.

**Requires Docker Compose v2.27.2 or newer.** The host selection helper needs
`docker compose config --environment`, added in v2.27.2. The overlay uses the
`!reset` tag to drop the base file's `env_file`, introduced in v2.24.0. An older
Compose does not fail closed in a way that names the cause — it reports a schema
error on `env_file`, or silently keeps the base value on versions that ignore
unknown tags, which would put `.env` secrets back into `docker inspect` while the
mounted files were also present. Check with `docker compose version` before
deploying, and note this when provisioning the Azure VM, where the distribution's
packaged Compose is often older than Docker Desktop's.

## Local proof before Azure

For contributor testing, use the [isolated setup](../CONTRIBUTING.md#isolated-container-testing).
The commands below operate on the selected deployment; they are not an isolated
test environment.

Prepare files without replacing anything already present:

```sh
scripts/init-file-secrets.sh --from-env
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.build.yaml   # or save it in .env; see README "Save deployment settings"
docker compose build
docker compose up -d
scripts/test-file-secrets.sh compliance-claw:local
```

`--from-env` copies any existing Pretorin and Slack values from `.env` without
printing them. It also creates empty files for unconfigured model providers.
Without `--from-env`, it creates empty optional files and generates a fresh
gateway token.

The local helper keeps the parent directory private (`0700`). On macOS, where
the host user normally is not UID 1000, it grants read permission on the mounted
file itself so the image's non-root `node` process can consume it; other host
users still cannot traverse the private parent directory. Docker administrators
remain trusted, as they are with every bind mount.

Only non-secret deployment settings are interpolated from `.env` in this mode:

- `SLACK_CHANNEL_ID` — **legacy single-effort only.** Once `efforts.yaml` exists,
  each effort carries its own `slack_channel_id` and this variable is ignored (the
  container says so on start).
- target and model selection performed by their existing configuration flows

Host-side GitHub App identifiers and its private-key path may remain in `.env`
for `scripts/bootstrap.sh`; the overlay does not forward them into either
container.

## The checklist — every secret file, in one place

This table is the single source of truth for what to populate. `.env.example`
points here rather than restating it, so the two cannot drift.

| Host file under `secrets/runtime/` | Runtime variable | Required? | Delivered to |
| --- | --- | --- | --- |
| `pretorin-api-key` | `PRETORIN_API_KEY` | for any platform access | `openclaw`, `cli` |
| `openclaw-gateway-token` | `OPENCLAW_GATEWAY_TOKEN` | default token authentication; empty for native proxy authentication | `openclaw` only |
| `openclaw-gateway-password` | `OPENCLAW_GATEWAY_PASSWORD` | optional native local maintenance credential | `openclaw` only |
| `slack-app-token` | `SLACK_APP_TOKEN` | only for Slack — **both tokens together** | `openclaw`, `cli` |
| `slack-bot-token` | `SLACK_BOT_TOKEN` | only for Slack — **both tokens together** | `openclaw`, `cli` |
| `openai-api-key` | `OPENAI_API_KEY` | model API-key mode; one selected provider | `openclaw` only |
| `anthropic-api-key` | `ANTHROPIC_API_KEY` | model API-key mode; one selected provider | `openclaw` only |
| `github-readonly-pat` | *(none — see below)* | only to sync a **private** target from Slack | `openclaw` only |

**Slack needs two files here, not three.** On the multi-effort path those two
tokens are the whole of what this table owns: which channels are served comes from
each effort's `slack_channel_id` in `efforts.yaml`, which `scripts/clawctl apply`
writes into the gateway configuration. `SLACK_CHANNEL_ID` is **legacy
single-effort only** — it is not a secret and stays in `.env`, and setting it
alongside an `efforts.yaml` is ignored with a message rather than honoured, so
there is exactly one owner of the channel allowlist.

The host-side GitHub App identifiers and private-key path also stay in `.env`;
the overlay does not forward them into either container.

An empty optional file supplies no value. OpenClaw configuration selects and
validates authentication; secret-file contents do not select a mode.
Native token mode can generate a runtime token when none is configured. Default
initialization still creates a persistent token. Native password mode rejects
a missing password.

### Delivery is least privilege, not convenience

One workflow, different reach. A service receives a credential only if it needs
it, and the two exclusions are the interesting part:

### `github-readonly-pat` is the one secret with no environment variable

Every other row above is read by the entrypoint and **exported into PID 1's
environment**, because OpenClaw and the Pretorin MCP child consume environment
variables — which means the agent's tool execution inherits them.

The PAT is not. It is consumed by a git credential helper that reads the mounted
path at the moment git asks, so it never has to become an environment variable,
and it is deliberately absent from the entrypoint's `load_secret_file` list.
There is no `GITHUB_READONLY_PAT_FILE`; `scripts/smoke.sh` fails if one appears.

**Be honest about what that buys.** It keeps the token out of `docker inspect`,
out of every child process's environment, and out of anything that dumps `env`.
It does **not** put it out of reach of a prompt-injected agent: tool execution in
this container is unsandboxed and runs as the same uid, so the file is readable.
The real containment is on GitHub's side — make it fine-grained, limited to the
selected repositories, with **Contents: Read-only** and nothing else. The GitHub
App remains the recommended mechanism for anything past the internal pilot.

Leave the file **empty** if you have no private targets. Empty means "no
credential"; a private target then reports `auth_failed` and names both fixes.

### Upgrading a deployment that predates a secret

Compose resolves every secret source when the container is created, and a
missing file is a hard failure — `bind source path does not exist`, container
never created — not a warning. So after pulling a release that adds one:

```sh
scripts/init-file-secrets.sh      # write-if-absent; never overwrites a value
```

`scripts/bootstrap.sh` already does this, and `scripts/update.sh` does it after
the fast-forward and **before it stops anything**, so an upgrade cannot turn into
an outage over a credential the deployment does not even use.

| Excluded from `cli` | Why |
| --- | --- |
| model API keys | agent turns run only in the gateway. Handing a one-off container a provider credential gives it spend authority it has no use for. |
| gateway token and password | local authenticated requests run with `exec` inside the gateway. The one-off `cli` service receives neither credential. |
| `github-readonly-pat` | only the gateway carries the target-sync routes, and only the gateway has the writable maintenance mount. A git credential in a container with nothing to use it on is pure exposure. |

Use the running gateway for local authenticated requests. Native authentication
still applies. `scripts/test-file-secrets.sh` asserts this matrix directly: it plants a
distinct canary in every secret file and checks that each container sees exactly
its allowed set **and nothing more**, so over-delivery fails the gate rather than
going unnoticed.

### The model credential needs no variable

For model API-key mode, populate the file for the selected provider:
`openai-api-key` or `anthropic-api-key`. Device-code login instead stores its
credential in OpenClaw state; see [model setup](../README.md#the-model). For an
OpenAI API key, the entrypoint derives the OpenAI request adapter
(`models.providers.openai.api`) from whether an OpenAI key is visible, and exports
it on every start, so the config carries a `${OPENAI_REQUEST_ADAPTER}` marker
rather than a baked value.

That indirection is load-bearing. Deciding the adapter when the config is *seeded*
does not work: the documented order runs `scripts/clawctl apply` before the
gateway exists, which seeds from the `cli` service — and `cli` deliberately has no
model key. A seed-time choice was therefore made by a container that could
not see the credential, and never-clobber then locked the wrong value in for the
life of the volume. Resolving per process removes the dependency instead of
widening the credential's reach.

An unset marker does not fall back to a default; it makes the whole config
invalid. The export is unconditional for that reason.

## Native proxy authentication and local maintenance

The default installation still uses a gateway token. An existing deployment can
use the pinned OpenClaw `trusted-proxy` authentication configuration after its
administrator supplies an authenticated proxy. This repository does not deploy
that proxy, choose an identity service, assign roles, or change network rules.

Back up the configuration and both state volumes before a mode change. Keep the
saved Compose selection and secret directory. Use supported native configuration
commands; a file replacement is not a canonical configuration update. Remove
`gateway.auth.token` completely, including a retained `${OPENCLAW_GATEWAY_TOKEN}`
reference. Set `gateway.auth.mode` to `trusted-proxy` and configure the native
proxy trust, identity headers and allowed origins. A TLS reverse proxy alone does
not establish identity. Restrict direct remote Gateway access to the proxy.

Keep `openclaw-gateway-token` present but empty. Initialization preserves an
existing empty file; it generates a token only when that file is absent. Empty
files do not change native authentication settings. An unresolved token reference
can still prevent startup after the mode changes.

For native local maintenance, put a password in `openclaw-gateway-password` with
the documented file permissions and set `gateway.auth.password` to the literal
`${OPENCLAW_GATEWAY_PASSWORD}` reference. Keep values out of configuration and
command arguments. Recreate the selected gateway to refresh file mounts. The
entrypoint and `clawctl` load the password inside that container. Local requests
use native password authentication without proxy identity headers. This password
is a shared VM maintenance credential, not an individual team identity.

Verify startup and a local authenticated request before granting team access.
The isolated `scripts/test-proxy-auth.sh` checks native startup and configuration
requests with a canary password; it does not prove a deployed proxy, sign-in,
role policy, or the complete multi-effort onboarding flow.

For rollback, use native commands to restore the previous authentication settings
and their matching credential files, then recreate only the selected gateway with the same
volumes and Compose selection. Do not restore revoked credentials or use
`down -v`. No startup script converts or overwrites retained auth settings.

## `docker compose exec` does not see these secrets

The entrypoint reads `/run/secrets/*` and exports them, so **PID 1** — the
gateway — has them. An `exec`'d process is a child of the Docker daemon, not of
PID 1, so it starts with none of those exports. This is the file-secret design
working as intended, and it is also a footgun worth knowing before you hit it.

It matters for any `exec` that loads the config, because
`gateway.auth.token` is a `${OPENCLAW_GATEWAY_TOKEN}` reference resolved at load
time. With the variable unset you get:

```
GatewaySecretRefUnavailableError: gateway.auth.token is configured as a secret
reference but is unavailable in this command path.
```

That is not a missing model key and not a broken token — it is an unset
variable. Re-read it from the mounted file **inside** the container, so the value
never crosses the `docker` CLI boundary:

```sh
docker compose exec -T openclaw sh -c '
  export OPENCLAW_GATEWAY_TOKEN="$(cat /run/secrets/openclaw_gateway_token)"
  exec openclaw agent --agent "$1" -m "your prompt"' sh crm-soc2
```

Replace `crm-soc2` with a configured effort agent name. The gateway must be
running. This example is for token authentication on the file-secret path. With
native proxy authentication, load `OPENCLAW_GATEWAY_PASSWORD` from
`/run/secrets/openclaw_gateway_password` instead. `clawctl` reloads both configured
file sources and refuses a missing, unreadable, or conflicting source.

Do **not** use `docker compose exec -e OPENCLAW_GATEWAY_TOKEN="$(cat ...)"`: that
reads the secret on the host and puts it in an argument list, which is visible to
`ps` for the life of the call.

Checking what the gateway actually resolved is a different question, and
`exec env` cannot answer it — read PID 1's own environment:

```sh
docker compose exec -T openclaw sh -c 'tr "\0" "\n" < /proc/1/environ | grep OPENAI_REQUEST_ADAPTER'
```

Reading it any other way is how an earlier round of this work "observed" an empty
adapter and went looking for a bug that was not there.

## Azure pilot mapping

The current internal pilot does **not** implement Key Vault synchronization.
Create the same files on the VM's persistent disk, restrict the parent directory
to the operator, and point Compose at it. For example:

```text
/opt/compliance-claw-secrets/
```

Save the selection in the repository-root `.env`, then start:

```dotenv
COMPOSE_FILE=compose.yaml:compose.secrets.yaml
COMPLIANCE_CLAW_SECRET_DIR=/opt/compliance-claw-secrets
```

```sh
docker compose up -d
```

The host files must be readable by the image's `node` user (UID/GID 1000) and
must not be readable by other host users. Create the directory as `0700` and
each file as `0400`, owned by `1000:1000`. Anyone with root or Docker-daemon
access remains inside the workload trust boundary. Do not put these files under
`/run` for the pilot: `/run` is recreated at boot and there is currently no
service that repopulates it.

A production deployment may later use the VM's managed identity and Azure Key
Vault to recreate the same filenames under `/run/compliance-claw-secrets/` before
Compose starts. That automation is planned, not shipped by this repository.

Enable Docker itself to start on boot. The gateway declares
`restart: unless-stopped`, so once Docker is up Compose restores the container
with the secret mounts it already had. Nothing is restored if the container was
stopped deliberately, or if `docker compose down` removed it; in that case run
`docker compose up -d` again. The saved `.env` selection supplies the files and
the secret directory in any shell.

The GitHub App private key is intentionally different: it stays host-only and is
used by `scripts/bootstrap.sh` to clone private targets. It is never declared as
a Compose secret or mounted into the agent container.

## Rotation

A changed file, a process that uses the replacement, and issuer revocation are
three separate results. Running processes keep values loaded at startup or MCP
child creation. `check_context` reads local context; it does not authenticate.

Use this sequence for the file-secret path. The VM operator changes the files;
the service owner supplies and revokes credentials. Schedule an interruption.

1. Confirm the current Compose files, project, secret directory and both state
   volumes. Keep the same image and volume selection. Use the
   [stopped-state backup procedure](upgrade.md) where recovery is required.
2. Obtain a replacement with the required issuer scopes. For Pretorin, check
   the affected effort's `credential_ref`: `default` uses `pretorin-api-key`;
   a named reference uses `pretorin/<name>`. List all efforts that share that
   reference. Do not change a different effort's file or put a value in argv,
   `.env`, gateway configuration or a support report.
3. Prepare the replacement beside the current file. Keep the current owner and
   the documented file and parent-directory modes. Use an approved secret-input
   method, then rename the replacement over the current file on the same
   filesystem. Do not truncate the current file in place. `clawctl credential
   add` is write-if-absent; it does not replace an existing value.
4. Recreate the gateway with the same Compose selection:

   ```sh
   docker compose stop --timeout 330 openclaw
   docker compose up -d --force-recreate --wait --wait-timeout 720 openclaw
   ```

   Keep both volumes; do not use `down -v`. Recreation refreshes individual
   file bind mounts and starts new gateway/MCP processes. A running individual
   bind mount can still refer to the old file after atomic replacement. A named
   key directory can expose the new file to a new child, but an existing child
   still uses its loaded value. Do not use either fact as activation proof.
   `--wait` checks native health; adjust its finite startup allowance for the
   supported deployment if needed. Health alone does not verify a service key.
5. Through each affected effort's running Pretorin MCP, make a harmless
   authenticated system read and confirm the expected system. Use the selected
   model/Slack service's equivalent check for those credentials. A separate CLI
   process proves only its own credential; it does not prove a retained MCP
   child changed. Device-code model login and gateway access/session removal
   have their own lifecycle and are not rotated by a Pretorin file change.
6. After the replacement works, revoke the old credential at its issuer. Use
   the issuer's audit or an approved isolated client to confirm that the old
   authority is rejected and the replacement still works. Do not reinstall an
   old credential in Claw merely to check rejection. Restart is not revocation.

If readiness or authentication fails, keep the old credential valid only when
safe, stop affected work and check the selected file, permissions, issuer scope
and new process generation. Correct the file and recreate again. Do not fall
back to another effort's key or a direct environment value. For a compromised
credential, revoke first, accept an interruption, then replace, recreate and
verify. Never restore revoked authority as a recovery step.

Revocation stops future authorized reads when it takes effect. It does not erase
prior copies in sessions, memory, logs, evidence, providers or backups. The VM
and service owners must apply their retention/deletion rules to those copies;
protect recovery archives as described in [upgrade and recovery](upgrade.md).
Treat logs as sensitive: an upstream error can include a masked key fingerprint.
Review logs before sharing them; this procedure does not promise automatic
redaction or deletion of prior evidence.

`scripts/test-effort-credentials.sh` uses the real launcher and CLI seed against
an isolated synthetic issuer. It checks old loaded children, replacement mounts,
new authenticated children and revocation. It does not rotate a real credential
or prove live provider, Slack or issuer behavior.

Host initialization and credential commands also use the saved non-secret
selection. See [Save deployment settings](../README.md#save-deployment-settings)
for the shared directory, ordered files and explicit override rules.
