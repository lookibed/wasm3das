#!/usr/bin/env python3
"""
Command-line client for the EdenSpark editor's MCP server.

Runs on the Windows side (the editor listens on 127.0.0.1:54300, Windows
loopback only), so from WSL call it through Windows interop:

    /mnt/c/Python313/python.exe -X utf8 <this file> <tool> [json-args]

or via scripts/eden/edenmcp (the bash wrapper that does exactly that).

Examples:
    edenmcp get_game_status
    edenmcp exec_cheat '{"cmd":"wasm3_tests"}'
    edenmcp get_logs
    edenmcp game_restart
    edenmcp --list

Exit codes: 0 = tool call succeeded, 1 = tool returned isError, 2 = transport
error (editor not running, bad JSON), 3 = usage error.

Output: the concatenated text content of the tool result on stdout. Images
(screenshots) are written to --out <file> if given, otherwise skipped.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("EDENSPARK_MCP_URL", "http://127.0.0.1:54300/mcp")
TIMEOUT = float(os.environ.get("EDENSPARK_MCP_TIMEOUT", "600"))
_next_id = [1]


def rpc(method, params=None):
    msg = {"jsonrpc": "2.0", "id": _next_id[0], "method": method}
    _next_id[0] += 1
    if params is not None:
        msg["params"] = params
    body = json.dumps(msg).encode("utf-8")
    req = urllib.request.Request(
        URL, data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        raw = resp.read().decode("utf-8", "replace")
    if not raw.strip():
        return None
    obj = json.loads(raw)
    if "error" in obj:
        raise RuntimeError("%s: %s" % (method, obj["error"]))
    return obj.get("result")


def handshake():
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                       "clientInfo": {"name": "edenmcp-cli", "version": "1"}})


def main(argv):
    out_file = None
    args = list(argv)
    if "--out" in args:
        i = args.index("--out")
        out_file = args[i + 1]
        del args[i:i + 2]
    if not args or args[0] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 3
    try:
        handshake()
        if args[0] == "--list":
            res = rpc("tools/list")
            for t in res.get("tools", []):
                print("%s\t%s" % (t["name"], (t.get("description") or "").split("\n")[0][:100]))
            return 0
        tool = args[0]
        params = {}
        if len(args) > 1:
            params = json.loads(args[1])
        res = rpc("tools/call", {"name": tool, "arguments": params})
    except urllib.error.URLError as e:
        sys.stderr.write("edenmcp: editor not reachable at %s (%s)\n" % (URL, e.reason))
        return 2
    except (ValueError, RuntimeError) as e:
        sys.stderr.write("edenmcp: %s\n" % e)
        return 2
    texts = []
    for c in res.get("content", []):
        if c.get("type") == "text":
            texts.append(c.get("text", ""))
        elif c.get("type") == "image" and out_file:
            with open(out_file, "wb") as f:
                f.write(base64.b64decode(c.get("data", "")))
            texts.append("[image written to %s]" % out_file)
    sys.stdout.write("\n".join(texts))
    if texts and not texts[-1].endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.flush()
    return 1 if res.get("isError") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
