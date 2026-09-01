#!/usr/bin/env python3
"""openclaw-patch.py — turn efforts.yaml into an OpenClaw config patch, and check
that applying it did what it said.

    openclaw-patch.py generate --efforts FILE --config FILE --out-dir DIR
                               [--dm-add USER:EFFORT] [--dm-remove USER]
    openclaw-patch.py verify   --manifest FILE --config FILE --snapshot FILE
                               [--agents-json FILE] [--mcp-json FILE]
    openclaw-patch.py verify-rollback --config FILE --snapshot FILE
    openclaw-patch.py --self-test

HOST-ONLY. Nothing in the image runs this, which is why the Dockerfile does not
copy it: `clawctl` generates the patch on the host and pipes it in with
`openclaw config patch --stdin`. The runtime stage copies scripts individually
rather than globbing scripts/, so a file that had to run in-image would need an
explicit COPY line, and this one does not.

WHY THIS IS NOT IN clawctl OR parse-efforts.py.

  clawctl is bash, and hand-building nested JSON in bash is the quoting and
  injection risk this repository has repeatedly refused.

  parse-efforts.py is exec'd INSIDE the image by the MCP launcher on every
  session, and it owns credential resolution. Gateway-config synthesis has no
  business widening that file's surface.

WHAT IT OWNS, AND WHAT IT REFUSES TO TOUCH.

Compliance Claw owns a small, named set of config paths and regenerates them from
efforts.yaml every apply. Everything else in openclaw.json belongs to the operator
or to OpenClaw, and this program must never name it — because `config patch`
merges objects but REPLACES arrays, so naming an array you do not own silently
deletes its contents. That is not hypothetical: an earlier release lost
plugins.load.paths exactly that way. The rule here is the inverse and stronger:
do not name what you do not own. `plugins` appears nowhere below.

    OWNED, regenerated
      agents.list                          (array, --replace-path)
      bindings                             (array, --replace-path)
      channels.slack.channels              (map,   --replace-path)
      channels.slack.dmPolicy              derived from the direct bindings
      channels.slack.allowFrom             derived from the direct bindings
      mcp.servers.pretorin-<effort>        one per effort; null deactivates
      mcp.servers.pretorin                 null, retiring the single-effort server

    PRESERVED, never named
      gateway.*  models.*  agents.defaults.*  tools.*  plugins.*  session.*
      messages.*  mcp.sessionIdleTtlMs
      channels.slack.{enabled,mode,configWrites,slashCommand,groupPolicy}
      channels.slack.dm.*   (including groupEnabled/groupChannels — see below)
      every Slack token path

THE BINDINGS ARRAY HAS TWO OWNERS, AND THAT IS THE WHOLE DESIGN.

Effort channel bindings are generated. Slack DIRECT-peer bindings are the
operator's, created in the Control UI or with `clawctl dm`, and are preserved
verbatim across every apply. Anything else in the array is refused by name rather
than silently retained or silently dropped.

`dmPolicy` and `allowFrom` are DERIVED from the preserved direct bindings and are
never authored independently. That is what stops the Control UI and clawctl
fighting: there is exactly one source of truth for who may DM — the binding — and
two ways to edit it. Adding a user to allowFrom without a binding is refused,
because routing admits that user and then falls through every tier to the DEFAULT
agent, which is precisely the outcome the design forbids.

MPIM SUPPORT IS NOT HERE. A Slack `G` id can be a legacy private channel or a
multi-person DM, and an MPIM is admitted by channels.slack.dm.groupEnabled (off by
default) — a routing binding selects an agent only AFTER admission and cannot
substitute for it. parse-efforts.py refuses G ids for that reason, and this file
never writes channels.slack.dm.*.
"""

import argparse
import hashlib
import json
import importlib.util
import os
import re
import sys

SELF_DIR = os.path.dirname(os.path.abspath(__file__))


def _load_parse_efforts():
    path = os.path.join(SELF_DIR, "parse-efforts.py")
    spec = importlib.util.spec_from_file_location("_parse_efforts", path)
    if spec is None or spec.loader is None:
        sys.stderr.write("openclaw-patch: cannot load %s\n" % path)
        raise SystemExit(2)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pe = _load_parse_efforts()

# Where the launcher lives in the image. mcp.servers.<name>.command points here
# and passes ONE argument, the effort name; the launcher resolves scope and
# credential from the read-only mounted efforts.yaml. Every effort therefore runs
# the same binary at the same path, which is what keeps one CLI version across
# every agent.
LAUNCHER = "/opt/compliance-claw/pretorin-mcp-launch"
# The same sentinel the single-effort config used: Pretorin derives host-local
# resolvers from the process cwd, so nothing repository-shaped may be there.
MCP_CWD = "/opt/compliance-claw/no-repo"
# The retired single-effort server. Deleting it is explicit, not incidental.
LEGACY_MCP_SERVER = "pretorin"

WORKSPACE_ROOT = "/home/node/.openclaw"

# The arrays and maps we intentionally replace wholesale. `--replace-path` states
# that intent to OpenClaw; it is also what the gateway RPC path requires when it
# detects a shrinking array. Note this is NOT the whole guard on the CLI path,
# which performs no such check — generating the complete array from efforts.yaml
# plus the classified live bindings is.
#
# CANDIDATES, NOT A FIXED LIST. `openclaw config patch` refuses a --replace-path
# that matches nothing in the patch ("did not match any value in the input
# patch"), so passing all four unconditionally fails every run that writes no
# allowFrom — i.e. every deployment with no DMs configured. resolve_replace_paths
# emits only the ones actually present.
REPLACE_PATH_CANDIDATES = (
    "agents.list",
    "bindings",
    "channels.slack.channels",
    "channels.slack.allowFrom",
)


def resolve_replace_paths(patch):
    """The --replace-path flags this particular patch needs, and no others."""
    out = []
    for path in REPLACE_PATH_CANDIDATES:
        parts = path.split(".")
        cur = patch
        for part in parts:
            if not isinstance(cur, dict) or part not in cur:
                cur = None
                break
            cur = cur[part]
        else:
            # A `null` is a delete, which merge semantics handle on its own and
            # which --replace-path would reject as a non-replacement.
            if cur is not None:
                out.append(path)
    return out

# Subtrees verify() compares before and after, semantically. Not byte-wise:
# OpenClaw rewrites the file as strict JSON and stamps a fresh meta.lastTouchedAt
# on every write, so a byte comparison would fail on every successful apply.
PRESERVED_PATHS = (
    "gateway",
    "models",
    "agents.defaults",
    "tools",
    "plugins",
    "session",
    "messages",
    "mcp.sessionIdleTtlMs",
    "channels.slack.enabled",
    "channels.slack.mode",
    "channels.slack.configWrites",
    "channels.slack.slashCommand",
    "channels.slack.groupPolicy",
    # dm.* is the MPIM/DM admission block. We never write it, so it must come out
    # the other side untouched — including groupEnabled, which is what an MPIM
    # would need and what this release deliberately leaves off.
    "channels.slack.dm",
)

SLACK_USER_RE = re.compile(r"^[UW][A-Z0-9]{6,}$")


class PatchError(Exception):
    pass


