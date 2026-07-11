from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from router import decide, Route

HEADROOM = "http://127.0.0.1:8787"
BRIDGE = "http://127.0.0.1:18765"
SMALL = "claude-sonnet-5"
CODEX = "gpt-5.5"


def test_small_model_always_goes_to_headroom_even_when_gpt_on():
    r = decide("claude-sonnet-5", "gpt", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=HEADROOM, rewrite_model=None)


def test_dated_small_model_variant_still_goes_to_headroom():
    # Claude Code may emit a date-suffixed id (e.g. observed default haiku was
    # claude-haiku-4-5-20251001). Prefix-tolerant match must catch it.
    r = decide("claude-sonnet-5-20260114", "gpt", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=HEADROOM, rewrite_model=None)


def test_main_model_goes_to_bridge_and_is_rewritten_when_gpt_on():
    r = decide("claude-opus-4-8", "gpt", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=BRIDGE, rewrite_model=CODEX)


def test_main_model_goes_to_headroom_when_toggle_off():
    r = decide("claude-opus-4-8", "claude", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=HEADROOM, rewrite_model=None)


def test_unknown_model_defaults_to_toggle_behaviour():
    assert decide("", "claude", SMALL, HEADROOM, BRIDGE, CODEX).upstream == HEADROOM
    assert decide("", "gpt", SMALL, HEADROOM, BRIDGE, CODEX).upstream == BRIDGE
