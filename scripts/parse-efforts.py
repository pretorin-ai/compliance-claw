#!/usr/bin/env python3
"""parse-efforts.py — read efforts.yaml, validate it, and resolve credentials.

    parse-efforts.py validate         [FILE]        -> exit 0, or a named error
    parse-efforts.py efforts          [FILE]        -> "<effort>" per line
    parse-efforts.py scope    EFFORT  [FILE]        -> "<system>\\t<framework>\\t<credential_ref>"
    parse-efforts.py list     EFFORT  [FILE]        -> "<name>\\t<url>\\t<private>\\t<ref>"
    parse-efforts.py targets-all      [FILE]        -> the same, deduped across every effort
    parse-efforts.py agents           [FILE]        -> "<effort>\\t<agent>\\t<channel>\\t<mcp>\\t<prefix>\\t<ref>"
    parse-efforts.py credentials      [FILE]        -> "<effort>\\t<ref>\\t<host_path>\\t<container_path>"
    parse-efforts.py credential-path EFFORT [FILE] [--container]
    parse-efforts.py --self-test

THIS FILE OWNS TWO THINGS, AND OWNING BOTH IS THE POINT.

  1. The effort schema.
  2. THE CREDENTIAL LADDER — the mapping from a `credential_ref` name to the file
     that holds the key, on the host AND in the container.

The ladder was very nearly written twice: once here for `clawctl`, once in bash
for the MCP launcher. Two copies of a security-relevant mapping drift, and the
direction they drift in is "the launcher reads a different file than the
validator checked". So `scripts/pretorin-mcp-launch.sh` calls THIS program
instead of reimplementing the table, and there is no second copy anywhere.

TARGET RULES ARE NOT RESTATED HERE EITHER. `validate_target()` is imported from
parse-targets.py, so https-only, the strict `private` boolean, the github.com
restriction and path safety have exactly one definition across both file formats.

`list` emits the SAME four tab-separated fields in the SAME order as
parse-targets.py, deliberately: every shell reader in this repo already reads
that shape, and the field-order contract is load-bearing. Tab is IFS whitespace,
so consecutive tabs collapse and only the LAST field may ever be empty. `private`
is always the literal "true" or "false"; `ref` is optional and therefore last.
Getting this backwards silently turns a private repository into a public one.

Why a hand-written parser: the same reason parse-targets.py has one. Stock macOS
ships /usr/bin/python3 with no PyYAML, and this file's values become directory
names, container paths, credential file paths and process environment, so
anything unexpected must fail loudly rather than be guessed at.

The subset:

    efforts:
      - name: <scalar>
        system_id: <scalar>
        framework_id: <scalar>
        credential_ref: <scalar>
        slack_channel_id: <scalar>
        targets:
          - name: <scalar>
            url: <scalar>
            ref: <scalar>        # optional
            private: true|false  # optional, default false

`system_id` must be a CANONICAL UUID. See _check_system_uuid for why a friendly
name is refused rather than resolved.

FILE defaults to efforts.yaml beside this script's parent directory.
"""

import importlib.util
import os
import re
import sys

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SELF_DIR)


# --- importing a hyphenated sibling ---------------------------------------
# parse-targets.py cannot be `import`ed by name: the hyphen is not a legal
# identifier. Loading it by path is the explicit way to say "this exact file,
# next to me" and keeps the target rules to ONE definition. Renaming
# parse-targets.py to make it importable was rejected: it is referenced by name
# from the Dockerfile, bootstrap.sh, sync-targets.sh, onboard-targets.sh and
# smoke.sh, and a rename to satisfy an import is a lot of blast radius for
# four lines.
def _load_parse_targets():
    path = os.path.join(SELF_DIR, "parse-targets.py")
    spec = importlib.util.spec_from_file_location("_parse_targets", path)
    if spec is None or spec.loader is None:
        sys.stderr.write("parse-efforts: cannot load %s\n" % path)
        raise SystemExit(2)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pt = _load_parse_targets()
ParseError = pt.ParseError
_scalar = pt._scalar

EFFORT_KEYS = ("name", "system_id", "framework_id", "credential_ref",
               "slack_channel_id", "targets")
REQUIRED_EFFORT_KEYS = ("name", "system_id", "framework_id", "credential_ref",
                        "slack_channel_id")
# Keys whose value may legally be empty on its own line, because their content
# is the indented block beneath them.
BLOCK_KEYS = ("targets",)

# THE RESERVED CREDENTIAL NAME. `default` means "the credential this deployment
# already had", i.e. the single pretorin-api-key that predates efforts. It is
# reserved so that a file literally named .../pretorin/default cannot exist and
# quietly shadow the legacy one — two files, one name, and no way to tell which
# a given process read.
DEFAULT_CREDENTIAL = "default"

# Container paths. The first is already mounted by compose.secrets.yaml; the
# second is the directory compose.efforts.yaml adds.
CONTAINER_DEFAULT_PATH = "/run/secrets/pretorin_api_key"
CONTAINER_CREDENTIAL_DIR = "/run/compliance-claw/credentials"
# Host paths, relative to COMPLIANCE_CLAW_SECRET_DIR (default secrets/runtime).
HOST_DEFAULT_FILE = "pretorin-api-key"
HOST_CREDENTIAL_SUBDIR = "pretorin"


# --- token rules -----------------------------------------------------------

# Canonical 8-4-4-4-12, LOWERCASE ONLY. Pretorin's canonical form is lowercase and
# the pinned system is compared literally, so an uppercase UUID recreates exactly
# the write-refusal a friendly name causes. Passed through verbatim.
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                     r"[0-9a-f]{4}-[0-9a-f]{12}$")