# --- reading the live config -----------------------------------------------
#
# THE SEEDED CONFIG IS JSON5, not JSON: entrypoint.sh installs the template
# verbatim and OpenClaw only rewrites it as strict JSON on the first patch, so on
# a never-applied deployment `json.loads` fails on line 1.
#
# STRING-AWARE, because a naive stripper is worse than none: the shipped config
# contains "http://127.0.0.1:18789" and cutting at the first `//` would silently
# truncate a value rather than fail.
def strip_json5(text):
    out = []
    i = 0
    n = len(text)
    in_string = False
    quote = ""
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:      # an escape consumes the next char,
                out.append(text[i + 1])        # so \" never ends the string
                i += 2
                continue
            if ch == quote:
                in_string = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_string = True
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


# The other two things JSON5 allows and JSON does not, and that the shipped
# template uses: unquoted object keys (`gateway: {`) and trailing commas. Both
# are rewritten only OUTSIDE strings, which is why this runs after the scanner
# above rather than as one regex over the raw text.
def _json5_to_json(text):
    out = []
    i = 0
    n = len(text)
    in_string = False
    quote = ""
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                in_string = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_string = True
            quote = ch
            # JSON has no single-quoted strings; normalise the delimiter and let
            # the copy below escape any embedded double quote.
            out.append('"')
            i += 1
            continue
        # A bare identifier immediately followed by ':' is a key.
        if ch.isalpha() or ch == "_" or ch == "$":
            j = i
            while j < n and (text[j].isalnum() or text[j] in "_$"):
                j += 1
            word = text[i:j]
            k = j
            while k < n and text[k] in " \t\r\n":
                k += 1
            if k < n and text[k] == ":" and word not in ("true", "false", "null"):
                out.append('"%s"' % word)
                i = j
                continue
            out.append(word)
            i = j
            continue
        out.append(ch)
        i += 1
    joined = "".join(out)
    # Trailing commas, outside strings by construction.
    return re.sub(r",(\s*[}\]])", r"\1", joined)


def load_config_text(text):
    """Parse an OpenClaw config that may be strict JSON or the seeded JSON5.

    Read-only: nothing this program WRITES goes through here — the patch it
    generates is emitted as strict JSON and validated by OpenClaw's own
    `config patch --dry-run` before it is applied. A misparse here therefore
    surfaces as a refusal, not as a corrupted config.
    """
    text = text.strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except ValueError:
        pass
    return json.loads(_json5_to_json(strip_json5(text)))


# --- small path helpers ----------------------------------------------------

