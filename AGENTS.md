# Contributor agent guide

This file guides coding agents that change this repository. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, commands, and the PR process.
Use ASD-STE100 English in responses, issues, PRs, and documentation.

## Product and architecture

Compliance Claw is an OpenClaw runtime with Pretorin CLI integrated. OpenClaw
runs agents and manages providers, connections, and channels. Pretorin CLI and
its Model Context Protocol (MCP) server connect those agents to Pretorin.
This repository owns deployment and integration, not another agent runtime or
a copy of Pretorin's compliance logic.

```text
VM administrator -> Docker Compose -> OpenClaw gateway -> agent
                                                   -> Pretorin MCP -> platform
Claw administrator -> provider, connection, agent, and channel configuration
```

VM administrators maintain the runtime, persistent state, and network access.
Claw administrators configure the Claw. Native UI administration is the intended
path where verified. Current effort setup uses host scripts and `efforts.yaml`.
Do not describe an intended UI flow as an available feature without evidence.

| Files | Responsibility |
| --- | --- |
| `Dockerfile`, `versions.env`, `vendor/` | Build the runtime and verify dependency bytes and pins. |
| `compose*.yaml` | Services, mounts, credentials, build selection, and test isolation. |
| `scripts/bootstrap.sh`, `scripts/init-file-secrets.sh` | Host prerequisites, target clones, image selection, and initial secret files. |
| `scripts/entrypoint.sh`, config/Slack templates, `scripts/managed-slack.mjs` | Runtime secret loading, initial config, active CLI seed, and managed Slack installation. |
| `scripts/clawctl`, `parse-targets.py`, `parse-efforts.py`, `openclaw-patch.py` in `scripts/` | Validate declarations, generate owned configuration, apply, verify, and roll back. |
| `scripts/onboard-lib.sh`, `scripts/onboard-targets.sh`, `scripts/pretorin-mcp-launch.sh` | Bind source context and start MCP with the effort's scope and credential. |
| `scripts/sync-targets.sh`, `plugins/target-sync/` | Fast-forward declared targets through host, command, and model-tool routes. |
| `scripts/pretorin-update*.sh`, `plugins/pretorin-update/` | Install and activate the shared CLI; report installation and activation accurately. |
| `scripts/*test*`, `scripts/smoke.sh`, `scripts/lint-heredocs.py` | Existing validation. See the contribution guide for selection and prerequisites. |
| `.github/workflows/build.yml`, `.github/workflows/release.yml`, `scripts/release-assets.py`, `scripts/release-tag.sh` | Candidate checks, release-set preparation, and release publication. |

The image contains a verified CLI seed. The active CLI lives in `pretorin-state`
and survives image replacement. `openclaw-state` holds config, sessions, agent
workspaces, and model login state. Do not confuse an installed file with the
binary still loaded by an MCP process.

Assessment targets are read-only at `/workspace/targets`. The gateway also has
a writable maintenance mount at `/var/lib/compliance-claw/targets`. Both paths
are reachable by the same container user. This path split is not a security
boundary. Pretorin API key scopes are enforced by the platform. Preserve the
limits in [SECURITY.md](SECURITY.md).

`scripts/agents-md.template` produces instructions for deployed effort agents.
Those files guide customer runtime behavior. They are separate from this root
contributor guide. Do not add `CLAUDE.md`, instruction mirrors, or symlinks.

## Investigation and change rules

1. Read the request, current files, `git status`, and relevant diffs first.
   Preserve unrelated changes. Use a separate worktree when needed.
2. Reproduce a reported fault and establish its cause before a fix. Read the
   affected code and tests. Check the pinned runtime rather than assume that
   upstream documentation describes the deployed version.
3. Keep one responsibility per implementation. Read the parser, patch ownership,
   credential ladder, and existing wrappers before adding another path.
4. Do not run checks against customer state or use real credentials by default.
   Follow [isolated container testing](CONTRIBUTING.md#isolated-container-testing).
5. Keep the diff within the approved scope. Record unrelated runtime/UI questions
   as follow-up candidates; do not silently fix them or file issues without authority.

## Tests and review

Use the [test selection table](CONTRIBUTING.md#test-selection). A runtime fix
needs a meaningful regression test where practical. The test must exercise the
affected behavior and reject the old fault. State the limits of stubs and static
checks. If a test is impractical, give the reason and other evidence.

For documentation-only changes, check links, anchors, template structure, and
commands against current code/CI. Execute changed examples only when needed.
Do not add artificial tests or run full images and credentialed services just
to validate prose.

Before a PR, review the full diff, config ownership, state/credential effects,
and relevant checks. Report exact commands, observed results, skips, and limits.
Update customer instructions when behavior changes. Never claim that a static
check proves a live channel, UI flow, or recovery operation.

## Optional gstack skills

These skills can help when installed. Public contributions do not require them,
private tools, personal skill paths, or a specific agent vendor.

| Skill | Use |
| --- | --- |
| `spec` | Define a focused issue and acceptance criteria. |
| `investigate` | Establish the cause of a fault before a fix. |
| `plan-eng-review` | Review an architecture or execution plan. |
| `qa` / `qa-only` | Test a relevant flow, with fixes or a report only. |
| `review` | Review the complete diff before a PR. |
| `document-release` | Check documentation against changed behavior. |
| `ship` | Prepare checks, commits, push, and a PR when requested. |

Apply this repository's [release rules](docs/releasing.md). Do not add a generic
version bump or publish a release as part of ordinary PR preparation.
