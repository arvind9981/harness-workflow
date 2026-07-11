"""Toggle state: a single file containing 'gpt' or 'claude'. Default 'claude'.
The active ChatGPT model is a second file holding a single model name."""
from pathlib import Path

VALID = {"gpt", "claude"}
# Last-resort literal only. The good default is resolved dynamically from the
# bridge catalog by `gpt-toggle refresh` and stored in the default-model file.
DEFAULT_MODEL = "gpt-5.5"


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


def read_model(path, default=DEFAULT_MODEL) -> str:
    try:
        value = Path(path).read_text().strip()
    except FileNotFoundError:
        return default
    return value or default


def write_model(path, value: str) -> None:
    value = value.strip()
    if not value:
        raise ValueError("model must be a non-empty string")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(value + "\n")
