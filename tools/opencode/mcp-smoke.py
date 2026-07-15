#!/usr/bin/env python3

"""Token-free Claude worker handshake, with an optional fake-backed call test."""

from __future__ import annotations

import argparse
import json
import selectors
import subprocess
import sys
import time
from typing import Any


def send(process: subprocess.Popen[str], message: dict[str, Any]) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def receive(
    process: subprocess.Popen[str],
    selector: selectors.BaseSelector,
    request_id: int,
    deadline: float,
) -> dict[str, Any]:
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
                raise RuntimeError(str(message["error"]))
            return message.get("result", {})
    raise TimeoutError(f"timed out waiting for MCP response id={request_id}")


def content_json(result: dict[str, Any]) -> dict[str, Any]:
    for item in result.get("content", []):
        if item.get("type") == "text":
            return json.loads(item.get("text") or "{}")
    raise RuntimeError("MCP result did not contain JSON text content")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", required=True)
    parser.add_argument("--claude-bin", required=True)
    parser.add_argument("--invoke", action="store_true")
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    process = subprocess.Popen(
        [sys.executable, args.worker, "--claude-bin", args.claude_bin],
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
                    "clientInfo": {"name": "opencode-doctor", "version": "1"},
                },
            },
        )
        receive(process, selector, 1, deadline)
        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        listed = receive(process, selector, 2, deadline)
        names = {tool.get("name") for tool in listed.get("tools", [])}
        if names != {"claude", "claude-reply"}:
            raise RuntimeError(f"unexpected tools: {sorted(names)}")

        if args.invoke:
            send(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "claude",
                        "arguments": {"role": "advisor", "prompt": "Return START_OK."},
                    },
                },
            )
            started = content_json(receive(process, selector, 3, deadline))
            if started.get("sessionId") != "session-test" or started.get("result") != "START_OK":
                raise RuntimeError(f"unexpected start result: {started}")
            usage = started.get("usage") or {}
            if usage.get("inputTokens") != 120 or usage.get("outputTokens") != 30:
                raise RuntimeError(f"worker discarded model usage: {started}")
            send(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {
                        "name": "claude-reply",
                        "arguments": {"sessionId": "session-test", "prompt": "Return REPLY_OK."},
                    },
                },
            )
            replied = content_json(receive(process, selector, 4, deadline))
            if replied.get("result") != "REPLY_OK":
                raise RuntimeError(f"unexpected reply result: {replied}")
        print("claude,claude-reply")
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