def _check_system_uuid(value, owner, lineno):
    """system_id must be the canonical UUID, never a friendly system name.

    Pretorin accepts either in many places, but the CLI resolves a write's target
    to a UUID BEFORE comparing it against the environment-pinned scope, and the
    comparison is literal. Measured on 0.28.7: with PRETORIN_SYSTEM_ID=Fathom, a
    write to that same system's own UUID is REFUSED —

        Active context is 'Fathom / soc2'; refusing write to
        '13c1f44e-b66d-417c-8604-4ac7b988b411 / soc2' without explicit
        scope override.

    So a friendly name here rejects legitimate writes. It also defeats the
    duplicate-pair check below, which compares literals: 'Fathom' and the UUID
    are the same system and would not be seen as one.

    Refused, not resolved. Resolving would mean a name lookup on every parse,
    which turns a pure offline validator into something that needs a credential.
    """
    if not value:
        raise ParseError(lineno, "system_id for effort '%s' is empty" % owner)
    if not UUID_RE.match(value):
        raise ParseError(
            lineno,
            "system_id '%s' (effort '%s') must be the canonical system UUID, not a"
            " name. Pretorin resolves a write's target to a UUID before comparing"
            " it against the pinned scope, and the comparison is literal — so a"
            " name here refuses writes to the very system it names. Find the UUID"
            " with:  docker compose run --rm cli pretorin --json context list"
            " (lowercase; Pretorin's canonical form is lowercase and the comparison"
            " is literal, so an uppercase UUID fails the same way a name does)"
            % (value, owner),
        )


def _check_token(value, what, owner, lineno):
    """Every operator-supplied identifier that becomes a path, an argv element,
    or a process environment value goes through here.

    A leading '-' is the one that does not look dangerous and is: `system_id:
    --system` becomes an argv element, and `pretorin ... --system --system
    <next>` is argument injection into the command clawctl builds. A leading '.'
    is the path-traversal direction. Everything else the character class already
    refuses ('/', '$', '`', ';', '|', spaces, quotes).
    """
    if not value:
        raise ParseError(lineno, "%s for effort '%s' is empty" % (what, owner))
    if not pt.NAME_RE.match(value):
        raise ParseError(
            lineno,
            "%s '%s' (effort '%s') must match [A-Za-z0-9._-]+ — it becomes an argv"
            " element and a container environment value, so shell metacharacters,"
            " slashes and spaces are refused. Reference a system by its UUID if its"
            " name contains anything else." % (what, value, owner),
        )
    if value.startswith("-"):
        raise ParseError(
            lineno,
            "%s '%s' (effort '%s') must not start with '-': it is passed as a"
            " command argument, and a leading dash is read as a flag rather than a"
            " value." % (what, value, owner),
        )
    if value.startswith(".") or value in (".", ".."):
        raise ParseError(
            lineno,
            "%s '%s' (effort '%s') must not start with a dot" % (what, value, owner),
        )


# --- the Slack channel id --------------------------------------------------

# C ONLY, AND THE TWO REJECTIONS BELOW ARE WHY.
#
# A Slack id's first letter is its conversation kind, and the kinds are admitted
# and routed differently:
#
#   C   public or (modern) private channel  -> peer kind "channel"
#   G   LEGACY private channel, OR a multi-person DM (MPIM)
#   D   a one-to-one DM conversation
#
# D is refused because an effort's home is a channel and DM access is configured
# against the Slack USER id instead (scripts/clawctl dm).
#
# G is refused because it is AMBIGUOUS and the two readings need different
# configuration. Measured in the pinned Slack plugin: an MPIM is admitted by
# channels.slack.dm.groupEnabled (default false) plus dm.groupChannels, and a
# routing binding selects an agent only AFTER admission — so a binding alone can
# never make an MPIM work. Telling the two apart needs a live Slack lookup, which
# nothing on the validation path has: `clawctl plan` guarantees zero network, and
# the first `clawctl apply` runs before any gateway exists. Refusing beats
# half-configuring something that silently never routes.
SLACK_CHANNEL_RE = re.compile(r"^C[A-Z0-9]{6,}$")


def _check_slack_channel_id(value, owner, lineno):
    if not value:
        raise ParseError(
            lineno, "slack_channel_id for effort '%s' is empty" % owner)
    if value.startswith("#"):
        raise ParseError(
            lineno,
            "slack_channel_id '%s' (effort '%s') is a channel NAME. The value"
            " becomes a key in the Slack channel allowlist, and a name-based key"
            " silently never routes under groupPolicy 'allowlist' — which is"
            " indistinguishable from the bot being broken. Open the channel ->"
            " right-click -> Copy link, and use the C value at the end of the URL."
            % (value, owner),
        )
    if value.startswith("D"):
        raise ParseError(
            lineno,
            "slack_channel_id '%s' (effort '%s') is a DM conversation id. An"
            " effort's canonical home is a channel, and DM access is configured"
            " separately against the Slack USER id (U...) — see"
            " 'scripts/clawctl dm --help'. Use the channel's C id."
            % (value, owner),
        )
    if value.startswith("G"):
        raise ParseError(
            lineno,
            "slack_channel_id '%s' (effort '%s') is a legacy G id. Slack uses G for"
            " both legacy private channels and multi-person DMs, and the two are"
            " admitted and routed differently — an MPIM additionally needs"
            " channels.slack.dm.groupEnabled, which this deployment does not set."
            " Nothing here can tell them apart without a live Slack lookup, so a G"
            " id is refused rather than half-configured. Modern private channels"
            " have C ids: open the channel -> right-click -> Copy link, and use the"
            " C value. If your workspace only issues G ids for this channel, this"
            " release cannot serve it." % (value, owner),
        )
    if not SLACK_CHANNEL_RE.match(value):
        raise ParseError(
            lineno,
            "slack_channel_id '%s' (effort '%s') is not a Slack channel id."
            " Expected a stable id such as C0123ABCDEF: 'C' followed by at least"
            " six characters, uppercase A-Z and 0-9 only."
            % (value, owner),
        )


