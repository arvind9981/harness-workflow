from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from toggle import read_state, write_state


def test_default_is_claude_when_missing(tmp_path):
    assert read_state(tmp_path / "nope") == "claude"


def test_write_then_read_roundtrip(tmp_path):
    p = tmp_path / "state"
    write_state(p, "gpt")
    assert read_state(p) == "gpt"
    write_state(p, "claude")
    assert read_state(p) == "claude"


def test_unknown_content_falls_back_to_claude(tmp_path):
    p = tmp_path / "state"
    p.write_text("garbage")
    assert read_state(p) == "claude"
