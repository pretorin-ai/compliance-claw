# Administrator guide

Use this guide for routine administration of the pinned OpenClaw runtime.
Start with the [Quickstart](../README.md#quickstart) for installation. The
[effort guide](efforts.md) owns declarations and apply rules;
[file-secret guide](file-secrets.md) owns credential delivery and rotation;
[upgrade guide](upgrade.md) owns state backup and recovery.

## Duties and handoff

| Role | Tasks and access |
| --- | --- |
| VM operator | Host access; image/Compose selection, network, state and backup; effort creation and scope, declared repositories, mounted Pretorin/model credentials and custom AI endpoints. |
| Claw administrator | Native Control UI; provider/model controls, unowned external MCP connections, matching agent settings and workspace files. No SSH access is required or granted by this guide. Request the operator for host-owned changes. |

This duties split is not an implemented permission boundary. See [SECURITY.md](../SECURITY.md)
and the selected access policy before team use. An image pull or healthy gateway
does not prove model, Pretorin, channel or individual access works.

The operator provisions efforts with `efforts.yaml`, named credentials and
`clawctl`. Follow the [existing effort procedure](efforts.md); native New agent
alone does not establish a scoped compliance effort. Slack is optional. Before
handoff, run schema validation, plan and full apply; give the administrator the
private UI address, declared agent names and the expected credential sources.

`clawctl apply` prepares native state itself when the gateway is stopped. Do not
add a manual Doctor workaround. Preparation can change native configuration
before the effort transaction takes its snapshot. A later effort failure does
not mean those earlier native changes were undone. Keep its diagnostics.

## Operator handoff checklist

The VM operator completes these items before handoff. Each row names the result
to check and the guide that owns the procedure. Do not skip a row because the
gateway is healthy.

| Item | Required result | Procedure |
| --- | --- | --- |
| Host | Linux VM with Docker Engine, Compose 2.27.2 or newer and `linux/amd64` support; `git`, `python3` and `openssl` on the host; Docker starts at boot. | [Requirements](../README.md#requirements) and [VM secret files](file-secrets.md#azure-pilot-mapping) |
| Image-pull trust | The host Docker daemon can pull the pinned digest. The registry credential stays in the host Docker login. No container receives it. | [Image verification](image-verification.md) |
| Container application trust | Pretorin, model, Slack and GitHub credentials are files in the secret directory with the documented owner and mode. They are separate from the registry credential. | [Secret checklist](file-secrets.md#the-checklist--every-secret-file-in-one-place) |
| Saved selection | `.env` holds the Compose files, project and secret directory. Private overlays come last. | [Save deployment settings](../README.md#save-deployment-settings) |
| Private gateway access | The gateway port stays published on `127.0.0.1` only. People reach it through an SSH tunnel or a customer TLS proxy. Do not publish it on all interfaces. | Text after this table |
| Native authentication | The default token, or the native trusted-proxy mode with its local maintenance password. | [Native proxy authentication](file-secrets.md#native-proxy-authentication-and-local-maintenance) |
| Allowed origins | `gateway.controlUi.allowedOrigins` lists each exact browser origin (scheme, host and port). The seed allows `http://127.0.0.1:18789` and `http://localhost:18789` only. | Text after this table |
| Trusted proxy, where used | Native proxy trust, identity headers and allowed origins are set. Only the proxy can reach the gateway port. | [Native proxy authentication](file-secrets.md#native-proxy-authentication-and-local-maintenance) |
| Network approvals | Each required connection in [Network connections](#network-connections) is approved for its purpose. | [Network connections](#network-connections) |
| Efforts | Schema validation, plan and full apply pass. | [Effort procedure](efforts.md#the-main-event-adding-a-second-effort) |
| Model | Test connection and an approved agent turn pass with the expected model. | [Providers and models](#providers-and-models) |
| Recovery | A stopped-state backup of both volumes was made and restored into test volumes. | [State backup](upgrade.md#openclaw-image-upgrade-and-state-backup) |
| Handoff record | The administrator has the private UI address, agent names, credential sources, network approvals and the retention owners in [Retained copies](#retained-copies-and-removal). | This guide |

An SSH tunnel that uses the same local port keeps the seeded origin, for
example `ssh -N -L 18789:127.0.0.1:18789 <operator>@<vm-host>`. A different
local port, host name or HTTPS proxy is a different origin. Set the complete
list with native configuration; the pinned OpenClaw refuses `--merge` for this
list. Keep the existing origins that people still use:

```sh
docker compose exec -T openclaw /usr/local/bin/compliance-claw-entrypoint \
  openclaw config set gateway.controlUi.allowedOrigins \
  '["http://127.0.0.1:18789","http://localhost:18789","https://<claw-host>"]' \
  --strict-json --replace
```

Then reconnect and check that the Control UI loads and authenticates. A tunnel
or proxy changes the network path only. It does not add a user identity.

### If a setup stage fails

Keep the failed state and its messages. Do not delete a volume to retry.

| Stage | First check | Next action |
| --- | --- | --- |
| Registry login or pull | The `docker compose pull` error | [Troubleshooting](../README.md#troubleshooting) registry rows; [image verification](image-verification.md) |
| `scripts/bootstrap.sh` | The prerequisite or target that the message names | Correct it, then run the script again. It is idempotent. |
| Secret files | File names, owner and mode | [Secret checklist](file-secrets.md#the-checklist--every-secret-file-in-one-place) |
| `clawctl validate` or `plan` | The effort row status | [Check an effort](efforts.md#3-check-it) |
| `clawctl apply` | Its diagnostics and rollback result | [Ownership rules](efforts.md#what-apply-does-to-the-openclaw-configuration); keep the diagnostics |
| Gateway health | `docker compose ps -a` and `docker compose logs --tail 200 openclaw` | [Troubleshooting](../README.md#troubleshooting); [recovery](upgrade.md#openclaw-image-upgrade-and-state-backup) |
| Model turn | Test connection, then the gateway log | [Providers and models](#providers-and-models); [internal AI endpoint](#internal-ai-endpoint-with-a-private-ca) |
| Pretorin access | `scripts/clawctl validate` probe rows | [Key permissions](../README.md#read-only-vs-write-enabled-keys) |
| Slack | Gateway Slack log lines | [Optional Slack](#optional-slack) |
| Update | The message and exit code of `scripts/update.sh` | [Routine deployment update](upgrade.md#routine-deployment-update). The first update to an image with per-effort Plan and preflight roots also needs the manual [record transfer](upgrade.md#transfer-existing-effort-records) before start. |

If the next action does not correct the fault, collect
[support diagnostics](#support-diagnostics).

## Setting ownership and checks

These paths were checked in the pinned 2026.10.5 UI and local fixtures. A visible
credential control or successful save is not live service authentication.

| Setting | Role and edit path | Storage/owner | Check |
| --- | --- | --- | --- |
| Effort scope, repository URL/ref, Pretorin credential reference, optional channel | Operator: `efforts.yaml` and `clawctl` | Host declaration and generated wiring | Schema, plan, full apply and approved scoped probe; inspect declared target commits. |
| Mounted credentials | Operator: existing file-secret procedure | Host secret files; loaded by runtime processes | Follow the delivery/rotation checks in the secret guide; never display values. |
| Provider/default model and thinking | Claw administrator: `/settings/model-providers` | Native config/auth profiles in `openclaw-state`; mounted keys remain operator-owned | Check the credential source, API/model, Test connection, then an approved agent turn. |
| Agent display name, identity and model override | Claw administrator: `/settings/agents/<effort>/overview`, then Save | Native matching agent entry and identity file | Reconnect, inspect the selected agent, then repeat after apply. |
| Unowned external MCP | Claw administrator: `/settings/mcp` | Native `mcp.servers`, outside the managed `pretorin-` names | Save, reconnect and probe; verify an approved harmless external read separately. |
| Persona and memory files | Claw administrator: agent Files (`/settings/agents/<effort>/files`) | Displayed agent workspace in `openclaw-state` | Save, reopen and check file content after maintenance. |
| Generated AGENTS and target links | Operator: declaration/template and full apply | Generated effort workspace | Inspect plan/apply and generated instructions; direct edits are replaced. |
| Native agent tool settings and administrator denies | Authorized administrator: native controls where exposed; operator fallback otherwise | Matching declared agent entry, subject to generated ownership | Read back and check after apply; retention alone does not prove containment. |

Apply retains valid native fields for matching declared IDs. The declaration
owns membership, workspace/agent directory and generated wiring. Undeclared
agent entries are not retained as compliance efforts. Read the full
[ownership rules](efforts.md#what-apply-does-to-the-openclaw-configuration),
including generated cross-effort denies and owned-field conflicts. Do not edit
native configuration while apply runs. Use persona or MEMORY files for retained
notes; apply replaces generated `AGENTS.md` and target links. Removing wiring
does not erase old workspaces, sessions or backups.

## Providers and models

`MODEL` in `versions.env` sets the fresh config's build-time default. Changing
that seed needs a rebuild. Existing deployments can select a runtime model
without rebuilding; `.env` does not provide a runtime model override. Supplying
a provider credential does not silently select its model.

In `/settings/model-providers`, review Defaults for all agents and the selected
agent's provider access. The page offers model/thinking controls, Test connection
and provider key controls. Agent-specific values override the global defaults.
Use the agent Overview primary-model control for one effort. Wait for save and
reconnect before another edit; a native config reload can disconnect the page.

The operator configures a custom AI endpoint through supported native config
when the UI does not expose that setup. Check the request API, base URL, model
catalog/ID, context limits and credential source. Keep normal TLS verification.
For an endpoint with a private CA, use the
[internal AI endpoint example](#internal-ai-endpoint-with-a-private-ca).
A compatible chat route does not establish embedding/search or tool quality.
Do not call memory engine, import, embedding or OAuth behavior verified merely
because its controls are present.

File-mounted OpenAI/Anthropic keys and native auth-profile credentials are
separate sources. Select the intended source and follow the
[file-secret guide](file-secrets.md); a Claw administrator must request the
operator to change a mounted file. Do not add a competing source to hide an
authentication error. No model credential is built into the image.

A local fixture tested native connection/routing and saved settings. For real
use, run Test connection and an approved agent turn with the expected model.
A saved key, auth-list row or healthy gateway is insufficient. Real provider
login/key replacement was not established by the local fixture.

## Internal AI endpoint with a private CA

Use this example for an internal OpenAI-compatible endpoint whose TLS
certificate comes from a private certificate authority (CA). The gateway Node
process sends the model requests, so the gateway must trust that CA. The image
does not trust a private CA.

The example uses the native `models.providers.<id>.request.tls.ca` setting. It
applies to that one provider. Its value is the complete CA list for that
provider: it replaces the default public CA list for those requests and does not
change other gateway connections. Put every CA certificate that the endpoint
chain needs in the file. Keep TLS verification on. The pinned OpenClaw accepts
`insecureSkipVerify: true` in configuration, then refuses to prepare the model
runtime; the gateway stays unhealthy until you remove that field and recreate
the gateway.

The files are in [`examples/internal-ai-ca/`](../examples/internal-ai-ca/): a
private Compose overlay and a native configuration patch. They contain
placeholders, no credential and no private name.

1. Get the approved CA certificate (PEM) and the endpoint credential from the
   endpoint owner. The host name in the endpoint URL must be a name in the
   endpoint certificate.
2. Put the CA file at a private host path. Put the credential in the secret
   directory as `internal-ai-api-key`. Both files must belong to UID 1000 and
   have an owner-only mode, `0400` or `0600`. OpenClaw file references refuse a
   file that the group or other users can read. For example:

   ```sh
   sudo install -o 1000 -g 1000 -m 0400 ca.pem /opt/compliance-claw-trust/internal-ai-ca.pem
   ```

   Deliver the credential with an approved secret-input method, as in the
   [secret guide](file-secrets.md#internal-ai-endpoint-credential).
3. Copy `compose.internal-ai-ca.yaml` to a private path. Add it last to the saved
   `COMPOSE_FILE` and add `INTERNAL_AI_CA_FILE=<private CA path>` to `.env`.
   Run `docker compose --profile '*' config` and check the CA mount on both
   services, the credential on `openclaw` only, both state volumes and the
   loopback port. Compose stops if `INTERNAL_AI_CA_FILE` is missing.
4. Recreate the gateway with the same selection:

   ```sh
   docker compose stop --timeout 330 openclaw
   docker compose up -d --force-recreate --wait --wait-timeout 720 openclaw
   ```

5. Copy `internal-ai.patch.json5` to a private path. Replace the endpoint URL
   and the model ID and limits. Apply it through the running gateway, first as
   a dry run:

   ```sh
   docker compose exec -T openclaw /usr/local/bin/compliance-claw-entrypoint \
     openclaw config patch --stdin --dry-run < /private/path/internal-ai.patch.json5
   docker compose exec -T openclaw /usr/local/bin/compliance-claw-entrypoint \
     openclaw config patch --stdin < /private/path/internal-ai.patch.json5
   ```

   A dry run in the one-off `cli` service fails because the credential is
   mounted on the gateway only. This is expected.
6. Select the model with the agent Overview control, or set the global default
   with the [host command fallback](#host-command-fallback).
7. Run Test connection, then an approved agent turn that uses a tool. A chat
   response alone does not show that tool calls work.

To replace the CA file, rename the new file over the old one with the same owner
and mode, then recreate the gateway. To replace the credential, follow
[rotation](file-secrets.md#rotation).

| Message | Cause | Action |
| --- | --- | --- |
| `UNABLE_TO_VERIFY_LEAF_SIGNATURE` in the gateway log; the turn reports that it could not connect | The endpoint certificate does not chain to the configured CA, or `request.tls.ca` is missing | Check the CA file, the chain and the provider setting. Do not disable verification. |
| `permissions are too open` for a `secrets.providers` path | The group or other users can read the file | Set owner UID 1000 and mode `0400`, then recreate the gateway. |
| `is not readable` for `/run/secrets/internal_ai_api_key` | The overlay is not selected, the file is missing, or the command ran in `cli` | Check the saved selection and run the command in the gateway. |
| `Provider transport overrides do not allow insecureSkipVerify` | The bypass field is present | Remove it with `openclaw config unset`, then recreate the gateway. |

Local fixture evidence, pinned OpenClaw 2026.10.5: with the approved test CA, a
gateway agent turn completed a tool call, tool execution and final answer
through an OpenAI-compatible mock endpoint on an internal Docker network. The
same configuration rejected a certificate from another CA, and no request
reached the mock. A configuration without `request.tls.ca` was also rejected.
`tests/internal-ai-ca/run.sh` repeats the main checks. This does not prove a
real endpoint, network path, proxy or model quality.

## Host command fallback

These commands are for the VM operator. While the gateway runs, use its PID
namespace and the existing entrypoint to load mounted credentials:

```sh
docker compose exec openclaw /usr/local/bin/compliance-claw-entrypoint openclaw models list
docker compose exec openclaw /usr/local/bin/compliance-claw-entrypoint openclaw models set <provider/model>
docker compose exec openclaw /usr/local/bin/compliance-claw-entrypoint openclaw mcp probe <external-name> --json
```

`models set` changes the **global default**, not one agent's override. A one-off
`docker compose run --rm cli` is for config work with the gateway stopped; it
must not bypass the native live-state owner check. Use the
[file-secret-aware agent command](file-secrets.md#docker-compose-exec-does-not-see-these-secrets)
for a turn against the running gateway.

For interactive device-code login, the native command is
`openclaw models auth login --provider openai --device-code`; run it through the
same gateway entrypoint with a TTY, or the CLI service while stopped. Check
`openclaw models auth list`, then an approved real turn. Native login stores state
in `openclaw-state`. Do not treat command availability as a verified provider login.

## External MCP connections

Use `/settings/mcp` for unowned external stdio servers. In the checked UI, edits
save automatically and automatic reload rebuilds connections on next use. Use
names outside `pretorin-`; managed Pretorin scope, command, credential and target
context come from the effort declaration. Do not create a second Pretorin path.

After a change, reconnect, inspect the saved command/Cwd and probe the connection.
A handshake/tool list is transport evidence, not an external permission check.
The external service owner grants the required access. A one-off `mcp reload`
disposes only that caller's cache; it does not prove gateway-owned children were
replaced. Coordinate any necessary process restart with the operator and follow
[credential activation/removal](file-secrets.md). Preserve unrelated connections.

## Optional Slack

For initial app registration or reuse, keep the [README Slack procedure](../README.md#slack).
The image contains the pinned plugin/seed logic, no Slack credentials or channel
IDs. Mounted tokens are operator-owned; `efforts.yaml` supplies optional channel
IDs. The full [delivery matrix](file-secrets.md) covers the legacy single-effort
path too.

Fresh Slack configuration is seeded once when the required tokens are present.
The multi-effort seed starts with no allowed channels and DMs disabled; apply
adds declared channels. Existing state is never overwritten. Adding tokens to
Slack-less state alone does not configure it. Inspect startup warnings and keep
both volumes before repair; use the [upgrade guide](upgrade.md), not volume deletion.

Socket Mode connects outbound; no inbound Slack request URL is needed. The
normal gateway remains on loopback. Fresh plugin setup or a version change needs
npm access. OpenClaw stores the runtime plugin in `openclaw-state`; the image's
verified package is retained for scanning. Unused Slack does not establish that
Doctor makes no registry requests.

The seed requires mentions in allowed channels. [Optional DM bindings](efforts.md#optional-slack-dms)
remain separate. Check gateway Slack logs, then an approved test message through
the actual channel. Configuration or local canary tests do not prove delivery.
After an upgrade, check native plugin status; do not use a fixed plugin count as
an access control. Keep the local `pretorin-update` and `target-sync` plugins.

Every member of a shared Slack channel acts with its configured Pretorin key's
authority; this path has no per-user attribution. Keep the existing read-only
shared-channel limit in [SECURITY.md](../SECURITY.md). This guide does not add RBAC.

## Network connections

No inbound connection to the VM is required. The gateway listens on host
loopback only. Approve outbound connections by purpose. The names below are
public service names or placeholders; take the exact names from your provider,
Pretorin account and network team.

| Connection | When | Purpose | Source |
| --- | --- | --- | --- |
| Container registry (`ghcr.io` and its storage) | Install and update | Pull the pinned image | Host Docker daemon |
| This repository's Git host | Update | `scripts/update.sh` fetches the checkout | Host |
| Target Git hosts | Install and normal operation | Clone targets (host); fast-forward them (host or gateway) | Host; gateway for chat sync |
| GitHub API (`api.github.com`) | Install, private targets only | Mint the read-only GitHub App token | Host |
| Pretorin platform (`<pretorin-api-host>`) | Normal operation | Pretorin CLI and MCP calls with each effort's key | Gateway and `cli` |
| Pretorin CLI release source | CLI update only | The signed installer downloads the CLI | Container that runs the update |
| AI provider or internal endpoint (`<ai-endpoint-host>`) | Normal operation | Model requests and device-code login | Gateway |
| npm registry (`registry.npmjs.org`) | Slack setup or Slack version change | Install the pinned managed Slack package | Gateway or `cli` |
| Slack | Normal operation, Slack only | Socket Mode connection (outbound) | Gateway |
| External MCP services | Normal operation, where configured | Connections that the Claw administrator adds | Gateway |

A local image build (`--build`) also needs the base-image registries and package
sources that `versions.env` pins. A deployment of the published image does not.
This repository does not configure an egress proxy or DNS. A custom provider
`baseUrl` permits model requests to that exact origin only; see the native
private-network rules for other private destinations. A blocked connection
usually appears as a connection error or timeout in the gateway log for the
matching feature.

## Retained copies and removal

Customer policy sets retention. This repository adds no retention or deletion
service. Credential revocation stops future access when it takes effect; it does
not delete content that was already copied. A backup holds copies of everything
in the volumes it archives.

| Copy | Location | Owner | Inspect and remove, or limit |
| --- | --- | --- | --- |
| Gateway configuration, sessions and transcripts, agent workspaces and memory, model login, managed Slack package, native and automatic-triage support bundles (`logs/support`) | `openclaw-state` volume | VM operator; Claw administrator for sessions and agent files | `openclaw sessions list` and `openclaw sessions delete <key>` in the gateway container, with the gateway credential loaded as for [agent commands](file-secrets.md#docker-compose-exec-does-not-see-these-secrets). Delete keeps a compressed `<session>.jsonl.deleted.<timestamp>` transcript archive in the volume; indexed memory needs `openclaw memory forget`. Complete removal is deletion of the volume (see [Resetting](upgrade.md#resetting-destructive)). |
| Active Pretorin CLI, context, preflight resolvers, Plan records, recipes, CLI update and target-sync audit files | `pretorin-state` volume | VM operator | Inspect with the [record procedure](upgrade.md#transfer-existing-effort-records) and `scripts/pretorin-update.sh --status`. This repository has no per-record delete command; complete removal is deletion of the volume. |
| Gateway file log (`/tmp/openclaw/openclaw-<date>.log`) | Container writable layer | VM operator | Removed when the container is recreated or removed. |
| Doctor pre-repair captures of configuration and databases | `/home/node/.openclaw.update-captures`, container writable layer, outside both volumes | VM operator | Startup Doctor can create them. Removed when the container is recreated or removed. A volume backup does not include them. |
| Container output log | Docker log driver on the host | VM operator | `docker compose logs openclaw`. Removed with the container. Docker daemon settings set its rotation. |
| Target clones | `workspace/targets` on the host | VM operator | Remove the target from `efforts.yaml`, apply, then delete the clone directory. Volume deletion does not remove it. |
| Host deployment files and private overlays | Checkout, secret directory, private paths | VM operator | Delete the files. Revoke credentials at their issuers first. |
| Backups, restore tests and rendered `docker compose config` output | Operator-chosen private location | VM operator | Keep and delete them under customer policy; see [state backup](upgrade.md#openclaw-image-upgrade-and-state-backup). A restore brings back every copy that they hold. A restore does not undo Pretorin platform writes or copies at providers and other remote services. |
| Prompts, repository content in tool results, and model responses | AI provider or internal endpoint | Customer and the provider | Provider retention terms apply. This repository cannot inspect or delete provider copies. |
| Evidence, narratives, uploads and other records written with a write-enabled key | Pretorin platform | Customer and Pretorin | Use Pretorin platform controls or Pretorin support. Key revocation does not delete them. |
| Slack messages and files | Slack workspace | Customer Slack administrator | Slack retention settings apply. |
| Data sent to external MCP services | That service | Its service owner | That service's terms and controls apply. |
| Support bundles and log excerpts sent for support | Support case | Customer and the receiver | Send only reviewed content; the receiver's retention applies. |

## Support diagnostics

Collect the minimum. Review every file before you send it. Do not send secret
files, `.env`, state volume archives, transcripts, heap snapshots or rendered
`docker compose config` output.

1. Versions and status, with the deployment's saved selection:

   ```sh
   git rev-parse --short HEAD
   docker compose ps -a
   docker compose images openclaw
   scripts/pretorin-update.sh --status
   ```

2. The native sanitized bundle. OpenClaw designs it to omit prompts, tool
   output and credentials. In the local fixture it held no credential, but it
   held a short model reply in a log line and the configured endpoint host
   name. Review it before you send it:

   ```sh
   docker compose exec -T openclaw /usr/local/bin/compliance-claw-entrypoint \
     openclaw gateway diagnostics export --output /tmp/openclaw-diagnostics.zip
   docker compose cp openclaw:/tmp/openclaw-diagnostics.zip ./openclaw-diagnostics.zip
   ```

   The copy in the container stays until the container is recreated.

3. A short gateway log excerpt for the failure time, for example
   `docker compose logs --since 30m openclaw`. Remove credential fragments:
   a provider error can include a masked key prefix and suffix.

Delete local copies under customer policy after the case closes.
