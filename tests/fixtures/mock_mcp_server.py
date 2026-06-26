#!/usr/bin/env python3
"""Minimal MCP server for tests — speaks newline-delimited JSON-RPC 2.0 over stdio,
the same transport real MCP servers use. Implements initialize, the initialized
notification, tools/list and tools/call (echo, add). Stdlib only; logs nothing to
stdout (protocol channel) so the client's line parser stays clean.
"""
import sys, json

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

TOOLS = [
    {"name": "echo", "description": "Echo back the given text",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "add", "description": "Add two numbers a and b",
     "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}},
]

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
            "serverInfo": {"name": "mock-mcp", "version": "0.1"}}})
    elif method == "notifications/initialized":
        pass  # a notification — no reply
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        p = msg.get("params") or {}
        name, args = p.get("name"), (p.get("arguments") or {})
        if name == "echo":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": "echo: " + str(args.get("text", ""))}], "isError": False}})
        elif name == "add":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text", "text": str((args.get("a") or 0) + (args.get("b") or 0))}], "isError": False}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown tool: " + str(name)}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown method: " + str(method)}})
