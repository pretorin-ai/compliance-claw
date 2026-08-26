#!/usr/bin/env python3
"""parse-targets.py — read targets.yaml and emit TSV for the shell scripts.

Usage:
    parse-targets.py scope [FILE]    -> "<system_id>\\t<framework_id>"
    parse-targets.py list  [FILE]    -> "<name>\\t<url>\\t<private>\\t<ref>"
    parse-targets.py --self-test     -> run the validation case table

FIELD ORDER IS LOAD-BEARING, and `ref` is last for a reason worth stating:

    TAB IS AN IFS *WHITESPACE* CHARACTER, so `IFS=$'\\t' read -r A B C D`
    collapses consecutive tabs into ONE delimiter. A target with no `ref`
    emitted as "name<TAB>url<TAB><TAB>true" is read as THREE fields, and
    `true` lands in the ref variable while private comes back empty — a
    private repository silently treated as public, which then fails with an
    authentication error that reads like a network fault.

Only the LAST field may ever be empty. `private` is always the literal "true" or
"false" and never empty, so it is safe in the middle; `ref` is optional, so it
goes at the end. Any future optional field must also go after it, or the shell
readers in bootstrap.sh and smoke.sh have to stop using tab.

FILE defaults to targets.yaml beside this script's parent directory.

Why a hand-written parser instead of PyYAML: the only Python guaranteed on a
stock macOS is /usr/bin/python3 from the Command Line Tools, and it does NOT
ship PyYAML (a local `import yaml` that appears to work is usually a user
site-install under ~/Library/Python). Bootstrap already requires git, which
comes from the same Command Line Tools, so stdlib-only python3 is a dependency
we know is present. The cost is that only the documented subset parses -- which
is deliberate: this file's values become directory names and container paths, so
anything unexpected must fail loudly rather than be guessed at.

The subset:

    system_id: <scalar>
    framework_id: <scalar>
    targets:
      - name: <scalar>
        url: <scalar>
        ref: <scalar>        # optional
        private: true|false  # optional, default false

Comments (whole-line and trailing ` #`), single/double quoted scalars, and
blank lines are handled. Everything else -- tabs, anchors, nested maps, flow
sequences, multi-line scalars, unknown keys -- is an error.
"""

import os
import re
import sys

TOP_KEYS = ("system_id", "framework_id")
ITEM_KEYS = ("name", "url", "ref", "private")
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

# A private target is authenticated with a GitHub App installation token (host,
# scripts/bootstrap.sh) or a fine-grained PAT (container, scripts/sync-targets.sh).
# Both are github.com credentials. Any other host would silently fall back to an
# anonymous clone and fail as if the repo were missing, so the host is restricted
# here where the error can name the real reason.
PRIVATE_URL_PREFIX = "https://github.com/"


class ParseError(Exception):
    def __init__(self, lineno, message):
        super().__init__("line %d: %s" % (lineno, message))
        self.lineno = lineno
        self.message = message


def _scalar(value, lineno):
    """Resolve one scalar: strip a trailing ` #` comment, then unquote.

    A quoted scalar is unquoted at its CLOSING quote, not at the end of the
    line -- otherwise `'x'  # note` keeps the comment inside the value, which is
    how the first version of this function was wrong.
    """
    quote = value[:1]
    if quote in ("'", '"'):
        close = value.find(quote, 1)
        if close < 0:
            raise ParseError(lineno, "unbalanced quote in value: %s" % value)
        rest = value[close + 1:].strip()
        if rest and not rest.startswith("#"):
            raise ParseError(lineno, "unexpected text after closing quote: %s" % rest)
        return value[1:close]
    cut = value.find(" #")
    if cut >= 0:
        value = value[:cut].rstrip()
    if value.endswith("'") or value.endswith('"'):
        raise ParseError(lineno, "unbalanced quote in value: %s" % value)
    return value


