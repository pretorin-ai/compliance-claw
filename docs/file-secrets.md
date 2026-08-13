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

- `PRETORIN_KEY_MODE`
- `SLACK_CHANNEL_ID`
- target and model selection performed by their existing configuration flows

Host-side GitHub App identifiers and its private-key path may remain in `.env`
for `scripts/bootstrap.sh`; the overlay does not forward them into either
container.

The six runtime secret files are:

| Host filename | Runtime variable |
| --- | --- |
| `pretorin-api-key` | `PRETORIN_API_KEY` |
| `openclaw-gateway-token` | `OPENCLAW_GATEWAY_TOKEN` |
| `slack-app-token` | `SLACK_APP_TOKEN` |
| `slack-bot-token` | `SLACK_BOT_TOKEN` |
| `openai-api-key` | `OPENAI_API_KEY` |
| `anthropic-api-key` | `ANTHROPIC_API_KEY` |

Provider API keys are mounted only into the long-running gateway service. The
CLI service receives Pretorin, gateway and optional Slack credentials because
its diagnostics and configuration commands use them, but it does not receive
model API keys.

Empty optional files mean that provider is not configured. The gateway token is
required when starting the gateway; an empty file fails closed.

## Azure mapping

On the Azure VM, a root-owned startup service will authenticate to Key Vault
with the VM's managed identity and create the same filenames under:

```text
/run/compliance-claw-secrets/
```

The directory is RAM-backed and recreated after every boot. Start with:

```sh
export COMPOSE_FILE=compose.yaml:compose.secrets.yaml
export COMPLIANCE_CLAW_SECRET_DIR=/run/compliance-claw-secrets
docker compose up -d
```

The host files must be readable by the image's `node` user (UID/GID 1000) and
must not be readable by other host users. The Azure sync service should create
the directory as `0700` and each file as `0400`, owned by `1000:1000`. Anyone
with root or Docker-daemon access remains inside the workload trust boundary.

The GitHub App private key is intentionally different: it stays host-only and is
used by `scripts/bootstrap.sh` to clone private targets. It is never declared as
a Compose secret or mounted into the agent container.

## Rotation

Update the backing files atomically, then restart the gateway:

```sh
docker compose restart openclaw
```

Azure will replace the local files from the latest Key Vault secret versions
before this restart. File changes are not automatically re-read by an already
running process.
