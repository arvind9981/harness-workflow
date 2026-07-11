"""Toggle state: a single file containing 'gpt' or 'claude'. Default 'claude'."""
from pathlib import Path

VALID = {"gpt", "claude"}


def read_state(path) -> str:
    try:
        value = Path(path).read_text().strip()
    except FileNotFoundError:
        return "claude"
    return value if value in VALID else "claude"


def write_state(path, value: str) -> None:
    if value not in VALID:
        raise ValueError(f"state must be one of {VALID}, got {value!r}")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(value + "\n")