# --- derived identifiers ---------------------------------------------------
#
# ONE EFFORT PRODUCES THREE NAMES, AND ALL THREE ARE DERIVED HERE so that
# clawctl, the patch generator and the launcher cannot disagree about them.
#
#   agent id          == the effort name
#   MCP server name   == "pretorin-<effort>"
#   MCP tool prefix   == what OpenClaw makes of that server name
#
# THE TOOL PREFIX IS THE ONE THAT BITES. Each agent's tool policy denies every
# OTHER effort's MCP tools by their prefix glob, so a prefix that is not what we
# think it is points a deny rule at the wrong server — which reads as isolation
# while providing none. OpenClaw's sanitizer (agent-bundle-mcp-names) is
# reproduced below EXACTLY, and the two rules it implies are enforced as schema
# errors rather than discovered in production:
#
#   1. the prefix is truncated at 30 characters
#      "pretorin-fedramp-moderate-authorization-boundary"
#        -> "pretorin-fedramp-moderate-auth"
#   2. two server names that sanitize to the same prefix get a "-2" suffix
#      "a.b" and "a-b" both sanitize to "pretorin-a-b"; the second silently
#      becomes "pretorin-a-b-2"
MCP_SERVER_PREFIX = "pretorin-"
# OpenClaw's TOOL_NAME_MAX_PREFIX.
MCP_PREFIX_MAX = 30
MAX_EFFORT_NAME = MCP_PREFIX_MAX - len(MCP_SERVER_PREFIX)   # 21
_MCP_UNSAFE_RE = re.compile(r"[^A-Za-z0-9_-]")


def agent_id(effort_name):
    """The OpenClaw agent id for an effort. Deliberately identical to the effort
    name: it appears in session keys, workspace paths and audit lines, and a
    second naming scheme would be one more thing to keep in step."""
    return effort_name


def mcp_server_name(effort_name):
    """The mcp.servers key for an effort."""
    return MCP_SERVER_PREFIX + effort_name


def mcp_tool_prefix(server_name):
    """What OpenClaw will call this server's tools, as `<prefix>__<tool>`.

    A transcription of sanitizeToolFragment/sanitizeServerName from the pinned
    OpenClaw, minus the duplicate-suffix loop — validate() refuses duplicates
    outright rather than letting the suffix happen.
    """
    normalized = _MCP_UNSAFE_RE.sub("-", server_name.strip()) or "mcp"
    if not re.match(r"^[A-Za-z]", normalized):
        normalized = "mcp-" + normalized
    return normalized[:MCP_PREFIX_MAX]


# --- the credential ladder (ONE definition) --------------------------------

def host_credential_path(ref, secret_dir=None):
    """Where this credential lives on the HOST."""
    if secret_dir is None:
        secret_dir = os.environ.get("COMPLIANCE_CLAW_SECRET_DIR") or os.path.join(
            REPO_ROOT, "secrets", "runtime")
    if ref == DEFAULT_CREDENTIAL:
        return os.path.join(secret_dir, HOST_DEFAULT_FILE)
    return os.path.join(secret_dir, HOST_CREDENTIAL_SUBDIR, ref)


def container_credential_path(ref):
    """Where this credential is mounted INSIDE the container."""
    if ref == DEFAULT_CREDENTIAL:
        return CONTAINER_DEFAULT_PATH
    return "%s/%s" % (CONTAINER_CREDENTIAL_DIR, ref)


def reserved_collision_path(secret_dir=None):
    """The file that must NOT exist: .../pretorin/default."""
    if secret_dir is None:
        secret_dir = os.environ.get("COMPLIANCE_CLAW_SECRET_DIR") or os.path.join(
            REPO_ROOT, "secrets", "runtime")
    return os.path.join(secret_dir, HOST_CREDENTIAL_SUBDIR, DEFAULT_CREDENTIAL)


# --- parser ----------------------------------------------------------------

def _split_pair_allow_block(text, lineno):
    """Like parse-targets' _split_pair, but tolerates an empty value for the
    keys whose content is the block beneath them (`targets:`)."""
    if ":" not in text:
        raise ParseError(lineno, "expected 'key: value', got: %s" % text)
    key, _, value = text.partition(":")
    key = key.strip()
    value = _scalar(value.strip(), lineno)
    if not key:
        raise ParseError(lineno, "empty key")
    if not value and key not in BLOCK_KEYS:
        raise ParseError(lineno, "key '%s' has an empty value" % key)
    return key, value


