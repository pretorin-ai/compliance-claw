#!/usr/bin/env python3
"""Refuse shell scripts that EXECUTE text they meant to PRINT.

An unquoted heredoc (`<<EOF`) performs command substitution on its body. So a
command name written in backticks for a human to read is not displayed — it is
run, on the host, and its output replaces the name in the sentence.

Found in the credentialed acceptance run of the CLI self-update work.
scripts/onboard-targets.sh ended with an operator message naming the command you
must NOT use:

    (Not `openclaw mcp reload` from the cli service: ...)

inside a `cat <<EOF`. The shell ran it. The run printed

    scripts/onboard-targets.sh: line 334: openclaw: command not found

and the message itself came out as "(Not  from the cli service:" — the one word
the sentence existed to say had been deleted by the shell. Two repo conventions
broken at once: name-the-fix, and never execute what you intend to display.

The fix is a backslash-escaped backtick in an expanding heredoc, or a quoted
delimiter (`<<'EOF'`) when the body needs no expansion at all.

BACKTICKS ONLY, DELIBERATELY. `$(...)` is not checked: in an operator message it
is always intentional, and this repo relies on it — bootstrap.sh's completion
text uses `$([ ... ] && printf ...)` to vary a line by condition. Nobody writes
`$(foo)` in prose hoping it will show up as `$(foo)`; people write ``foo`` in prose
constantly. Flagging both would mean a linter the repo has to suppress, which is
worse than no linter.

Static, so it runs with no credentials and no containers. Exits 1 and names
every offending file:line when the property does not hold.

    python3 scripts/lint-heredocs.py scripts/*.sh
"""

import re
import sys

# `<<WORD`, `<<-WORD`, `<<"WORD"`, `<<'WORD'`. A quoted delimiter is recorded
# too, because its body must be SKIPPED rather than scanned: quoting the
# delimiter is exactly the sanctioned fix, not a violation.
HEREDOC_START = re.compile(
    r"""<<(?P<dash>-?)\s*(?P<q>["']?)(?P<word>[A-Za-z_][A-Za-z0-9_]*)(?P=q)"""
)

UNESCAPED_BACKTICK = re.compile(r"(?<!\\)`")


def offenders(path):
    """Yield 'path:line' for every unescaped backtick in an expanding heredoc."""
    delim = None
    dash = False
    expands = False
    found = []

    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")

            if delim is None:
                # A COMMENT-ONLY LINE IS NOT A HEREDOC START. Without this, the
                # comment in onboard-targets.sh that explains the `python3 -
                # <<EOF` idiom opens a phantom heredoc, and every backtick in
                # every comment for the next 250 lines reads as a violation.
                # Only safe while delim is None: inside a heredoc body, a leading
                # `#` is literal text, not a comment.
                if line.lstrip().startswith("#"):
                    continue
                match = HEREDOC_START.search(line)
                if match:
                    delim = match.group("word")
                    dash = bool(match.group("dash"))
                    # No quotes around the delimiter => the body expands.
                    expands = not match.group("q")
                continue

            # `<<-` strips leading TABS (not spaces) from the terminator.
            terminator = line.lstrip("\t") if dash else line
            if terminator.strip() == delim:
                delim = None
                continue

            if expands and UNESCAPED_BACKTICK.search(line):
                found.append(f"{path}:{lineno}")

    return found


def main(argv):
    paths = argv[1:]
    if not paths:
        print("usage: lint-heredocs.py <script> [script ...]", file=sys.stderr)
        return 2

    bad = []
    for path in paths:
        bad.extend(offenders(path))

    if not bad:
        return 0

    print(
        "lint-heredocs: unescaped backtick inside an EXPANDING heredoc.\n"
        "  This text is EXECUTED, not printed. Escape it (\\`), or quote the\n"
        "  delimiter (<<'EOF') if the body needs no expansion.",
        file=sys.stderr,
    )
    for entry in bad:
        print(f"  {entry}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