def _split_pair(text, lineno):
    if ":" not in text:
        raise ParseError(lineno, "expected 'key: value', got: %s" % text)
    key, _, value = text.partition(":")
    key = key.strip()
    value = _scalar(value.strip(), lineno)
    if not key:
        raise ParseError(lineno, "empty key")
    if not value:
        raise ParseError(lineno, "key '%s' has an empty value" % key)
    return key, value


def parse(text):
    """Parse the documented subset. Returns (scope_dict, [target_dicts])."""
    scope = {}
    targets = []
    item = None
    item_indent = None
    in_targets = False

    for lineno, raw in enumerate(text.splitlines(), start=1):
        if "\t" in raw:
            raise ParseError(lineno, "tab character found; YAML indentation must be spaces")
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue

        indent = len(raw) - len(raw.lstrip(" "))
        body = raw.strip()

        # Top level: scope keys, or the targets: header.
        if indent == 0:
            if body == "targets:":
                if in_targets:
                    raise ParseError(lineno, "duplicate key 'targets'")
                in_targets = True
                item = None
                continue
            key, value = _split_pair(body, lineno)
            if key not in TOP_KEYS:
                raise ParseError(
                    lineno,
                    "unknown top-level key '%s' (expected %s or targets)"
                    % (key, " / ".join(TOP_KEYS)),
                )
            if key in scope:
                raise ParseError(lineno, "duplicate key '%s'" % key)
            if in_targets:
                raise ParseError(lineno, "'%s' must appear before targets:" % key)
            scope[key] = value
            continue

        # Indented: only legal inside the targets list.
        if not in_targets:
            raise ParseError(lineno, "indented line outside targets: %s" % body)

        if body.startswith("- "):
            key, value = _split_pair(body[2:], lineno)
            if key != "name":
                raise ParseError(lineno, "each target must start with '- name:', got '%s'" % key)
            item = {"name": value, "_lineno": lineno}
            item_indent = indent
            targets.append(item)
            continue

        if body == "-" or body.startswith("-"):
            raise ParseError(lineno, "expected '- name: <value>'")

        if item is None:
            raise ParseError(lineno, "expected '- name:' to start a target, got: %s" % body)
        if indent <= item_indent:
            raise ParseError(lineno, "continuation line must be indented past its '- name:'")
        key, value = _split_pair(body, lineno)
        if key not in ITEM_KEYS:
            raise ParseError(
                lineno, "unknown target key '%s' (expected %s)" % (key, " / ".join(ITEM_KEYS))
            )
        if key in item:
            raise ParseError(lineno, "duplicate key '%s' in target '%s'" % (key, item["name"]))
        item[key] = value

    return validate(scope, targets)


def validate(scope, targets):
    for key in TOP_KEYS:
        if key not in scope:
            raise ParseError(0, "missing required top-level key '%s'" % key)
    if not targets:
        raise ParseError(0, "no targets defined; at least one is required")

    seen = {}
    for item in targets:
        line = item["_lineno"]
        name = item["name"]
        # name becomes ./workspace/targets/<name> on the host and
        # /workspace/targets/<name> in the container, so it is path-critical.
        if not NAME_RE.match(name):
            raise ParseError(line, "target name '%s' must match [A-Za-z0-9._-]+" % name)
        if name.startswith(".") or name in (".", ".."):
            raise ParseError(line, "target name '%s' must not start with a dot" % name)
        if name in seen:
            raise ParseError(line, "duplicate target name '%s' (also on line %d)" % (name, seen[name]))
        seen[name] = line
        if "url" not in item:
            raise ParseError(line, "target '%s' has no url" % name)
        if not item["url"].startswith("https://"):
            raise ParseError(
                line,
                "target '%s' url must start with https:// (SSH remotes are not supported)"
                % name,
            )

        # Strict boolean. YAML would accept yes/on/True for `private`, and a value
        # that quietly parses as "not true" is the dangerous direction: a private
        # repo treated as public fails with an authentication error that looks
        # like a network problem. Two spellings, nothing else.
        raw = item.get("private", "false")
        if raw not in ("true", "false"):
            raise ParseError(
                line,
                "target '%s' private must be exactly 'true' or 'false', got '%s'"
                % (name, raw),
            )
        item["private"] = raw
        if raw == "true" and not item["url"].startswith(PRIVATE_URL_PREFIX):
            raise ParseError(
                line,
                "target '%s' is private but its url is not on github.com; both"
                " supported credentials — a GitHub App installation token on the"
                " host, and the fine-grained PAT used for synchronization from"
                " the container — only work for %s" % (name, PRIVATE_URL_PREFIX),
            )
    return scope, targets