def parse(text):
    """Parse the documented subset. Returns [effort_dicts]."""
    efforts = []
    effort = None
    target = None
    effort_indent = None
    target_indent = None
    section = None            # None | "targets"
    section_indent = None
    seen_efforts_key = False

    for lineno, raw in enumerate(text.splitlines(), start=1):
        if "\t" in raw:
            raise ParseError(lineno, "tab character found; YAML indentation must be spaces")
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue

        indent = len(raw) - len(raw.lstrip(" "))
        body = raw.strip()

        # Close anything this line has dedented out of, before dispatching.
        if target is not None and indent <= target_indent:
            target = None
        if section is not None and section_indent is not None and indent <= section_indent:
            section = None
            section_indent = None

        # --- top level -----------------------------------------------------
        if indent == 0:
            if body == "efforts:":
                if seen_efforts_key:
                    raise ParseError(lineno, "duplicate key 'efforts'")
                seen_efforts_key = True
                effort = None
                continue
            key = body.partition(":")[0].strip()
            if key in ("system_id", "framework_id", "targets"):
                raise ParseError(
                    lineno,
                    "'%s' is a targets.yaml key. This is the efforts format: every"
                    " scope lives inside an entry under 'efforts:'. Convert an"
                    " existing targets.yaml with: scripts/clawctl migrate" % key,
                )
            raise ParseError(
                lineno, "unknown top-level key '%s' (the only one is 'efforts')" % key)

        if not seen_efforts_key:
            raise ParseError(lineno, "indented line before 'efforts:': %s" % body)

        # --- list items ----------------------------------------------------
        if body.startswith("- "):
            if effort_indent is None or indent == effort_indent:
                if effort_indent is None:
                    effort_indent = indent
                key, value = _split_pair_allow_block(body[2:], lineno)
                if key != "name":
                    raise ParseError(
                        lineno, "each effort must start with '- name:', got '%s'" % key)
                effort = {"name": value, "_lineno": lineno, "targets": []}
                efforts.append(effort)
                target = None
                section = None
                section_indent = None
                continue
            if section == "targets" and indent > section_indent:
                key, value = _split_pair_allow_block(body[2:], lineno)
                if key != "name":
                    raise ParseError(
                        lineno, "each target must start with '- name:', got '%s'" % key)
                target = {"name": value, "_lineno": lineno}
                target_indent = indent
                effort["targets"].append(target)
                continue
            raise ParseError(lineno, "unexpected list item at this indentation: %s" % body)

        if body == "-" or body.startswith("-"):
            raise ParseError(lineno, "expected '- name: <value>'")

        # --- key: value ----------------------------------------------------
        if effort is None:
            raise ParseError(
                lineno, "expected '- name:' to start an effort, got: %s" % body)

        # Inside a target?
        if target is not None and indent > target_indent:
            key, value = _split_pair_allow_block(body, lineno)
            if key not in pt.ITEM_KEYS:
                raise ParseError(
                    lineno,
                    "unknown target key '%s' (expected %s)" % (key, " / ".join(pt.ITEM_KEYS)))
            if key in target:
                raise ParseError(
                    lineno, "duplicate key '%s' in target '%s'" % (key, target["name"]))
            target[key] = value
            continue

        if indent <= effort_indent:
            raise ParseError(
                lineno, "effort key must be indented past its '- name:': %s" % body)

        key, value = _split_pair_allow_block(body, lineno)
        if key not in EFFORT_KEYS:
            raise ParseError(
                lineno,
                "unknown effort key '%s' (expected %s)" % (key, " / ".join(EFFORT_KEYS)))

        if key == "targets":
            if section == "targets" or effort["targets"]:
                raise ParseError(lineno, "duplicate key 'targets' in effort '%s'" % effort["name"])
            if value:
                raise ParseError(
                    lineno,
                    "'targets:' takes an indented list, not an inline value")
            section = "targets"
            section_indent = indent
            continue

        if key in effort:
            raise ParseError(lineno, "duplicate key '%s' in effort '%s'" % (key, effort["name"]))
        effort[key] = value

    return validate(efforts)


# --- validation ------------------------------------------------------------

# The four target fields that make two same-named targets "the same target".
# ref absent and ref present-but-equal are different only if the values differ,
# so a missing ref normalises to "" for the comparison.
def _target_identity(item):
    return (item["url"], item.get("ref", ""), item.get("private", "false"))


def validate(efforts):
    if not efforts:
        raise ParseError(0, "no efforts defined; at least one is required")

    seen_effort_names = {}
    seen_pairs = {}
    seen_channels = {}
    # sanitized MCP tool prefix -> (effort name, lineno)
    seen_prefixes = {}
    # target name -> (identity tuple, effort name, lineno)
    seen_targets = {}

    for effort in efforts:
        line = effort["_lineno"]
        name = effort["name"]

        # The effort name is a stable identifier for the effort and its agent, so
        # it is held to the same charset as a target name.
        _check_token(name, "effort name", name, line)
        if name in seen_effort_names:
            raise ParseError(
                line,
                "duplicate effort name '%s' (also on line %d)" % (name, seen_effort_names[name]))
        seen_effort_names[name] = line

        # THE TWO PREFIX RULES. See mcp_tool_prefix() for why getting either one
        # wrong points an agent's deny glob at the wrong MCP server — isolation
        # that looks configured and is not.
        if len(name) > MAX_EFFORT_NAME:
            raise ParseError(
                line,
                "effort name '%s' is %d characters; the maximum is %d. The name"
                " becomes the MCP server '%s', whose model-facing tool prefix"
                " OpenClaw truncates at %d characters — so a longer name produces"
                " '%s', and the per-agent tool policy that denies other efforts'"
                " tools by prefix would then point at the wrong server. Shorten it."
                % (name, len(name), MAX_EFFORT_NAME, mcp_server_name(name),
                   MCP_PREFIX_MAX, mcp_tool_prefix(mcp_server_name(name))),
            )
        prefix = mcp_tool_prefix(mcp_server_name(name))
        if prefix in seen_prefixes:
            other, other_line = seen_prefixes[prefix]
            raise ParseError(
                line,
                "effort '%s' and effort '%s' (line %d) both produce the MCP tool"
                " prefix '%s'. OpenClaw replaces every character outside"
                " [A-Za-z0-9_-] with '-' when it names an MCP server's tools, so"
                " names differing only in those characters collide — and the"
                " second one silently becomes '%s-2', leaving the per-agent tool"
                " policy denying a server that no longer answers to that name."
                " Rename one of them."
                % (name, other, other_line, prefix, prefix),
            )
        seen_prefixes[prefix] = (name, line)

        for key in REQUIRED_EFFORT_KEYS:
            if key not in effort:
                raise ParseError(line, "effort '%s' has no %s" % (name, key))

        _check_system_uuid(effort["system_id"], name, line)
        _check_token(effort["framework_id"], "framework_id", name, line)
        _check_token(effort["credential_ref"], "credential_ref", name, line)
        _check_slack_channel_id(effort["slack_channel_id"], name, line)

        # ONE CHANNEL ROUTES TO ONE AGENT. The channel id is both an allowlist key
        # and a binding's peer id; two efforts claiming it would produce two
        # bindings in the same match tier, where OpenClaw takes the first in config
        # order and the other effort silently never answers in its own channel.
        channel = effort["slack_channel_id"]
        if channel in seen_channels:
            other, other_line = seen_channels[channel]
            raise ParseError(
                line,
                "effort '%s' and effort '%s' (line %d) both declare"
                " slack_channel_id '%s'. One channel binds to exactly one agent:"
                " two bindings on one peer land in the same match tier, the first"
                " in config order wins, and the other effort would never answer"
                " anywhere. Give each effort its own channel."
                % (name, other, other_line, channel),
            )
        seen_channels[channel] = (name, line)

        # One preflight artifact is keyed on system+framework. Two efforts on the
        # same pair are the same compliance effort wearing two names, and they
        # would sweep and bind over each other's resolvers forever.
        pair = (effort["system_id"], effort["framework_id"])
        if pair in seen_pairs:
            other, other_line = seen_pairs[pair]
            raise ParseError(
                line,
                "effort '%s' has the same system_id + framework_id as effort '%s'"
                " (line %d). Pretorin keys preflight state and the active recipe set"
                " on that pair, so these are one compliance effort, not two — they"
                " would overwrite each other's resolvers. Merge them."
                % (name, other, other_line),
            )
        seen_pairs[pair] = (name, line)

        if not effort["targets"]:
            raise ParseError(line, "effort '%s' has no targets" % name)

        # Per-target rules come from parse-targets.py, so they cannot drift.
        local = {}
        for item in effort["targets"]:
            pt.validate_target(item)
            tname = item["name"]
            if tname in local:
                raise ParseError(
                    item["_lineno"],
                    "duplicate target name '%s' within effort '%s' (also on line %d)"
                    % (tname, name, local[tname]))
            local[tname] = item["_lineno"]

            # THE GLOBAL TARGET NAMESPACE, WITH AN EQUAL-DEFINITION EXEMPTION.
            #
            # Every target is cloned to ONE directory, workspace/targets/<name>,
            # and Pretorin derives resolver names from the directory basename. So
            # the name is global, not per-effort. But sharing a repository between
            # efforts is a first-class case — the same code reviewed under SOC 2
            # and under HIPAA — so the same name in two efforts is allowed when the
            # definitions are IDENTICAL: one clone, bound into each scope.
            #
            # Two different definitions under one name is the failure this catches.
            # Without it, whichever effort synchronised last would silently decide
            # what every other effort is reviewing.
            if tname in seen_targets:
                identity, other_effort, other_line = seen_targets[tname]
                if identity != _target_identity(item):
                    differing = []
                    for field, mine, theirs in (
                        ("url", item["url"], identity[0]),
                        ("ref", item.get("ref", ""), identity[1]),
                        ("private", item.get("private", "false"), identity[2]),
                    ):
                        if mine != theirs:
                            differing.append("%s (%r here, %r there)" % (
                                field, mine, theirs))
                    raise ParseError(
                        item["_lineno"],
                        "target '%s' in effort '%s' conflicts with target '%s' in"
                        " effort '%s' (line %d): %s. Target names are a GLOBAL"
                        " namespace — every target is cloned to the one directory"
                        " workspace/targets/%s — so the same name must mean the same"
                        " repository everywhere. Give one of them a different name,"
                        " or make the definitions identical."
                        % (tname, name, tname, other_effort, other_line,
                           "; ".join(differing), tname),
                    )
            else:
                seen_targets[tname] = (_target_identity(item), name, item["_lineno"])

    return efforts


