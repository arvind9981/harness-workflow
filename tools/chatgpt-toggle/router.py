# /// script
# requires-python = ">=3.12"
# dependencies = ["starlette", "httpx", "uvicorn"]
# ///
"""Front-router: fixed ANTHROPIC_BASE_URL -> {headroom | claude-code-proxy}."""
import os
from dataclasses import dataclass

HEADROOM_URL = os.environ.get("HEADROOM_URL", "http://127.0.0.1:8787")
BRIDGE_URL = os.environ.get("BRIDGE_URL", "http://127.0.0.1:18765")
SMALL_FAST_MODEL = os.environ.get("SMALL_FAST_MODEL", "claude-sonnet-5")
CODEX_MODEL = os.environ.get("CODEX_MODEL", "gpt-5.5")  # last-resort literal only
STATE_FILE = os.environ.get(
    "GPT_TOGGLE_STATE_FILE",
    os.path.expanduser("~/.config/chatgpt-toggle/state"),
)
MODEL_FILE = os.environ.get(  # explicit user override, if set
    "GPT_TOGGLE_MODEL_FILE",
    os.path.expanduser("~/.config/chatgpt-toggle/model"),
)
DEFAULT_FILE = os.environ.get(  # dynamically resolved default (gpt-toggle refresh)
    "GPT_TOGGLE_DEFAULT_FILE",
    os.path.expanduser("~/.config/chatgpt-toggle/model-default"),
)
USAGE_FILE = os.environ.get(  # rolling GPT request accounting for the status bar
    "GPT_TOGGLE_USAGE_FILE",
    os.path.expanduser("~/.config/chatgpt-toggle/gpt-usage.json"),
)
ROUTER_PORT = int(os.environ.get("ROUTER_PORT", "8788"))


@dataclass(frozen=True)
class Route:
    upstream: str
    rewrite_model: str | None


def decide(model, toggle, small_fast_model, headroom_url, bridge_url, codex_model) -> Route:
    # Background/small-fast tasks always stay on Claude, even on the GPT path.
    # Prefix-tolerant so a date-suffixed small id (claude-sonnet-5-YYYYMMDD)
    # still routes to Claude and never bleeds onto the GPT/Codex path.
    if model == small_fast_model or model.startswith(small_fast_model + "-"):
        return Route(upstream=headroom_url, rewrite_model=None)
    # Explicit GPT model (e.g. selected in /model) -> bridge, pass the exact id
    # through unchanged. This is what lets one session mix Claude and GPT per
    # request: no toggle flip, no rewrite, the picked model is what serves.
    if model.startswith("gpt-"):
        return Route(upstream=bridge_url, rewrite_model=None)
    # Global-toggle fallback: a Claude model on the GPT path is rewritten to the
    # resolved Codex model. Preserves the original gpt-toggle UX for setups that
    # can't surface GPT ids in the /model picker.
    if toggle == "gpt":
        return Route(upstream=bridge_url, rewrite_model=codex_model)
    return Route(upstream=headroom_url, rewrite_model=None)


import json
import time
import tempfile
import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import StreamingResponse, Response
from starlette.routing import Route as StarletteRoute
from toggle import read_state, read_model
from usage import record_usage

# Response headers we must NOT copy verbatim (length/encoding are recomputed by us).
_DROP_RESP_HEADERS = {"content-length", "content-encoding", "transfer-encoding", "connection"}


def _persist_gpt_usage(status: int) -> None:
    """Fold one GPT-routed request into the usage state file (best-effort).

    Atomic write (temp file + rename) so a concurrent status-bar read never
    sees a half-written file. Never raises into the request path.
    """
    try:
        try:
            with open(USAGE_FILE) as f:
                state = json.load(f)
        except (FileNotFoundError, ValueError):
            state = {}
        state = record_usage(state, dest="gpt", status=status, now=int(time.time()))
        d = os.path.dirname(USAGE_FILE)
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".gpt-usage-", suffix=".tmp")
        with os.fdopen(fd, "w") as f:
            json.dump(state, f)
        os.replace(tmp, USAGE_FILE)
    except OSError:
        pass  # telemetry must never break routing


async def proxy(request: Request) -> Response:
    body = await request.body()
    try:
        payload = json.loads(body) if body else {}
        model = payload.get("model", "")
    except (ValueError, AttributeError):
        payload, model = None, ""

    # explicit override > dynamically-resolved default > last-resort literal
    codex_model = read_model(MODEL_FILE, read_model(DEFAULT_FILE, CODEX_MODEL))
    route = decide(model, read_state(STATE_FILE), SMALL_FAST_MODEL,
                   HEADROOM_URL, BRIDGE_URL, codex_model)

    # One line per request so it's clear which model actually served — the
    # answer to "am I on Claude or GPT right now?". Shows the requested id, the
    # served id (after any rewrite), and the upstream host.
    dest = "gpt" if route.upstream == BRIDGE_URL else "claude"
    served = route.rewrite_model or model or "(none)"
    print(f"[route] requested={model or '(none)'} served={served} -> {dest}",
          flush=True)

    out_body = body
    if route.rewrite_model and payload is not None:
        payload["model"] = route.rewrite_model
        out_body = json.dumps(payload).encode()

    # Forward headers, but let httpx/us set length, host, and force identity encoding.
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in {"host", "content-length", "accept-encoding"}}
    headers["content-length"] = str(len(out_body))
    url = route.upstream.rstrip("/") + request.url.path

    client = httpx.AsyncClient(timeout=None)
    upstream_req = client.build_request(
        request.method, url, headers=headers, content=out_body,
        params=request.query_params)
    upstream = await client.send(upstream_req, stream=True)

    # Record GPT-bridge requests for the status bar (headers are in; body still
    # streams). Claude-path requests are not recorded — Claude Code already
    # reports those via .rate_limits in the status-line JSON.
    if route.upstream == BRIDGE_URL:
        _persist_gpt_usage(upstream.status_code)

    async def stream():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    resp_headers = {k: v for k, v in upstream.headers.items()
                    if k.lower() not in _DROP_RESP_HEADERS}
    return StreamingResponse(stream(), status_code=upstream.status_code, headers=resp_headers)


app = Starlette(routes=[StarletteRoute("/{path:path}", proxy,
                methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])])


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=ROUTER_PORT)