def load(path):
    try:
        with open(path, "r") as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("parse-targets: cannot read %s: %s\n" % (path, exc.strerror))
        raise SystemExit(2)
    try:
        return parse(text)
    except ParseError as exc:
        sys.stderr.write("parse-targets: %s: %s\n" % (path, exc))
        raise SystemExit(2)


# --- self-test -------------------------------------------------------------
# Every case is a real failure mode, not a hypothetical: the parser turns this
# file into filesystem paths, so `name: ../x` and friends must be rejected.

GOOD = """
# comment
system_id: sys-1
framework_id: soc2
targets:
  - name: simple-crm
    url: https://example.com/a.git
    ref: main
  - name: other
    url: 'https://example.com/b.git'   # trailing comment
  - name: secret-repo
    url: https://github.com/acme/secret-repo.git
    private: true
"""

CASES = [
    ("tab indentation", "system_id: a\nframework_id: b\ntargets:\n\t- name: x\n", "tab character"),
    ("unknown top key", "system_id: a\nframework_id: b\nnope: 1\ntargets:\n  - name: x\n    url: https://e/r.git\n", "unknown top-level key"),
    ("duplicate top key", "system_id: a\nsystem_id: c\nframework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n", "duplicate key 'system_id'"),
    ("duplicate name", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n  - name: x\n    url: https://e/s.git\n", "duplicate target name"),
    ("path traversal", "system_id: a\nframework_id: b\ntargets:\n  - name: ../etc\n    url: https://e/r.git\n", "must match"),
    ("absolute path name", "system_id: a\nframework_id: b\ntargets:\n  - name: /etc/passwd\n    url: https://e/r.git\n", "must match"),
    ("dotfile name", "system_id: a\nframework_id: b\ntargets:\n  - name: .git\n    url: https://e/r.git\n", "must not start with a dot"),
    ("non-https url", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: git@github.com:o/r.git\n", "must start with https://"),
    ("missing url", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    ref: main\n", "has no url"),
    ("unknown target key", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n    branch: main\n", "unknown target key"),
    ("duplicate target key", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n    url: https://e/s.git\n", "duplicate key 'url'"),
    ("missing framework_id", "system_id: a\ntargets:\n  - name: x\n    url: https://e/r.git\n", "missing required top-level key 'framework_id'"),
    ("missing system_id", "framework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n", "missing required top-level key 'system_id'"),
    ("no targets", "system_id: a\nframework_id: b\n", "no targets defined"),
    ("empty targets list", "system_id: a\nframework_id: b\ntargets:\n", "no targets defined"),
    ("empty value", "system_id:\nframework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n", "empty value"),
    ("item not starting with name", "system_id: a\nframework_id: b\ntargets:\n  - url: https://e/r.git\n    name: x\n", "must start with '- name:'"),
    ("scope key after targets", "system_id: a\ntargets:\n  - name: x\n    url: https://e/r.git\nframework_id: b\n", "must appear before targets:"),
    ("indented line outside targets", "system_id: a\n  stray: 1\nframework_id: b\n", "indented line outside targets"),
    ("unbalanced quote", "system_id: 'a\nframework_id: b\ntargets:\n  - name: x\n    url: https://e/r.git\n", "unbalanced quote"),
    ("bare dash", "system_id: a\nframework_id: b\ntargets:\n  -\n", "expected '- name: <value>'"),
    ("no colon", "system_id: a\nframework_id b\n", "expected 'key: value'"),
    # private: the dangerous direction is a value that parses as "not true", which
    # turns a private repo into a public one and produces an auth error that reads
    # like a network fault. Every YAML-truthy spelling other than `true` is rejected.
    ("private: yes", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://github.com/o/r.git\n    private: yes\n", "must be exactly 'true' or 'false'"),
    ("private: True", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://github.com/o/r.git\n    private: True\n", "must be exactly 'true' or 'false'"),
    ("private: 1", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://github.com/o/r.git\n    private: 1\n", "must be exactly 'true' or 'false'"),
    ("private on a non-github host", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://gitlab.com/o/r.git\n    private: true\n", "only work for https://github.com/"),
    ("duplicate private key", "system_id: a\nframework_id: b\ntargets:\n  - name: x\n    url: https://github.com/o/r.git\n    private: true\n    private: false\n", "duplicate key 'private'"),
]


def _shell_reads_private_correctly():
    """Read our own `list` output the way bootstrap.sh does, in a real shell.

    This is not a parser test. It guards the FIELD ORDER contract described in
    the module docstring: tab is IFS whitespace, so a target with no `ref` would
    collapse two tabs into one and shift `private` into the wrong variable.
    A pure-Python assertion cannot catch that -- only bash can.
    """
    import subprocess
    # A private target with NO ref: the exact shape that broke.
    text = ("system_id: s\nframework_id: f\ntargets:\n"
            "  - name: p\n    url: https://github.com/o/p.git\n    private: true\n"
            "  - name: q\n    url: https://github.com/o/q.git\n    ref: main\n")
    scope, targets = parse(text)
    tsv = "".join("%s\t%s\t%s\t%s\n" % (t["name"], t["url"], t["private"], t.get("ref", ""))
                  for t in targets)
    script = ('while IFS="\t" read -r NAME URL PRIVATE REF; do '
              'printf "%s:%s:%s\\n" "$NAME" "$PRIVATE" "$REF"; done')
    out = subprocess.run(["bash", "-c", script], input=tsv,
                         capture_output=True, text=True).stdout.strip().splitlines()
    return out == ["p:true:", "q:false:main"], out


def self_test():
    failures = 0

    ok, observed = _shell_reads_private_correctly()
    if ok:
        print("PASS  bash reads private correctly when ref is absent")
    else:
        print("FAIL  bash misreads private when ref is absent: %r" % (observed,))
        print("      field order must be name/url/private/ref -- tab is IFS whitespace")
        failures += 1

    try:
        scope, targets = parse(GOOD)
    except ParseError as exc:
        print("FAIL  happy path rejected: %s" % exc)
        return 1
    checks = [
        (scope.get("system_id") == "sys-1", "system_id"),
        (scope.get("framework_id") == "soc2", "framework_id"),
        (len(targets) == 3, "target count"),
        (targets[0]["name"] == "simple-crm", "first name"),
        (targets[0].get("ref") == "main", "first ref"),
        (targets[1]["url"] == "https://example.com/b.git", "quoted url + trailing comment"),
        ("ref" not in targets[1], "absent ref stays absent"),
        (targets[0]["private"] == "false", "absent private defaults to false"),
        (targets[2]["private"] == "true", "private: true accepted on a github url"),
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

    print("")
    print("parse-targets self-test: %d case(s) failed" % failures if failures else
          "parse-targets self-test: all %d cases pass" % (len(CASES) + len(checks) + 1))
    return 1 if failures else 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    if argv[1] == "--self-test":
        return self_test()

    mode = argv[1]
    if mode not in ("scope", "list"):
        sys.stderr.write("parse-targets: unknown mode '%s' (expected scope or list)\n" % mode)
        return 2

    default = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "targets.yaml")
    path = argv[2] if len(argv) > 2 else default
    scope, targets = load(path)

    if mode == "scope":
        print("%s\t%s" % (scope["system_id"], scope["framework_id"]))
    else:
        for item in targets:
            # private BEFORE ref: validate() always populates private, and only the
            # last field may be empty. See the field-order note in the module
            # docstring — getting this backwards silently turns a private
            # repository into a public one.
            print("%s\t%s\t%s\t%s" % (
                item["name"], item["url"], item["private"], item.get("ref", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
