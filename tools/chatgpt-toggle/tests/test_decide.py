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


# --- per-model routing: mix Claude and GPT in one session -------------------

def test_explicit_gpt_model_goes_to_bridge_unchanged_when_toggle_off():
    # The core fix: request a gpt-* model with the toggle OFF and it still
    # reaches the bridge, with the exact id preserved (no rewrite).
    r = decide("gpt-5.6-terra", "claude", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=BRIDGE, rewrite_model=None)


def test_explicit_gpt_model_passes_through_unchanged_when_toggle_on():
    # Even on the GPT path, an explicit gpt-* id is NOT rewritten to the resolved
    # codex model — the picked model is what serves.
    r = decide("gpt-5.6-terra", "gpt", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=BRIDGE, rewrite_model=None)


def test_claude_model_stays_on_claude_when_toggle_off():
    # The other half of mixing: a claude-* model with toggle OFF stays on Claude.
    r = decide("claude-opus-4-8", "claude", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=HEADROOM, rewrite_model=None)


def test_small_model_stays_on_claude_regardless_of_gpt_prefix_rule():
    # Guard ordering: the small-fast clause wins even though it is a claude id;
    # the gpt- clause must not accidentally capture non-gpt models.
    r = decide("claude-sonnet-5", "claude", SMALL, HEADROOM, BRIDGE, CODEX)
    assert r == Route(upstream=HEADROOM, rewrite_model=None)