def load(path):
    try:
        with open(path, "r") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("parse-efforts: cannot read %s: %s\n" % (path, exc.strerror))
        raise SystemExit(2)
    try:
        return parse(text)
    except ParseError as exc:
        sys.stderr.write("parse-efforts: %s: %s\n" % (path, exc))
        raise SystemExit(2)


def union_targets(efforts):
    """Every target any effort declares, once, in declaration order.

    Returns (name, url, private, ref) tuples in `list`'s field order. Sharing a
    repository between efforts is a first-class case — the same code under SOC 2
    and under HIPAA — and it must produce ONE clone at workspace/targets/<name>.
    validate() has already refused two DIFFERENT definitions under one name, so
    the first occurrence is the agreed definition rather than an arbitrary winner.
    """
    seen = set()
    out = []
    for effort in efforts:
        for item in effort["targets"]:
            if item["name"] in seen:
                continue
            seen.add(item["name"])
            out.append((item["name"], item["url"], item["private"],
                        item.get("ref", "")))
    return out


def find_effort(efforts, name):
    for effort in efforts:
        if effort["name"] == name:
            return effort
    sys.stderr.write(
        "parse-efforts: no effort named '%s'. Declared: %s\n"
        % (name, ", ".join(e["name"] for e in efforts)))
    raise SystemExit(2)


# --- self-test -------------------------------------------------------------
# Every case is a real failure mode. This file's values become directory names,
# container paths, credential file paths and process environment, so the table
# leans on the injection shapes and on the two rules that are genuinely new:
# the system+framework pair being unique, and the global target namespace with
# its equal-definition exemption.

GOOD = """
# a comment
efforts:
  - name: crm-soc2
    system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411
    framework_id: soc2
    credential_ref: default
    slack_channel_id: C0SOC2AAA
    targets:
      - name: simple-crm
        url: https://example.com/a.git
        ref: main
      - name: secret-repo
        url: 'https://github.com/acme/secret-repo.git'   # trailing comment
        private: true

  - name: crm-hipaa
    system_id: 13c1f44e-b66d-417c-8604-4ac7b988b411
    framework_id: hipaa
    credential_ref: hipaa-key
    slack_channel_id: C0HIPAABB
    targets:
      # SAME name, IDENTICAL definition -> one clone, bound into both scopes.
      - name: simple-crm
        url: https://example.com/a.git
        ref: main
"""

E = "efforts:\n  - name: %s\n    system_id: %s\n    framework_id: %s\n    credential_ref: %s\n    slack_channel_id: %s\n    targets:\n      - name: t\n        url: https://example.com/a.git\n"


UUID_A = "11111111-1111-4111-8111-111111111111"
UUID_B = "22222222-2222-4222-8222-222222222222"


def _e(name="a", sys_=UUID_A, fw="f", cred="default", chan="C0000001"):
    return E % (name, sys_, fw, cred, chan)