def get_path(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def workspace_dir(agent):
    return "%s/workspace-%s" % (WORKSPACE_ROOT, agent)


def agent_dir(agent):
    # NEVER shared between agents: OpenClaw stores per-agent auth and session
    # state here and documents that reuse causes collisions.
    return "%s/agents/%s/agent" % (WORKSPACE_ROOT, agent)


# --- binding classification ------------------------------------------------

def _is_slack_binding(binding):
    return (isinstance(binding, dict)
            and isinstance(binding.get("match"), dict)
            and binding["match"].get("channel") == "slack")


def _peer(binding):
    peer = binding["match"].get("peer")
    return peer if isinstance(peer, dict) else {}


def describe_binding(binding):
    """A stable one-line description for error messages."""
    if not isinstance(binding, dict):
        return repr(binding)
    match = binding.get("match") if isinstance(binding.get("match"), dict) else {}
    peer = match.get("peer") if isinstance(match.get("peer"), dict) else {}
    return "agentId=%s channel=%s peer=%s:%s" % (
        binding.get("agentId", "<none>"), match.get("channel", "<none>"),
        peer.get("kind", "<none>"), peer.get("id", "<none>"))


def classify_bindings(existing, effort_channels, agent_ids):
    """Split the live bindings array into (preserved_direct, refusals).

    effort_channels: {channel_id: agent_id} for the channels we generate.
    agent_ids:       the set of agent ids this apply will configure.

    Generated channel bindings are dropped here and re-emitted from efforts.yaml,
    so an edit to efforts.yaml always wins for the paths we own. Direct-peer
    bindings are the operator's and are carried through untouched. Everything else
    is a refusal: silently retaining an unrecognised binding would let a stale or
    hand-broken entry outlive the thing it referred to, and silently dropping one
    would delete operator intent without saying so.
    """
    preserved = []
    refusals = []
    seen_users = {}

    for binding in existing or []:
        if not _is_slack_binding(binding):
            refusals.append(
                "unrecognised binding (%s): this deployment owns only Slack"
                " channel bindings generated from efforts.yaml and Slack direct"
                " (DM) bindings you created. Remove it, or move it out of"
                " openclaw.json before applying."
                % describe_binding(binding))
            continue

        peer = _peer(binding)
        kind = peer.get("kind")
        pid = peer.get("id")

        if kind == "channel":
            if pid in effort_channels:
                continue                      # ours; regenerated below
            refusals.append(
                "Slack channel binding for %s -> agent '%s' is not declared in"
                " efforts.yaml. Add an effort with slack_channel_id: %s, or remove"
                " the binding." % (pid, binding.get("agentId"), pid))
            continue

        if kind == "direct":
            agent = binding.get("agentId")
            if not isinstance(pid, str) or not SLACK_USER_RE.match(pid):
                refusals.append(
                    "Slack direct binding has peer id '%s', which is not a Slack"
                    " USER id. DM routing matches on the sender's user id (U...),"
                    " never on the D... conversation id — a D id here can never"
                    " match, so the DM would fall through to the default agent."
                    % pid)
                continue
            if agent not in agent_ids:
                refusals.append(
                    "Slack direct binding for user %s targets agent '%s', which no"
                    " longer exists. It is NOT rerouted to the default agent."
                    " Either restore that effort in efforts.yaml, or drop the"
                    " binding:  scripts/clawctl dm revoke %s" % (pid, agent, pid))
                continue
            if pid in seen_users:
                refusals.append(
                    "Slack user %s is bound twice (to '%s' and to '%s'). One DM"
                    " conversation cannot represent two efforts, and the first"
                    " binding in config order would silently win. Keep one:"
                    "  scripts/clawctl dm revoke %s"
                    % (pid, seen_users[pid], agent, pid))
                continue
            seen_users[pid] = agent
            preserved.append(binding)
            continue

        refusals.append(
            "Slack binding with peer kind '%s' (%s) is not supported. This release"
            " serves channel bindings generated from efforts.yaml and direct (DM)"
            " bindings; multi-person DMs additionally need"
            " channels.slack.dm.groupEnabled, which is deliberately not configured"
            " here." % (kind, describe_binding(binding)))

    return preserved, refusals


def check_allow_from(existing_allow_from, bound_users):
    """An allowlisted user with no binding routes to the DEFAULT agent.

    dmPolicy/allowFrom are ADMISSION; bindings are SELECTION. OpenClaw's tier
    order ends at the default agent, so a user admitted with nothing to match
    lands there — an effort agent chosen by position rather than by intent. That
    is refused rather than repaired silently.
    """
    refusals = []
    for entry in existing_allow_from or []:
        if not isinstance(entry, str):
            continue
        value = entry.strip()
        if not value:
            continue
        if value == "*" or "*" in value:
            refusals.append(
                "channels.slack.allowFrom contains '%s'. A wildcard admits every"
                " Slack user, and an admitted user with no direct binding routes"
                " to the default agent. Remove it; allowFrom is derived from the"
                " direct bindings." % value)
            continue
        if value not in bound_users:
            refusals.append(
                "channels.slack.allowFrom lists %s, but no Slack direct binding"
                " sends that user to an effort agent. Admission without a binding"
                " routes the DM to the default agent. Either bind them"
                " (scripts/clawctl dm allow %s --effort <name>) or remove the"
                " allowFrom entry." % (value, value))
    return refusals


# --- generation ------------------------------------------------------------

def build_agent(effort):
    """One agents.list entry.

    TOOL POLICY IS A DENY LIST, NOT AN ALLOW LIST, and that is not a style
    choice. An agent-layer allowlist naming only this effort's MCP tools would
    strip every built-in tool, and OpenClaw aborts a run whose allowlist leaves
    nothing callable. Deny wins over allow at every layer, so denying the other
    efforts' MCP tool prefixes is both strictly enforcing and additive-safe.

    THIS IS A TOOL-VISIBILITY BOUNDARY, NOT A PROCESS ONE. mcp.servers is global
    to the gateway; what makes an effort's tools unreachable from another agent is
    this policy, not isolation of the MCP child.
    """
    name = effort["name"]
    return {
        "id": pe.agent_id(name),
        "workspace": workspace_dir(pe.agent_id(name)),
        "agentDir": agent_dir(pe.agent_id(name)),
    }


def fleet_fingerprint(efforts):
    """A stable hash of the non-DM fleet: scope, channel, credential and targets.

    Sorted and canonical so that reordering efforts.yaml, or reformatting it, is
    not a change. Effort order and target order within an effort are both
    meaningless, so both are sorted.

    THE WHOLE TARGET DEFINITION, not just its name. Hashing names alone left
    url, ref and private out of the fingerprint, so repointing a target at a fork,
    moving it to another branch, or flipping it to private all produced an
    identical hash — and `clawctl dm` would then deploy that repository change
    without the clone step that has to act on it. `_lineno` is deliberately
    excluded: it moves when the file is merely reformatted.
    """
    def target(t):
        return {"name": t["name"], "url": t.get("url"),
                "ref": t.get("ref"), "private": t.get("private")}

    canonical = [
        {"name": e["name"],
         "system_id": e["system_id"],
         "framework_id": e["framework_id"],
         "slack_channel_id": e["slack_channel_id"],
         "credential_ref": e["credential_ref"],
         "targets": sorted((target(t) for t in e["targets"]),
                           key=lambda t: t["name"])}
        for e in sorted(efforts, key=lambda e: e["name"])
    ]
    blob = json.dumps(canonical, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def build_patch(efforts, config, dm_bindings):
    agents = []
    bindings = []
    slack_channels = {}
    mcp_servers = {}

    prefixes = {e["name"]: pe.mcp_tool_prefix(pe.mcp_server_name(e["name"]))
                for e in efforts}

    for index, effort in enumerate(efforts):
        name = effort["name"]
        agent = pe.agent_id(name)
        entry = build_agent(effort)
        # The default agent is stated rather than left to list position. OpenClaw
        # falls back to the first entry when nothing claims it, so being explicit
        # means reordering efforts.yaml cannot change which agent answers a
        # request that matched no binding. Nothing should reach it: the Slack
        # allowlist and the exact bindings below are generated from one list.
        if index == 0:
            entry["default"] = True
        deny = sorted(p for n, p in prefixes.items() if n != name)
        if deny:
            entry["tools"] = {"deny": ["%s__*" % p for p in deny]}
        agents.append(entry)

        bindings.append({
            "agentId": agent,
            "match": {"channel": "slack",
                      "peer": {"kind": "channel", "id": effort["slack_channel_id"]}},
        })
        # THE CHANNEL IS THE TRUST BOUNDARY. Without `users`, OpenClaw refuses
        # every slash command with "You are not authorized to use this command."
        # "*" authorizes the members of THIS channel only: groupPolicy
        # "allowlist" still serves no channel that is not generated here, DMs
        # stay disabled, and /target-sync is still scoped to the effort the
        # channel routes to. Membership of the Slack channel is the grant.
        slack_channels[effort["slack_channel_id"]] = {
            "requireMention": True,
            "users": ["*"],
        }

        mcp_servers[pe.mcp_server_name(name)] = {
            "command": LAUNCHER,
            "args": [name],
            "cwd": MCP_CWD,
        }

    # Operator DM bindings, after the generated ones. Order is irrelevant to
    # routing here — a direct peer and a channel peer can never both match one
    # message — but keeping generated entries first makes the array diffable.
    bindings.extend(dm_bindings)

    bound_users = [b["match"]["peer"]["id"] for b in dm_bindings]

    # Retire the single-effort server explicitly. `null` is a delete in merge
    # semantics; leaving it would keep an unscoped Pretorin server visible to
    # every agent, which is the exact thing efforts exist to prevent.
    if get_path(config, "mcp.servers.%s" % LEGACY_MCP_SERVER) is not None:
        mcp_servers[LEGACY_MCP_SERVER] = None

    # Deactivate MCP servers left over from removed efforts. Non-destructive: the
    # workspace, memory, credential and clones stay; only the wiring goes.
    live = get_path(config, "mcp.servers") or {}
    for key in live:
        if key.startswith(pe.MCP_SERVER_PREFIX) and key not in mcp_servers:
            mcp_servers[key] = None

    slack = {
        "channels": slack_channels,
        # DERIVED, never authored. No bound users means DMs stay off, which is the
        # posture a deployment that never configures one keeps forever.
        "dmPolicy": "allowlist" if bound_users else "disabled",
    }
    if bound_users:
        slack["allowFrom"] = sorted(bound_users)
    else:
        # Delete rather than write an empty list: an empty allowFrom alongside
        # dmPolicy "disabled" is two statements of the same fact that can drift.
        if get_path(config, "channels.slack.allowFrom") is not None:
            slack["allowFrom"] = None

    patch = {
        "agents": {"list": agents},
        "bindings": bindings,
        "mcp": {"servers": mcp_servers},
        "channels": {"slack": slack},
    }

    manifest = {
        # The scope of every effort, so the next apply can refuse a name that has
        # been repointed at a different system or framework.
        "efforts": {e["name"]: {"system_id": e["system_id"],
                                "framework_id": e["framework_id"],
                                "slack_channel_id": e["slack_channel_id"],
                                "credential_ref": e["credential_ref"]}
                    for e in efforts},
        "agents": [a["id"] for a in agents],
        "defaultAgent": agents[0]["id"] if agents else None,
        "channelBindings": {e["slack_channel_id"]: pe.agent_id(e["name"])
                            for e in efforts},
        "directBindings": {b["match"]["peer"]["id"]: b["agentId"] for b in dm_bindings},
        "mcpServers": sorted(k for k, v in mcp_servers.items() if v is not None),
        "deactivatedMcpServers": sorted(k for k, v in mcp_servers.items() if v is None),
        "toolPrefixes": prefixes,
        "dmPolicy": slack["dmPolicy"],
        "allowFrom": sorted(bound_users),
        "workspaces": {pe.agent_id(e["name"]): workspace_dir(pe.agent_id(e["name"]))
                       for e in efforts},
        "targetsByEffort": {e["name"]: [t["name"] for t in e["targets"]]
                            for e in efforts},
        # THE FLEET FINGERPRINT — every part of the deployment that is NOT a DM.
        # `clawctl dm` regenerates and applies the whole fleet, so an unapplied
        # edit to efforts.yaml would otherwise reach the gateway through a DM
        # command, skipping the stable-scope check, target preparation and
        # Pretorin onboarding that `apply` does. dm refuses unless this matches
        # the last successful apply. Derived from efforts.yaml only: identical
        # input gives an identical hash on any machine.
        "fleetFingerprint": fleet_fingerprint(efforts),
        "preservedPaths": list(PRESERVED_PATHS),
        "replacePaths": resolve_replace_paths(patch),
    }
    return patch, manifest


def apply_dm_edits(preserved, add, remove, agent_ids):
    """`clawctl dm allow/revoke`, expressed as an edit to the preserved set."""
    out = [b for b in preserved]
    if remove:
        before = len(out)
        out = [b for b in out if b["match"]["peer"]["id"] != remove]
        if len(out) == before:
            raise PatchError(
                "no Slack direct binding exists for user %s; nothing to revoke."
                % remove)
    if add:
        user, _, effort = add.partition(":")
        if not user or not effort:
            raise PatchError("--dm-add expects USER:EFFORT, got '%s'" % add)
        if not SLACK_USER_RE.match(user):
            raise PatchError(
                "'%s' is not a Slack user id. DM routing matches the SENDER's user"
                " id (U...), never the D... conversation id. Find it in Slack:"
                " profile -> More -> Copy member ID." % user)
        if effort not in agent_ids:
            raise PatchError(
                "no effort named '%s' is declared in efforts.yaml. A DM can only be"
                " bound to an effort that exists, or it would route to the default"
                " agent." % effort)
        for existing in out:
            if existing["match"]["peer"]["id"] == user:
                raise PatchError(
                    "Slack user %s is already bound to effort '%s'. One DM"
                    " conversation represents exactly one effort. Revoke first:"
                    "  scripts/clawctl dm revoke %s"
                    % (user, existing["agentId"], user))
        out.append({
            "agentId": effort,
            "match": {"channel": "slack", "peer": {"kind": "direct", "id": user}},
            # PER-BINDING, NOT GLOBAL. OpenClaw honours a binding's own dmScope
            # over session.dmScope, so each DM gets its own session without this
            # deployment taking a position on global session grouping — which
            # would be a setting the Control UI and clawctl could fight over.
            "session": {"dmScope": "per-channel-peer"},
        })
    return out


def cmd_generate(args):
    efforts = pe.load(args.efforts)
    config = {}
    if args.config and os.path.exists(args.config):
        with open(args.config) as handle:
            text = handle.read()
        try:
            config = load_config_text(text)
        except ValueError as exc:
            raise PatchError(
                "%s could not be parsed as JSON or JSON5 (%s). A config that will"
                " not parse here is one the gateway cannot load either. Nothing"
                " was generated." % (args.config, exc))

    agent_ids = {pe.agent_id(e["name"]) for e in efforts}
    effort_channels = {e["slack_channel_id"]: pe.agent_id(e["name"]) for e in efforts}

    preserved, refusals = classify_bindings(
        get_path(config, "bindings"), effort_channels, agent_ids)

    if args.dm_add or args.dm_remove:
        # A DM edit must not be blocked by an unrelated refusal it cannot fix,
        # but it must not paper over one either: refusals are still reported and
        # still fail the run below.
        preserved = apply_dm_edits(preserved, args.dm_add, args.dm_remove, agent_ids)

    bound_users = {b["match"]["peer"]["id"] for b in preserved}
    refusals.extend(check_allow_from(get_path(config, "channels.slack.allowFrom"),
                                     bound_users))

    if refusals:
        raise PatchError(
            "the live OpenClaw configuration has %d problem(s) this apply will not"
            " silently fix:\n%s"
            % (len(refusals), "\n".join("  - " + r for r in refusals)))

    patch, manifest = build_patch(efforts, config, preserved)

    os.makedirs(args.out_dir, exist_ok=True)
    patch_path = os.path.join(args.out_dir, "patch.json")
    manifest_path = os.path.join(args.out_dir, "manifest.json")
    replace_path = os.path.join(args.out_dir, "replace-paths.txt")

    # Deterministic bytes: sorted keys and a fixed separator, so an unchanged
    # efforts.yaml produces a byte-identical patch and `apply` is provably
    # idempotent rather than merely believed to be.
    _write_atomic(patch_path, json.dumps(patch, indent=2, sort_keys=True) + "\n")
    _write_atomic(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    _write_atomic(replace_path,
                  "".join(p + "\n" for p in manifest["replacePaths"]))

    sys.stderr.write(
        "openclaw-patch: %d agent(s), %d channel binding(s), %d direct binding(s),"
        " %d MCP server(s), dmPolicy=%s\n"
        % (len(manifest["agents"]), len(manifest["channelBindings"]),
           len(manifest["directBindings"]), len(manifest["mcpServers"]),
           manifest["dmPolicy"]))
    print(patch_path)
    return 0


def _write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(text)
    os.replace(tmp, path)


# --- verification ----------------------------------------------------------

def cmd_verify(args):
    with open(args.manifest) as handle:
        manifest = json.load(handle)
    with open(args.config) as handle:
        config = load_config_text(handle.read())
    snapshot = None
    if args.snapshot and os.path.exists(args.snapshot):
        with open(args.snapshot) as handle:
            text = handle.read()
        # The PRE-APPLY snapshot of a never-patched deployment is the seeded
        # JSON5 template, so the preserved-subtree comparison has to read both
        # sides the same tolerant way or it would report every key as changed.
        if text.strip():
            snapshot = load_config_text(text)

    problems = []

    # --- what we own landed ---
    live_agents = [a.get("id") for a in (get_path(config, "agents.list") or [])]
    if live_agents != manifest["agents"]:
        problems.append("agents.list is %r, expected %r" % (live_agents, manifest["agents"]))

    # MCP SERVERS, CHECKED THREE WAYS — and deliberately NOT as an equality on the
    # whole key set. This deployment owns the `pretorin-<effort>` entries and
    # nothing else: an operator with their own MCP server configured would have
    # had a perfectly correct apply reported as a verification failure, and the
    # patch preserves that server precisely so it can survive.
    live_servers = get_path(config, "mcp.servers") or {}
    missing = [srv for srv in manifest["mcpServers"] if srv not in live_servers]
    if missing:
        problems.append("mcp.servers is missing the expected server(s) %r" % missing)
    still_there = [srv for srv in manifest["deactivatedMcpServers"] if srv in live_servers]
    if still_there:
        problems.append("mcp.servers still holds the deactivated server(s) %r" % still_there)
    if snapshot is not None:
        owned = set(manifest["mcpServers"]) | set(manifest["deactivatedMcpServers"])
        was = {k: v for k, v in (get_path(snapshot, "mcp.servers") or {}).items()
               if k not in owned}
        now = {k: v for k, v in live_servers.items() if k not in owned}
        if was != now:
            problems.append(
                "an MCP server this deployment does not own changed:\n"
                "      before: %s\n      after:  %s"
                % (json.dumps(was, sort_keys=True), json.dumps(now, sort_keys=True)))

    channel_bindings = {}
    direct_bindings = {}
    for binding in get_path(config, "bindings") or []:
        if not _is_slack_binding(binding):
            continue
        peer = _peer(binding)
        if peer.get("kind") == "channel":
            channel_bindings[peer.get("id")] = binding.get("agentId")
        elif peer.get("kind") == "direct":
            direct_bindings[peer.get("id")] = binding.get("agentId")
    if channel_bindings != manifest["channelBindings"]:
        problems.append("Slack channel bindings are %r, expected %r"
                        % (channel_bindings, manifest["channelBindings"]))
    # THE PRESERVATION ASSERTION. An operator's DM binding surviving apply is a
    # promise this makes, so it is checked rather than assumed.
    if direct_bindings != manifest["directBindings"]:
        problems.append("Slack direct (DM) bindings are %r, expected %r — an"
                        " operator-created binding was lost or altered"
                        % (direct_bindings, manifest["directBindings"]))

    if get_path(config, "channels.slack.dmPolicy") != manifest["dmPolicy"]:
        problems.append("channels.slack.dmPolicy is %r, expected %r"
                        % (get_path(config, "channels.slack.dmPolicy"), manifest["dmPolicy"]))

    live_allow = sorted(get_path(config, "channels.slack.allowFrom") or [])
    if live_allow != sorted(manifest["allowFrom"]):
        problems.append("channels.slack.allowFrom is %r, expected %r"
                        % (live_allow, sorted(manifest["allowFrom"])))

    live_slack_channels = sorted(get_path(config, "channels.slack.channels") or {})
    if live_slack_channels != sorted(manifest["channelBindings"]):
        problems.append("the Slack channel allowlist is %r, expected %r — the"
                        " allowlist and the bindings must name the same channels,"
                        " or a bound channel is never admitted"
                        % (live_slack_channels, sorted(manifest["channelBindings"])))

    # --- what we do NOT own survived ---
    #
    # SEMANTIC, NOT BYTE-WISE. `config patch` rewrites the file as strict JSON and
    # stamps a fresh meta.lastTouchedAt on every write, so comparing bytes would
    # fail on every successful apply. Parsed values at named paths is the question
    # actually being asked.
    if snapshot is not None:
        for path in manifest.get("preservedPaths", PRESERVED_PATHS):
            before = get_path(snapshot, path)
            after = get_path(config, path)
            if before != after:
                problems.append(
                    "%s changed, and this deployment does not own it:\n"
                    "      before: %s\n      after:  %s"
                    % (path, json.dumps(before, sort_keys=True),
                       json.dumps(after, sort_keys=True)))

    # --- the live gateway's own view, when it was captured ---
    #
    # These come from `openclaw ... --json` run INSIDE the gateway container. The
    # cli container cannot answer them: it has its own empty loopback, so a
    # gateway-bound command there silently falls back to the embedded agent.
    if args.agents_json:
        problems.extend(_verify_live_agents(args.agents_json, manifest))
    if args.mcp_json:
        problems.extend(_verify_live_mcp(args.mcp_json, manifest))

    if problems:
        sys.stderr.write("openclaw-patch: verification FAILED\n")
        for problem in problems:
            sys.stderr.write("    - %s\n" % problem)
        return 1
    sys.stderr.write("openclaw-patch: verification passed\n")
    return 0


# --- rollback verification -------------------------------------------------
#
# NOT THE FORWARD VERIFIER. That one compares the live config against the manifest
# of the change being undone, so after a restore it could only fail — reported as
# "the restored configuration did not verify either", which reads like the rollback
# broke something when it worked. The question here is whether the configuration is
# back: a whole-document comparison against the snapshot.
def cmd_verify_rollback(args):
    with open(args.config) as handle:
        after = load_config_text(handle.read())
    with open(args.snapshot) as handle:
        before = load_config_text(handle.read())

    # `meta` is OpenClaw's own bookkeeping — it stamps lastTouchedVersion and
    # lastTouchedAt on every write, including the one that restored the file — so
    # comparing it would fail every successful rollback.
    after_cmp = {k: v for k, v in after.items() if k != "meta"}
    before_cmp = {k: v for k, v in before.items() if k != "meta"}

    if after_cmp == before_cmp:
        sys.stderr.write("openclaw-patch: rollback verified — the configuration is"
                         " byte-for-byte the pre-apply state (ignoring meta)\n")
        return 0

    sys.stderr.write("openclaw-patch: ROLLBACK VERIFICATION FAILED — the restored"
                     " configuration is not the pre-apply state.\n")
    for key in sorted(set(before_cmp) | set(after_cmp)):
        b, a = before_cmp.get(key), after_cmp.get(key)
        if b != a:
            sys.stderr.write("    - %s differs:\n"
                             "      before: %s\n      after:  %s\n"
                             % (key,
                                json.dumps(b, sort_keys=True)[:400],
                                json.dumps(a, sort_keys=True)[:400]))
    return 1


def _collect_ids(blob, keys):
    """Pull ids out of an `openclaw ... --json` payload without pinning its shape.

    Upstream is free to reshape these payloads between releases, and a verifier
    that hard-codes one shape turns an OpenClaw upgrade into a false failure. So
    this walks the structure and collects any string under the given keys.
    """
    found = set()

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in keys and isinstance(value, str):
                    found.add(value)
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(blob)
    return found


def _load_json_or_none(path):
    try:
        with open(path) as handle:
            text = handle.read().strip()
        return json.loads(text) if text else None
    except (OSError, ValueError):
        return None


def _verify_live_agents(path, manifest):
    blob = _load_json_or_none(path)
    if blob is None:
        return ["the gateway's agent listing could not be read or parsed (%s)."
                " It is captured with 'docker compose exec -T openclaw', because"
                " the cli container cannot reach the gateway on 127.0.0.1." % path]
    ids = _collect_ids(blob, {"id", "agentId"})
    missing = [a for a in manifest["agents"] if a not in ids]
    if missing:
        return ["the running gateway does not report agent(s) %r" % missing]
    return []


def _verify_live_mcp(path, manifest):
    blob = _load_json_or_none(path)
    if blob is None:
        return ["the gateway's MCP listing could not be read or parsed (%s)" % path]
    text = json.dumps(blob)
    missing = [s for s in manifest["mcpServers"] if s not in text]
    if missing:
        return ["the running gateway does not report MCP server(s) %r" % missing]
    stale = [s for s in manifest["deactivatedMcpServers"] if '"%s"' % s in text]
    if stale:
        return ["the running gateway still reports deactivated MCP server(s) %r" % stale]
    return []


# --- self-test -------------------------------------------------------------

TWO_EFFORTS = """
efforts:
  - name: crm-soc2
    system_id: 11111111-1111-4111-8111-111111111111
    framework_id: soc2
    credential_ref: default
    slack_channel_id: C0SOC2AAA
    targets:
      - name: shared
        url: https://example.com/shared.git
        ref: main
  - name: crm-hipaa
    system_id: 11111111-1111-4111-8111-111111111111
    framework_id: hipaa
    credential_ref: hipaa-key
    slack_channel_id: C0HIPAABB
    targets:
      - name: shared
        url: https://example.com/shared.git
        ref: main
      - name: extra
        url: https://example.com/extra.git
"""


def _efforts_from(text):
    return pe.parse(text)


def _gen(text, config=None, dm=None):
    """The same sequence cmd_generate runs, against in-memory inputs.

    It mirrors cmd_generate rather than reimplementing it: a helper that skipped a
    check would report a pass for a refusal the real path performs, which is the
    one way a test like this can lie.
    """
    efforts = _efforts_from(text)
    config = config or {}
    agent_ids = {pe.agent_id(e["name"]) for e in efforts}
    channels = {e["slack_channel_id"]: pe.agent_id(e["name"]) for e in efforts}
    preserved, refusals = classify_bindings(get_path(config, "bindings"), channels, agent_ids)
    if dm:
        preserved = apply_dm_edits(preserved, dm, None, agent_ids)
    bound_users = {b["match"]["peer"]["id"] for b in preserved}
    refusals.extend(check_allow_from(get_path(config, "channels.slack.allowFrom"),
                                     bound_users))
    if refusals:
        raise PatchError("; ".join(refusals))
    return build_patch(efforts, config, preserved)


def self_test():
    failures = 0

    def check(ok, label):
        nonlocal failures
        if ok:
            print("PASS  %s" % label)
        else:
            print("FAIL  %s" % label)
            failures += 1

    def refuses(label, fn, expected):
        nonlocal failures
        try:
            fn()
        except (PatchError, pe.ParseError) as exc:
            message = getattr(exc, "message", None) or str(exc)
            if expected in message:
                print("PASS  refuses %s" % label)
            else:
                print("FAIL  refuses %s but with the wrong message: %s" % (label, message))
                failures += 1
        else:
            print("FAIL  ACCEPTED %s (must be refused)" % label)
            failures += 1

    # --- reading a real seeded config -------------------------------------
    #
    # The shipped template is JSON5, and the "//" inside an allowedOrigins URL is
    # the case a naive comment stripper corrupts silently.
    seeded = """
    // a leading comment
    {
      gateway: {
        /* block */ port: 18789,
        controlUi: { allowedOrigins: ["http://127.0.0.1:18789"] }, // trailing
      },
      note: "a // b /* c */ d",
      esc: "a \\" quote // still in the string",
    }
    """
    parsed = load_config_text(seeded)
    check(parsed["gateway"]["port"] == 18789, "json5: comments and trailing commas are stripped")
    check(parsed["gateway"]["controlUi"]["allowedOrigins"] == ["http://127.0.0.1:18789"],
          "json5: a // inside a URL string SURVIVES (the naive-stripper bug)")
    check(parsed["note"] == "a // b /* c */ d",
          "json5: comment markers inside a string are left alone")
    check(parsed["esc"] == 'a " quote // still in the string',
          "json5: an escaped quote does not end the string")
    check(load_config_text("") == {}, "json5: an empty config reads as empty, not an error")
    check(load_config_text('{"a":1}')["a"] == 1, "json5: strict JSON still parses")

    patch, manifest = _gen(TWO_EFFORTS)
    check(len(manifest["fleetFingerprint"]) == 64,
          "the manifest carries a fleet fingerprint")

    # THE FINGERPRINT COVERS A TARGET'S DEFINITION, NOT ONLY ITS NAME. Each of
    # these is a repository change `clawctl dm` must refuse to deploy.
    import importlib.util as _ilu

    def _fp(text):
        import tempfile
        handle = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
        handle.write(text)
        handle.close()
        try:
            return fleet_fingerprint(pe.load(handle.name))
        finally:
            os.unlink(handle.name)

    base_fp = _fp(TWO_EFFORTS)
    check(_fp(TWO_EFFORTS.replace("example.com/shared.git", "example.com/shared-fork.git"))
          != base_fp, "a url-only change alters the fleet fingerprint")
    check(_fp(TWO_EFFORTS.replace("ref: main", "ref: release/1.x")) != base_fp,
          "a ref-only change alters the fleet fingerprint")
    # `private` is only accepted on a github host, so the pair differs in nothing
    # else: the same github url in both, the flag in one.
    gh_public = TWO_EFFORTS.replace("https://example.com/shared.git",
                                    "https://github.com/acme/shared.git")
    gh_private = gh_public.replace("        url: https://github.com/acme/shared.git",
                                   "        url: https://github.com/acme/shared.git\n"
                                   "        private: true")
    check(_fp(gh_private) != _fp(gh_public),
          "a private-only change alters the fleet fingerprint")
    # ...and it stays blind to formatting, which is not a change.
    check(_fp(TWO_EFFORTS.replace("efforts:", "efforts:\n")) == base_fp,
          "reformatting does not alter the fleet fingerprint")
    agents = patch["agents"]["list"]
    servers = patch["mcp"]["servers"]

    check(len(agents) == 2, "two efforts produce two agents")
    check(agents[0]["id"] == "crm-soc2" and agents[1]["id"] == "crm-hipaa",
          "agent ids are the effort names")
    check(agents[0].get("default") is True and "default" not in agents[1],
          "the first effort is the explicit default agent")
    check(agents[0]["workspace"] != agents[1]["workspace"],
          "separate workspaces")
    check(agents[0]["agentDir"] != agents[1]["agentDir"],
          "separate agentDir (OpenClaw forbids sharing it)")

    # THE ISOLATION ASSERTION: each agent denies the OTHER effort's tools by
    # prefix, and never its own.
    check(agents[0]["tools"]["deny"] == ["pretorin-crm-hipaa__*"],
          "agent A denies exactly agent B's MCP tool prefix")
    check(agents[1]["tools"]["deny"] == ["pretorin-crm-soc2__*"],
          "agent B denies exactly agent A's MCP tool prefix")

    check(sorted(servers) == ["pretorin-crm-hipaa", "pretorin-crm-soc2"],
          "one named MCP server per effort")
    check(servers["pretorin-crm-soc2"]["command"] == servers["pretorin-crm-hipaa"]["command"]
          == LAUNCHER,
          "both MCP servers invoke the SAME launcher binary")
    check(servers["pretorin-crm-soc2"]["args"] == ["crm-soc2"]
          and servers["pretorin-crm-hipaa"]["args"] == ["crm-hipaa"],
          "the launcher is given a different effort name per server")

    channel_bindings = [b for b in patch["bindings"]
                        if _peer(b).get("kind") == "channel"]
    check(len(channel_bindings) == 2, "one channel binding per effort")
    check({_peer(b)["id"]: b["agentId"] for b in channel_bindings}
          == {"C0SOC2AAA": "crm-soc2", "C0HIPAABB": "crm-hipaa"},
          "each channel binds to its own agent")
    check(all(_peer(b).get("kind") != "group" for b in patch["bindings"]),
          "NO speculative 'group' binding is emitted (MPIM is not supported)")
    check(sorted(patch["channels"]["slack"]["channels"])
          == sorted(_peer(b)["id"] for b in channel_bindings),
          "the Slack allowlist and the bindings name the same channels")

    # WITHOUT `users`, OpenClaw refuses every slash command in the channel with
    # "You are not authorized to use this command." The channel is the trust
    # boundary: "*" is its members, and nothing widens which channels are served.
    slack_entries = patch["channels"]["slack"]["channels"]
    check(all(e.get("users") == ["*"] for e in slack_entries.values()),
          "every admitted channel authorizes its own members for commands")
    check(all(e.get("requireMention") is True for e in slack_entries.values()),
          "and still answers only on an explicit mention")
    check(patch["channels"]["slack"].get("groupPolicy") is None
          and patch["channels"]["slack"].get("dmPolicy") == "disabled",
          "while the patch widens nothing else: groupPolicy untouched, DMs disabled")

    check("dm" not in patch["channels"]["slack"],
          "channels.slack.dm.* is never written (no MPIM machinery)")
    # `openclaw config patch` REFUSES a --replace-path matching nothing in the
    # patch, so the list has to describe this patch rather than our intentions.
    check(manifest["replacePaths"]
          == ["agents.list", "bindings", "channels.slack.channels"],
          "replace paths omit allowFrom when the patch does not write one")
    check("plugins" not in patch,
          "the patch never names plugins (do not name what you do not own)")

    # DMs off by default.
    check(patch["channels"]["slack"]["dmPolicy"] == "disabled",
          "no DM configuration means dmPolicy stays 'disabled'")
    check("allowFrom" not in patch["channels"]["slack"],
          "no DM configuration means no allowFrom is written")

    # Idempotence: same input, byte-identical patch.
    again, _ = _gen(TWO_EFFORTS)
    check(json.dumps(patch, sort_keys=True) == json.dumps(again, sort_keys=True),
          "regenerating unchanged input yields a byte-identical patch")

    # Targets stay effort-scoped.
    check(manifest["targetsByEffort"] == {"crm-soc2": ["shared"],
                                          "crm-hipaa": ["shared", "extra"]},
          "the manifest records each effort's own targets")
    check(manifest["efforts"]["crm-soc2"]["framework_id"] == "soc2"
          and manifest["efforts"]["crm-hipaa"]["framework_id"] == "hipaa",
          "the manifest records each effort's scope (for the immutability check)")
    check("credential_ref" in manifest["efforts"]["crm-soc2"]
          and manifest["efforts"]["crm-soc2"]["credential_ref"] == "default",
          "the manifest records the credential NAME (never a path or a value)")

    # --- DM behaviour ---
    dm_patch, dm_manifest = _gen(TWO_EFFORTS, dm="U0ABCDEF1:crm-soc2")
    direct = [b for b in dm_patch["bindings"] if _peer(b).get("kind") == "direct"]
    check(len(direct) == 1 and direct[0]["agentId"] == "crm-soc2",
          "an allowed DM user binds to the selected effort agent")
    check(direct[0]["match"]["peer"]["id"] == "U0ABCDEF1",
          "the DM binding matches the Slack USER id, not a D... id")
    check(direct[0]["session"]["dmScope"] == "per-channel-peer",
          "the DM binding carries its own per-channel-peer session scope")
    check(dm_patch["channels"]["slack"]["dmPolicy"] == "allowlist",
          "one bound user flips dmPolicy to allowlist")
    check(dm_patch["channels"]["slack"]["allowFrom"] == ["U0ABCDEF1"],
          "allowFrom is DERIVED from the binding")
    check(dm_manifest["channelBindings"] == manifest["channelBindings"],
          "channel bindings are unaffected by a DM binding")
    check(dm_manifest["replacePaths"]
          == ["agents.list", "bindings", "channels.slack.channels",
              "channels.slack.allowFrom"],
          "replace paths include allowFrom exactly when the patch writes one")

    two_dm, _ = _gen(TWO_EFFORTS, config={"bindings": [
        {"agentId": "crm-hipaa",
         "match": {"channel": "slack", "peer": {"kind": "direct", "id": "U0SECOND1"}}}]},
        dm="U0ABCDEF1:crm-soc2")
    scopes = [b["match"]["peer"]["id"] for b in two_dm["bindings"]
              if _peer(b).get("kind") == "direct"]
    check(sorted(scopes) == ["U0ABCDEF1", "U0SECOND1"],
          "two allowed users keep two separate direct bindings")
    check(two_dm["channels"]["slack"]["allowFrom"] == ["U0ABCDEF1", "U0SECOND1"],
          "allowFrom lists both bound users")

    # A UI-created direct binding survives regeneration untouched.
    seeded = {"bindings": [
        {"agentId": "crm-hipaa",
         "match": {"channel": "slack", "peer": {"kind": "direct", "id": "U0OPER123"}},
         "session": {"dmScope": "per-channel-peer"}},
        {"agentId": "crm-soc2",
         "match": {"channel": "slack", "peer": {"kind": "channel", "id": "C0SOC2AAA"}}},
    ], "channels": {"slack": {"allowFrom": ["U0OPER123"]}}}
    kept, _ = _gen(TWO_EFFORTS, config=seeded)
    check(any(b["match"]["peer"].get("id") == "U0OPER123" and b["agentId"] == "crm-hipaa"
              for b in kept["bindings"]),
          "an operator-created direct binding survives apply verbatim")

    refuses("the same user bound to two efforts",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "crm-soc2",
                 "match": {"channel": "slack", "peer": {"kind": "direct", "id": "U0DUP1234"}}},
                {"agentId": "crm-hipaa",
                 "match": {"channel": "slack", "peer": {"kind": "direct", "id": "U0DUP1234"}}}]}),
            "is bound twice")
    refuses("adding a user who is already bound",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "crm-soc2",
                 "match": {"channel": "slack", "peer": {"kind": "direct", "id": "U0DUP1234"}}}]},
                dm="U0DUP1234:crm-hipaa"),
            "already bound to effort")
    refuses("a direct binding to an agent that no longer exists",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "retired-effort",
                 "match": {"channel": "slack", "peer": {"kind": "direct", "id": "U0GHOST12"}}}]}),
            "no longer exists")
    refuses("a direct binding using a D... conversation id",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "crm-soc2",
                 "match": {"channel": "slack", "peer": {"kind": "direct", "id": "D0123ABCD"}}}]}),
            "not a Slack USER id")
    refuses("an allowFrom entry with no binding",
            lambda: _gen(TWO_EFFORTS,
                         config={"channels": {"slack": {"allowFrom": ["U0UNBOUND"]}}}),
            "routes the DM to the default agent")
    refuses("a wildcard in allowFrom",
            lambda: _gen(TWO_EFFORTS,
                         config={"channels": {"slack": {"allowFrom": ["*"]}}}),
            "A wildcard admits every Slack user")
    refuses("a channel binding not declared in efforts.yaml",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "crm-soc2",
                 "match": {"channel": "slack", "peer": {"kind": "channel", "id": "C0STRAY11"}}}]}),
            "not declared in efforts.yaml")
    refuses("an MPIM-shaped group binding",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "crm-soc2",
                 "match": {"channel": "slack", "peer": {"kind": "group", "id": "G0MPIM123"}}}]}),
            "peer kind 'group'")
    refuses("a non-Slack binding we do not own",
            lambda: _gen(TWO_EFFORTS, config={"bindings": [
                {"agentId": "crm-soc2",
                 "match": {"channel": "discord", "peer": {"kind": "channel", "id": "123"}}}]}),
            "unrecognised binding")
    refuses("--dm-add with a D... id",
            lambda: _gen(TWO_EFFORTS, dm="D0123ABCD:crm-soc2"),
            "not a Slack user id")
    refuses("--dm-add naming an effort that does not exist",
            lambda: _gen(TWO_EFFORTS, dm="U0ABCDEF1:nope"),
            "no effort named")

    # --- removing an effort deactivates only its wiring ---
    one_effort = TWO_EFFORTS.split("  - name: crm-hipaa")[0]
    shrunk, shrunk_manifest = _gen(
        one_effort, config={"mcp": {"servers": {
            "pretorin-crm-soc2": {}, "pretorin-crm-hipaa": {}, "keepme": {}}}})
    check(shrunk["mcp"]["servers"]["pretorin-crm-hipaa"] is None,
          "removing an effort deletes its MCP server with an explicit null")
    check("keepme" not in shrunk["mcp"]["servers"],
          "an unrelated MCP server is not touched")
    check(shrunk_manifest["deactivatedMcpServers"] == ["pretorin-crm-hipaa"],
          "the manifest records the deactivation")

    # --- the legacy single-effort server is retired explicitly ---
    migrated, _ = _gen(TWO_EFFORTS, config={"mcp": {"servers": {"pretorin": {}}}})
    check(migrated["mcp"]["servers"]["pretorin"] is None,
          "the single-effort 'pretorin' MCP server is retired with a null")

    # --- verification: what we own, and what we must NOT require ------------
    # Driven through real files: both bugs these cover were in the comparison.
    import tempfile

    def _verify(cfg, manifest_obj, snap=None):
        d = tempfile.mkdtemp()
        mf = os.path.join(d, "m.json"); cf = os.path.join(d, "c.json")
        sf = os.path.join(d, "s.json")
        json.dump(manifest_obj, open(mf, "w"))
        json.dump(cfg, open(cf, "w"))
        if snap is not None:
            json.dump(snap, open(sf, "w"))
        args = argparse.Namespace(manifest=mf, config=cf,
                                  snapshot=sf if snap is not None else "",
                                  agents_json="", mcp_json="")
        import io, contextlib
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = cmd_verify(args)
        return rc, err.getvalue()

    applied, applied_manifest = _gen(TWO_EFFORTS)
    # A configuration in the state the patch would leave, PLUS an MCP server the
    # operator owns and this deployment must never require to be absent.
    live = {
        "agents": {"list": applied["agents"]["list"]},
        "bindings": applied["bindings"],
        "channels": {"slack": applied["channels"]["slack"]},
        "mcp": {"servers": {k: v for k, v in applied["mcp"]["servers"].items()
                            if v is not None}},
        "gateway": {"port": 18789},
    }
    live["mcp"]["servers"]["operator-owned"] = {"command": "/usr/local/bin/thing"}
    snap = {"gateway": {"port": 18789},
            "mcp": {"servers": {"operator-owned": {"command": "/usr/local/bin/thing"}}}}
    rc, out = _verify(live, applied_manifest, snap)
    check(rc == 0, "verify PASSES with an unrelated MCP server present "
                   "(it must not require equality on the whole key set)")
    if rc != 0:
        print("      " + out.strip().replace("\n", "\n      "))

    # ...and it must still notice one of OURS going missing.
    broken = json.loads(json.dumps(live))
    del broken["mcp"]["servers"]["pretorin-crm-hipaa"]
    rc, out = _verify(broken, applied_manifest, snap)
    check(rc == 1 and "missing the expected server" in out,
          "verify FAILS when one of our own MCP servers is missing")

    # ...and when an unrelated one is altered, which the old equality check could
    # not distinguish from our own churn.
    touched = json.loads(json.dumps(live))
    touched["mcp"]["servers"]["operator-owned"] = {"command": "/tmp/hijacked"}
    rc, out = _verify(touched, applied_manifest, snap)
    check(rc == 1 and "does not own changed" in out,
          "verify FAILS when an MCP server we do NOT own was altered")

    # --- rollback verification ----------------------------------------------
    def _verify_rollback(cfg, snap):
        d = tempfile.mkdtemp()
        cf = os.path.join(d, "c.json"); sf = os.path.join(d, "s.json")
        json.dump(cfg, open(cf, "w")); json.dump(snap, open(sf, "w"))
        import io, contextlib
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = cmd_verify_rollback(argparse.Namespace(config=cf, snapshot=sf))
        return rc, err.getvalue()

    pre = {"gateway": {"port": 18789}, "mcp": {"servers": {"pretorin": {}}}}
    restored = json.loads(json.dumps(pre))
    restored["meta"] = {"lastTouchedAt": "now"}   # OpenClaw stamps this on the restore
    rc, out = _verify_rollback(restored, pre)
    check(rc == 0, "rollback verification PASSES when the config is back to the snapshot")
    check(rc == 0 and "meta" in restored and "meta" not in pre,
          "  and it passed DESPITE OpenClaw stamping a meta block on the restore")

    # THE DISCRIMINATOR. The old code ran the FORWARD verifier here, which compares
    # against the manifest of the change being rolled back — so a correct rollback
    # was always reported as a failure.
    rc, _ = _verify(restored, applied_manifest, pre)
    check(rc == 1, "  (the forward verifier would REJECT a correct rollback — "
                   "which is why rollback needs its own check)")

    half = json.loads(json.dumps(pre))
    half["meta"] = {"lastTouchedAt": "now"}
    half["mcp"]["servers"]["pretorin-crm-soc2"] = {"command": "/x"}
    rc, out = _verify_rollback(half, pre)
    check(rc == 1 and "not the pre-apply state" in out,
          "rollback verification FAILS when the restore left the new state behind")
    check("- mcp differs" in out and "- meta differs" not in out,
          "  and it names the real difference without blaming meta")

    # --- no secret material anywhere in the output ---
    # The manifest names the credential REF (a name, e.g. "default"), which is
    # what efforts.yaml already carries in the clear. What must never appear is a
    # value or a PATH to one — the patch reaches openclaw.json, which lives in a
    # volume, and the manifest reaches a host file.
    blob = json.dumps(patch) + json.dumps(manifest) + json.dumps(dm_patch)
    check("PRETORIN_API_KEY" not in blob
          and "/run/secrets" not in blob
          and "/run/compliance-claw/credentials" not in blob
          and "pretorin-api-key" not in blob,
          "no credential value and no credential PATH appears in the patch or manifest")
    check("credential_ref" not in json.dumps(patch),
          "the patch itself never mentions a credential at all")

    print("")
    print("openclaw-patch self-test: %d case(s) failed" % failures if failures
          else "openclaw-patch self-test: all cases pass")
    return 1 if failures else 0


