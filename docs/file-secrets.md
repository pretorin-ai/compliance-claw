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

**Requires Docker Compose v2.24.0 or newer.** The overlay uses the `!reset` tag to
drop the base file's `env_file`, and that tag was introduced in v2.24.0. An older
Compose does not fail closed in a way that names the cause — it reports a schema
error on `env_file`, or silently keeps the base value on versions that ignore
unknown tags, which would put `.env` secrets back into `docker inspect` while the
mounted files were also present. Check with `docker compose version` before
deploying, and note this when provisioning the Azure VM, where the distribution's
packaged Compose is often older than Docker Desktop's.

## Local proof before Azure

Prepare files without replacing anything already present:

```sh
scripts/init-file-secrets.sh --from-env
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml:compose.build.yaml
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

- `SLACK_CHANNEL_ID`
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
| `openclaw-gateway-token` | `OPENCLAW_GATEWAY_TOKEN` | **yes** — the gateway exits 1 without it | `openclaw` only |
| `slack-app-token` | `SLACK_APP_TOKEN` | only for Slack (all three together) | `openclaw`, `cli` |
| `slack-bot-token` | `SLACK_BOT_TOKEN` | only for Slack | `openclaw`, `cli` |
| `openai-api-key` | `OPENAI_API_KEY` | **exactly one** model key | `openclaw` only |
| `anthropic-api-key` | `ANTHROPIC_API_KEY` | **exactly one** model key | `openclaw` only |
| `github-readonly-pat` | *(none — see below)* | only to sync a **private** target from Slack | `openclaw` only |

`SLACK_CHANNEL_ID` is the third Slack value and is **not** a secret — it stays in
`.env`, along with the host-side GitHub App identifiers and private-key path,
which the overlay does not forward into either container.

An empty optional file means that provider is simply not configured. The gateway
token is the one that fails closed.

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
| `openclaw-gateway-token` | the entrypoint requires it only for gateway invocations, and `cli` is one-off by Compose profile. Without it, `cli` cannot start a second gateway against the same volumes. |
| `github-readonly-pat` | only the gateway carries the target-sync routes, and only the gateway has the writable maintenance mount. A git credential in a container with nothing to use it on is pure exposure. |

If a `cli` invocation ever genuinely needs the gateway token, the entrypoint
refuses with a message naming the file to mount, rather than failing somewhere
deeper. `scripts/test-file-secrets.sh` asserts this matrix directly: it plants a
distinct canary in every secret file and checks that each container sees exactly
its allowed set **and nothing more**, so over-delivery fails the gate rather than
going unnoticed.

### The model credential needs no variable

Populate exactly one of `openai-api-key` or `anthropic-api-key`. Nothing else is
required: the entrypoint derives the OpenAI request adapter
(`models.providers.openai.api`) from whether an OpenAI key is visible, and exports
it on every start, so the config carries a `${OPENAI_REQUEST_ADAPTER}` marker
rather than a baked value.

That indirection is load-bearing. Deciding the adapter when the config is *seeded*
does not work: the documented order runs `scripts/onboard-targets.sh` before
`docker compose up`, which seeds from the `cli` service — and `cli` deliberately
has no model key. A seed-time choice was therefore made by a container that could
not see the credential, and never-clobber then locked the wrong value in for the
life of the volume. Resolving per process removes the dependency instead of
widening the credential's reach.

An unset marker does not fall back to a default; it makes the whole config
invalid. The export is unconditional for that reason.

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
  openclaw agent --agent main -m "your prompt"'
```

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

Start with:

```sh
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml
export COMPLIANCE_CLAW_SECRET_DIR=/opt/compliance-claw-secrets
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

This repository also does not yet install a system service that restarts Compose
after a VM reboot. For the pilot, re-export the two variables above and run
`docker compose up -d` after reboot. Automatic boot recovery belongs in the
deployment-hardening work, alongside Key Vault integration.

The GitHub App private key is intentionally different: it stays host-only and is
used by `scripts/bootstrap.sh` to clone private targets. It is never declared as
a Compose secret or mounted into the agent container.

## Rotation

Update the backing files atomically, then restart the gateway:

```sh
docker compose restart openclaw
```

For the pilot, replace the persistent host files yourself. A future Key Vault
sync service would replace them from the latest secret versions before this
restart. File changes are not automatically re-read by an already running
process.