SHARED = ("efforts:\n"
          "  - name: one\n    system_id: " + UUID_A + "\n    framework_id: f1\n    credential_ref: default\n"
          "    slack_channel_id: C0000011\n"
          "    targets:\n      - name: t\n        url: https://example.com/a.git\n%s"
          "  - name: two\n    system_id: " + UUID_A + "\n    framework_id: f2\n    credential_ref: default\n"
          "    slack_channel_id: C0000012\n"
          "    targets:\n      - name: t\n        url: %s\n%s")

CASES = [
    ("tab indentation", "efforts:\n\t- name: a\n", "tab character"),
    ("unknown top-level key", "nope: 1\nefforts:\n  - name: a\n", "unknown top-level key"),
    ("targets.yaml key at top level", "system_id: a\nefforts:\n  - name: a\n", "clawctl migrate"),
    ("targets: at top level", "targets:\n  - name: a\n", "clawctl migrate"),
    ("duplicate efforts key", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000101\n    targets:\n      - name: t\n        url: https://e/r.git\nefforts:\n", "duplicate key 'efforts'"),
    ("no efforts", "efforts:\n", "no efforts defined"),
    ("indented line before efforts:", "  stray: 1\nefforts:\n", "before 'efforts:'"),
    ("duplicate effort name", _e("a") + _e("a").replace("efforts:\n", ""), "duplicate effort name"),
    ("duplicate system+framework pair",
     "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000102\n    targets:\n      - name: t1\n        url: https://e/r.git\n"
     "  - name: b\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000103\n    targets:\n      - name: t2\n        url: https://e/r.git\n",
     "same system_id + framework_id"),
    ("missing system_id", "efforts:\n  - name: a\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000104\n    targets:\n      - name: t\n        url: https://e/r.git\n", "has no system_id"),
    ("missing framework_id", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    credential_ref: c\n    slack_channel_id: C0000105\n    targets:\n      - name: t\n        url: https://e/r.git\n", "has no framework_id"),
    ("missing credential_ref", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    slack_channel_id: C0000106\n    targets:\n      - name: t\n        url: https://e/r.git\n", "has no credential_ref"),
    ("effort with no targets", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000117\n", "has no targets"),
    # --- injection shapes ---
    ("command substitution in name", _e(name="$(whoami)"), "must match"),
    ("backtick in name", _e(name="a`id`"), "must match"),
    ("semicolon in system_id", _e(sys_="s;rm -rf /"), "must be the canonical system UUID"),
    ("pipe in framework_id", _e(fw="f|nc"), "must match"),
    ("path traversal in credential_ref", _e(cred="../../etc/passwd"), "must match"),
    ("absolute path in credential_ref", _e(cred="/etc/passwd"), "must match"),
    ("space in system_id", _e(sys_="My System"), "must be the canonical system UUID"),
    # A quote MID-value is not "unbalanced" — _scalar only unquotes when the
    # value OPENS with a quote — so it falls through to the charset check, which
    # is the correct refusal. The unbalanced-quote path is the next case.
    ("quote in name", _e(name='a"b'), "must match"),
    ("unbalanced quote", "efforts:\n  - name: 'a\n", "unbalanced quote"),
    ("ARGV INJECTION: leading dash system_id", _e(sys_="--system"), "must be the canonical system UUID"),
    ("leading dash framework_id", _e(fw="-f"), "must not start with '-'"),
    ("leading dash credential_ref", _e(cred="-c"), "must not start with '-'"),
    ("leading dot effort name", _e(name=".hidden"), "must not start with a dot"),
    ("leading dot credential_ref", _e(cred=".ssh"), "must not start with a dot"),
    ("empty value", "efforts:\n  - name: a\n    system_id:\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000107\n    targets:\n      - name: t\n        url: https://e/r.git\n", "empty value"),
    # --- system_id must be a UUID, never a friendly name ---
    ("FRIENDLY NAME as system_id", _e(sys_="Fathom"), "must be the canonical system UUID"),
    ("almost-a-uuid (too short)", _e(sys_="11111111-1111-4111-8111-11111111111"), "must be the canonical system UUID"),
    ("uuid with wrong separators", _e(sys_="11111111_1111_4111_8111_111111111111"), "must be the canonical system UUID"),
    ("UPPERCASE uuid", _e(sys_="11111111-1111-4111-8111-11111111111A"), "must be the canonical system UUID"),
    ("mixed-case uuid", _e(sys_="11111111-1111-4111-8111-11111111111a".replace("a", "A", 1)), "must be the canonical system UUID"),
    # --- the global target namespace ---
    ("shared target, CONFLICTING url", SHARED % ("", "https://example.com/DIFFERENT.git", ""), "conflicts with target"),
    ("shared target, CONFLICTING ref", SHARED % ("        ref: main\n", "https://example.com/a.git", "        ref: develop\n"), "conflicts with target"),
    ("shared target, CONFLICTING private", SHARED % ("", "https://github.com/o/t.git", "        private: true\n"), "conflicts with target"),
    ("duplicate target within one effort", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000108\n    targets:\n      - name: t\n        url: https://e/r.git\n      - name: t\n        url: https://e/r.git\n", "duplicate target name 't' within effort"),
    # `connections:` is NOT part of this schema; it must read as an unknown key
    # rather than being silently tolerated for a future release.
    ("connections is not a key yet", _e() + "    connections: []\n", "unknown effort key"),
    # --- the Slack channel id ---
    #
    # C ONLY. The two interesting rejections are D and G, and they are separate
    # cases because they are separate mistakes with separate remedies.
    ("slack_channel_id missing",
     "efforts:\n  - name: a\n    system_id: " + UUID_A + "\n    framework_id: f\n    credential_ref: c\n"
     "    targets:\n      - name: t\n        url: https://e/r.git\n", "has no slack_channel_id"),
    ("slack_channel_id is a DM id", _e(chan="D0123ABCDEF"), "is a DM conversation id"),
    ("slack_channel_id is a legacy G id", _e(chan="G0123ABCDEF"), "is a legacy G id"),
    ("slack_channel_id is a channel NAME", _e(chan="#compliance"), "is a channel NAME"),
    ("slack_channel_id lowercase", _e(chan="C0123abcdef"), "is not a Slack channel id"),
    ("slack_channel_id too short", _e(chan="C0123"), "is not a Slack channel id"),
    ("slack_channel_id wrong prefix", _e(chan="X0123ABCDEF"), "is not a Slack channel id"),
    ("duplicate slack_channel_id across efforts",
     _e("one", fw="f1", chan="C0000777") + _e("two", fw="f2", chan="C0000777").replace("efforts:\n", ""),
     "both declare"),

    # --- derived MCP identifiers ---
    #
    # Both of these are silent-misrouting bugs if they get through: the per-agent
    # tool policy denies other efforts by MCP tool prefix, so a truncated or
    # suffixed prefix denies a server that is not the one it names.
    ("effort name too long for the MCP tool prefix",
     _e(name="fedramp-moderate-authorization"), "the maximum is 21"),
    ("effort names colliding after MCP sanitization",
     _e("a.b", fw="f1", chan="C0000801") + _e("a-b", fw="f2", chan="C0000802").replace("efforts:\n", ""),
     "both produce the MCP tool prefix"),

    # --- structure ---
    ("unknown effort key", _e() + "    region: us\n", "unknown effort key"),
    ("unknown target key", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000109\n    targets:\n      - name: t\n        url: https://e/r.git\n        branch: main\n", "unknown target key"),
    ("duplicate effort key", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    system_id: t\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000110\n    targets:\n      - name: t\n        url: https://e/r.git\n", "duplicate key 'system_id'"),
    ("duplicate targets key", _e() + "    targets:\n      - name: u\n        url: https://e/r.git\n", "duplicate key 'targets'"),
    ("targets with inline value", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    targets: nope\n", "indented list, not an inline value"),
    ("effort not starting with - name", "efforts:\n  - system_id: 11111111-1111-4111-8111-111111111111\n    name: a\n", "each effort must start with '- name:'"),
    ("target not starting with - name", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000111\n    targets:\n      - url: https://e/r.git\n", "each target must start with '- name:'"),
    ("bare dash", "efforts:\n  -\n", "expected '- name: <value>'"),
    # --- target rules inherited from parse-targets.py (must NOT drift) ---
    ("non-https url", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000112\n    targets:\n      - name: t\n        url: git@github.com:o/r.git\n", "must start with https://"),
    ("missing url", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000113\n    targets:\n      - name: t\n        ref: main\n", "has no url"),
    ("private: yes", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000114\n    targets:\n      - name: t\n        url: https://github.com/o/r.git\n        private: yes\n", "must be exactly 'true' or 'false'"),
    ("private on a non-github host", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000115\n    targets:\n      - name: t\n        url: https://gitlab.com/o/r.git\n        private: true\n", "only work for https://github.com/"),
    ("target name traversal", "efforts:\n  - name: a\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n    credential_ref: c\n    slack_channel_id: C0000116\n    targets:\n      - name: ../etc\n        url: https://e/r.git\n", "must match"),
]


def _shell_reads_list_correctly():
    """Read our own `list` output the way the shell callers do, in a real shell.

    Guards the FIELD ORDER contract: tab is IFS whitespace, so a target with no
    `ref` emitted as "name<TAB>url<TAB><TAB>true" collapses to THREE fields and
    `private` lands in the wrong variable — a private repository silently treated
    as public. parse-targets.py has the same guard; this one proves the efforts
    format kept the contract.
    """
    import subprocess
    text = ("efforts:\n  - name: e\n    system_id: 11111111-1111-4111-8111-111111111111\n    framework_id: f\n"
            "    credential_ref: default\n    slack_channel_id: C0000042\n    targets:\n"
            "      - name: p\n        url: https://github.com/o/p.git\n        private: true\n"
            "      - name: q\n        url: https://github.com/o/q.git\n        ref: main\n")
    efforts = parse(text)
    tsv = "".join("%s\t%s\t%s\t%s\n" % (t["name"], t["url"], t["private"], t.get("ref", ""))
                  for t in efforts[0]["targets"])
    script = ('while IFS="\t" read -r NAME URL PRIVATE REF; do '
              'printf "%s:%s:%s\\n" "$NAME" "$PRIVATE" "$REF"; done')
    out = subprocess.run(["bash", "-c", script], input=tsv,
                         capture_output=True, text=True).stdout.strip().splitlines()
    return out == ["p:true:", "q:false:main"], out


def self_test():
    failures = 0

    ok, observed = _shell_reads_list_correctly()
    if ok:
        print("PASS  bash reads private correctly when ref is absent")
    else:
        print("FAIL  bash misreads private when ref is absent: %r" % (observed,))
        failures += 1

    try:
        efforts = parse(GOOD)
    except ParseError as exc:
        print("FAIL  happy path rejected: %s" % exc)
        return 1

    checks = [
        (len(efforts) == 2, "effort count"),
        (efforts[0]["name"] == "crm-soc2", "first effort name"),
        (efforts[0]["system_id"] == "13c1f44e-b66d-417c-8604-4ac7b988b411", "system_id"),
        (efforts[0]["framework_id"] == "soc2", "framework_id"),
        (efforts[0]["credential_ref"] == "default", "credential_ref"),
        (len(efforts[0]["targets"]) == 2, "target count"),
        (efforts[0]["targets"][0].get("ref") == "main", "target ref"),
        (efforts[0]["targets"][1]["url"] == "https://github.com/acme/secret-repo.git",
         "quoted url + trailing comment"),
        (efforts[0]["targets"][1]["private"] == "true", "private: true accepted"),
        (efforts[0]["targets"][0]["private"] == "false", "absent private defaults to false"),
        ("ref" not in efforts[1]["targets"][0] or efforts[1]["targets"][0]["ref"] == "main",
         "shared target keeps its ref"),
        (efforts[1]["credential_ref"] == "hipaa-key", "second effort credential_ref"),
    ]
    # The whole point of the exemption: this file has two efforts naming one target.
    checks.append((efforts[1]["targets"][0]["name"] == "simple-crm",
                   "SHARED target with an IDENTICAL definition is ACCEPTED"))

    # The derived identifiers, and the sanitizer transcription that the two
    # schema rules above depend on being correct.
    checks += [
        (agent_id("crm-soc2") == "crm-soc2", "derived: agent id is the effort name"),
        (mcp_server_name("crm-soc2") == "pretorin-crm-soc2", "derived: MCP server name"),
        (mcp_tool_prefix("pretorin-crm-soc2") == "pretorin-crm-soc2",
         "derived: a short name passes through the sanitizer unchanged"),
        (mcp_tool_prefix("pretorin-a.b") == "pretorin-a-b",
         "derived: '.' becomes '-' (this is why a.b and a-b collide)"),
        (mcp_tool_prefix("pretorin-fedramp-moderate-authorization-boundary")
         == "pretorin-fedramp-moderate-auth",
         "derived: the prefix truncates at 30 characters"),
        (len(MCP_SERVER_PREFIX) + MAX_EFFORT_NAME == MCP_PREFIX_MAX,
         "derived: the name limit is exactly what fits in the prefix"),
    ]

    # The union: one clone per name, first definition wins, `list` field order.
    union = union_targets(efforts)
    checks += [
        ([t[0] for t in union] == ["simple-crm", "secret-repo"],
         "targets-all: SHARED target appears ONCE across two efforts"),
        (union[1][2] == "true", "targets-all: keeps `private` in the third field"),
        (union[0][3] == "main", "targets-all: keeps `ref` in the fourth field"),
    ]

    # The credential ladder, both modes, both rungs.
    checks += [
        (host_credential_path("default", "/S") == "/S/pretorin-api-key",
         "ladder: host default -> the legacy file"),
        (host_credential_path("hipaa-key", "/S") == "/S/pretorin/hipaa-key",
         "ladder: host named -> the pretorin/ directory"),
        (container_credential_path("default") == "/run/secrets/pretorin_api_key",
         "ladder: container default -> the already-mounted secret"),
        (container_credential_path("hipaa-key") == "/run/compliance-claw/credentials/hipaa-key",
         "ladder: container named -> the credentials mount"),
        (reserved_collision_path("/S") == "/S/pretorin/default",
         "ladder: the reserved collision path"),
    ]

    for ok, label in checks:
        if ok:
            print("PASS  happy path: %s" % label)
        else:
            print("FAIL  happy path: %s" % label)
            failures += 1

    for label, text, expected in CASES:
        try:
            parse(text)
        except ParseError as exc:
            if expected in exc.message:
                print("PASS  rejects %s" % label)
            else:
                print("FAIL  rejects %s but with the wrong message: %s" % (label, exc.message))
                failures += 1
        else:
            print("FAIL  ACCEPTED %s (must be rejected)" % label)
            failures += 1

    total = len(CASES) + len(checks) + 1
    print("")
    print("parse-efforts self-test: %d case(s) failed" % failures if failures else
          "parse-efforts self-test: all %d cases pass" % total)
    return 1 if failures else 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    if argv[1] == "--self-test":
        return self_test()

    args = [a for a in argv[1:] if a != "--container"]
    want_container = "--container" in argv[1:]
    mode = args[0]

    default_file = os.path.join(REPO_ROOT, "efforts.yaml")
    if mode in ("validate", "efforts", "credentials", "targets-all", "agents"):
        path = args[1] if len(args) > 1 else default_file
        effort_name = None
    elif mode in ("scope", "list", "credential-path"):
        if len(args) < 2:
            sys.stderr.write("parse-efforts: %s needs an effort name\n" % mode)
            return 2
        effort_name = args[1]
        path = args[2] if len(args) > 2 else default_file
    else:
        sys.stderr.write(
            "parse-efforts: unknown mode '%s' (expected validate / efforts / scope /"
            " list / targets-all / agents / credentials / credential-path)\n" % mode)
        return 2

    efforts = load(path)

    if mode == "validate":
        return 0
    if mode == "efforts":
        for effort in efforts:
            print(effort["name"])
        return 0
    if mode == "credentials":
        for effort in efforts:
            ref = effort["credential_ref"]
            print("%s\t%s\t%s\t%s" % (
                effort["name"], ref, host_credential_path(ref), container_credential_path(ref)))
        return 0
    if mode == "targets-all":
        # THE UNION, DEDUPED, in the same four-field shape `list` emits — so every
        # existing shell reader takes it unchanged. This is what makes efforts.yaml
        # authoritative for cloning: bootstrap needs every repository any effort
        # declares, exactly once. validate() has already refused two different
        # definitions under one name, so first-wins here is not a choice between
        # rivals; it is the one agreed definition.
        for name, url, private, ref in union_targets(efforts):
            print("%s\t%s\t%s\t%s" % (name, url, private, ref))
        return 0
    if mode == "agents":
        # One row per effort: everything downstream needs to generate an agent,
        # a binding and an MCP server, derived HERE so nothing re-derives it.
        for effort in efforts:
            name = effort["name"]
            server = mcp_server_name(name)
            print("%s\t%s\t%s\t%s\t%s\t%s" % (
                name, agent_id(name), effort["slack_channel_id"],
                server, mcp_tool_prefix(server), effort["credential_ref"]))
        return 0

    effort = find_effort(efforts, effort_name)

    if mode == "scope":
        print("%s\t%s\t%s" % (
            effort["system_id"], effort["framework_id"], effort["credential_ref"]))
        return 0
    if mode == "credential-path":
        ref = effort["credential_ref"]
        print(container_credential_path(ref) if want_container else host_credential_path(ref))
        return 0
    # list: private BEFORE ref. validate_target always populates private, and only
    # the last field may be empty. See the field-order note in the docstring.
    for item in effort["targets"]:
        print("%s\t%s\t%s\t%s" % (
            item["name"], item["url"], item["private"], item.get("ref", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
