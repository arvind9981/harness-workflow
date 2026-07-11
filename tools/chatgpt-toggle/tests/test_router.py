import json
from pathlib import Path
import sys
import httpx
import respx
from starlette.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import router


def _client(monkeypatch, tmp_path, state, model="gpt-5.5"):
    (tmp_path / "state").write_text(state)
    (tmp_path / "model").write_text(model)
    monkeypatch.setattr(router, "STATE_FILE", str(tmp_path / "state"))
    monkeypatch.setattr(router, "MODEL_FILE", str(tmp_path / "model"))
    monkeypatch.setattr(router, "SMALL_FAST_MODEL", "claude-sonnet-5")
    monkeypatch.setattr(router, "CODEX_MODEL", "gpt-5.5")
    return TestClient(router.app)


@respx.mock
def test_gpt_on_rewrites_model_and_hits_bridge(monkeypatch, tmp_path):
    route = respx.post("http://127.0.0.1:18765/v1/messages").mock(
        return_value=httpx.Response(200, json={"ok": True}))
    client = _client(monkeypatch, tmp_path, "gpt")
    r = client.post("/v1/messages", json={"model": "claude-opus-4-8", "max_tokens": 8, "messages": []})
    assert r.status_code == 200
    assert route.called
    sent = json.loads(route.calls.last.request.content)
    assert sent["model"] == "gpt-5.5"
    assert route.calls.last.request.headers["content-length"] == str(len(route.calls.last.request.content))


@respx.mock
def test_small_model_goes_to_headroom_unrewritten(monkeypatch, tmp_path):
    route = respx.post("http://127.0.0.1:8787/v1/messages").mock(
        return_value=httpx.Response(200, json={"ok": True}))
    client = _client(monkeypatch, tmp_path, "gpt")
    r = client.post("/v1/messages", json={"model": "claude-sonnet-5", "max_tokens": 8, "messages": []})
    assert route.called
    sent = json.loads(route.calls.last.request.content)
    assert sent["model"] == "claude-sonnet-5"


@respx.mock
def test_gpt_model_from_model_file_is_used_for_rewrite(monkeypatch, tmp_path):
    route = respx.post("http://127.0.0.1:18765/v1/messages").mock(
        return_value=httpx.Response(200, json={"ok": True}))
    client = _client(monkeypatch, tmp_path, "gpt", model="gpt-5.6-terra")
    client.post("/v1/messages", json={"model": "claude-opus-4-8", "max_tokens": 8, "messages": []})
    sent = json.loads(route.calls.last.request.content)
    assert sent["model"] == "gpt-5.6-terra"


@respx.mock
def test_toggle_off_sends_main_model_to_headroom(monkeypatch, tmp_path):
    route = respx.post("http://127.0.0.1:8787/v1/messages").mock(
        return_value=httpx.Response(200, json={"ok": True}))
    client = _client(monkeypatch, tmp_path, "claude")
    client.post("/v1/messages", json={"model": "claude-opus-4-8", "max_tokens": 8, "messages": []})
    assert route.called