# --- entry point -----------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="mode")

    gen = sub.add_parser("generate")
    gen.add_argument("--efforts", required=True)
    gen.add_argument("--config", default="")
    gen.add_argument("--out-dir", required=True)
    gen.add_argument("--dm-add", default="")
    gen.add_argument("--dm-remove", default="")

    fp = sub.add_parser("fingerprint")
    fp.add_argument("--efforts", required=True)

    rb = sub.add_parser("verify-rollback")
    rb.add_argument("--config", required=True)
    rb.add_argument("--snapshot", required=True)

    ver = sub.add_parser("verify")
    ver.add_argument("--manifest", required=True)
    ver.add_argument("--config", required=True)
    ver.add_argument("--snapshot", default="")
    ver.add_argument("--agents-json", default="")
    ver.add_argument("--mcp-json", default="")

    args = parser.parse_args(argv[1:])
    if args.self_test:
        return self_test()
    if args.mode is None:
        parser.print_help(sys.stderr)
        return 2
    try:
        if args.mode == "generate":
            return cmd_generate(args)
        if args.mode == "fingerprint":
            sys.stdout.write(fleet_fingerprint(pe.load(args.efforts)) + "\n")
            return 0
        if args.mode == "verify-rollback":
            return cmd_verify_rollback(args)
        return cmd_verify(args)
    except PatchError as exc:
        sys.stderr.write("openclaw-patch: ERROR — %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
