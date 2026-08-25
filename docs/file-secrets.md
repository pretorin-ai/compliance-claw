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

`SLACK_CHANNEL_ID` is the third Slack value and is **not** a secret — it stays in
`.env`, along with the host-side GitHub App identifiers and private-key path,
which the overlay does not forward into either container.

An empty optional file means that provider is simply not configured. The gateway
token is the one that fails closed.

### Delivery is least privilege, not convenience

One workflow, different reach. A service receives a credential only if it needs
it, and the two exclusions are the interesting part:

| Excluded from `cli` | Why |
| --- | --- |
| model API keys | agent turns run only in the gateway. Handing a one-off container a provider credential gives it spend authority it has no use for. |
| `openclaw-gateway-token` | the entrypoint requires it only for gateway invocations, and `cli` is one-off by Compose profile. Without it, `cli` cannot start a second gateway against the same volumes. |

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
