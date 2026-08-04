#!/usr/bin/env python3
"""mcp-call.py — call one Pretorin MCP tool over stdio and report the result.

    mcp-call.py <tool_name> ['<json arguments>']

Runs inside the container: it spawns `pretorin mcp-serve`, performs the MCP
handshake, calls one tool, prints the text content, and exits.

    0  the tool returned a result
    3  the tool returned isError (an authorization or validation failure —
       a REAL answer from the server, not a transport problem)
    1  transport/protocol failure: the server died, timed out, or answered
       with a JSON-RPC error

That exit-code split is the point of this script. scripts/smoke.sh uses it to
prove key posture through the same transport the agent uses — a read tool
succeeding and a write tool being rejected server-side — without needing model
credentials, which `openclaw agent` would require.

The working directory is deliberately the same sentinel the gateway configures
(mcp.servers.pretorin.cwd), so this client cannot accidentally pass a CWD-based
probe that the real runtime would fail.
"""

import json
import os
import signal
import subprocess
import sys

PRETORIN = "/usr/local/bin/pretorin"
CWD = "/opt/compliance-claw/no-repo"
TIMEOUT_SECONDS = int(os.environ.get("MCP_CALL_TIMEOUT", "120"))


def fail(message, code=1):
    sys.stderr.write("mcp-call: %s\n" % message)
    raise SystemExit(code)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    tool = argv[1]
    try:
        arguments = json.loads(argv[2]) if len(argv) > 2 and argv[2] else {}
    except ValueError as exc:
        fail("arguments are not valid JSON: %s" % exc, 2)

    def on_alarm(_signum, _frame):
        fail("timed out after %ds calling %s" % (TIMEOUT_SECONDS, tool))

    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(TIMEOUT_SECONDS)

    proc = subprocess.Popen(
        [PRETORIN, "mcp-serve"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        cwd=CWD if os.path.isdir(CWD) else None,
        text=True,
    )

    def send(payload):
        proc.stdin.write(json.dumps(payload) + "\n")
        proc.stdin.flush()

    def recv():
        # The server may interleave non-JSON banner lines; skip anything that is
        # not a JSON object rather than treating it as a protocol error.
        while True:
            line = proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except ValueError:
                continue

    try:
        send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "compliance-claw-smoke", "version": "1"},
            },
        })
        if recv() is None:
            fail("mcp-serve exited during initialize (is PRETORIN_API_KEY set?)")
        send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        })
        response = recv()
    finally:
        signal.alarm(0)
        proc.kill()
        proc.wait()

    if response is None:
        fail("no response to tools/call %s" % tool)
    if "error" in response:
        fail("JSON-RPC error calling %s: %s" % (tool, json.dumps(response["error"])))

    result = response.get("result") or {}
    text = "\n".join(
        block.get("text", "") for block in result.get("content", []) if isinstance(block, dict)
    )

    if result.get("isError"):
        sys.stderr.write(text + "\n" if text else "mcp-call: tool reported isError\n")
        return 3
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
