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
