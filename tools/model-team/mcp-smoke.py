#!/usr/bin/env python3

"""Perform a token-free MCP initialize/tools-list handshake with Codex."""

from __future__ import annotations

import argparse
import json
import selectors
import subprocess
import time


def send(process: subprocess.Popen[str], message: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def wait_for_id(
    process: subprocess.Popen[str], selector: selectors.BaseSelector, request_id: int, deadline: float
) -> dict:
    while time.monotonic() < deadline:
        events = selector.select(max(0.0, deadline - time.monotonic()))
        if not events:
            break
        assert process.stdout is not None
        line = process.stdout.readline()
        if not line:
            break
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(f"MCP request {request_id} failed: {message['error']}")
            return message.get("result", {})
    raise TimeoutError(f"timed out waiting for MCP response id={request_id}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-bin", required=True)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    process = subprocess.Popen(
        [
            args.codex_bin,
            "mcp-server",
            "-c",
            "mcp_servers.MCP_DOCKER.enabled=false",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    selector = selectors.DefaultSelector()
    assert process.stdout is not None
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.timeout
    try:
        send(
            process,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "model-team-doctor", "version": "1"},
                },
            },
        )
        wait_for_id(process, selector, 1, deadline)
        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        result = wait_for_id(process, selector, 2, deadline)
        names = sorted(tool.get("name", "") for tool in result.get("tools", []))
        required = {"codex", "codex-reply"}
        if not required.issubset(names):
            raise RuntimeError(f"missing required tools: {sorted(required - set(names))}")
        print(",".join(name for name in names if name in required))
        return 0
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
