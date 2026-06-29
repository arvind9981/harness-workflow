#!/usr/bin/env bash
# Install the Claude workflow's local hooks/instructions into Codex.
#
# This intentionally avoids plugin marketplace setup. Codex owns its plugin
# catalog in ~/.codex/config.toml; this script only wires the workflow pieces
# that this repo maintains: hooks, AGENTS.md, and shell env required by hooks.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
STAMP="$(date +%Y%m%d-%H%M%S)"

backup() {
  [ -e "$1" ] && cp -p "$1" "$1.bak-codex-$STAMP"
  return 0
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'install-codex: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require python3
require sed

mkdir -p "$CODEX_DIR/hooks"

for hook in "$REPO_DIR"/claude/hooks/*.sh; do
  [ -e "$hook" ] || continue
  dest="$CODEX_DIR/hooks/$(basename "$hook")"
  backup "$dest"
  install -m 0755 "$hook" "$dest"
done

existing_hooks=""
if [ -n "${CODEX_PRESERVE_HOOKS_FROM:-}" ] && [ -f "$CODEX_PRESERVE_HOOKS_FROM" ]; then
  existing_hooks="$(mktemp)"
  cp "$CODEX_PRESERVE_HOOKS_FROM" "$existing_hooks"
elif [ -f "$CODEX_DIR/hooks.json" ]; then
  existing_hooks="$(mktemp)"
  cp "$CODEX_DIR/hooks.json" "$existing_hooks"
fi
backup "$CODEX_DIR/hooks.json"
sed "s#__HOME__#$HOME#g" "$REPO_DIR/codex/hooks.json" > "$CODEX_DIR/hooks.json"

if [ -n "$existing_hooks" ]; then
  python3 - "$CODEX_DIR/hooks.json" "$existing_hooks" <<'PY'
import json
import sys
from pathlib import Path

target_path = Path(sys.argv[1])
existing_path = Path(sys.argv[2])

try:
    target = json.loads(target_path.read_text(encoding="utf-8"))
    existing = json.loads(existing_path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)

def managed(entry):
    for hook in entry.get("hooks", []):
        if "supacode-managed-hook" in str(hook.get("command", "")):
            return True
    return False

target_hooks = target.setdefault("hooks", {})
for event, entries in existing.get("hooks", {}).items():
    if not isinstance(entries, list):
        continue
    keep = [entry for entry in entries if isinstance(entry, dict) and managed(entry)]
    if keep:
        target_hooks.setdefault(event, []).extend(keep)

target_path.write_text(json.dumps(target, indent=2) + "\n", encoding="utf-8")
PY
  rm -f "$existing_hooks"
fi

backup "$CODEX_DIR/AGENTS.md"
install -m 0644 "$REPO_DIR/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md"

config="$CODEX_DIR/config.toml"
touch "$config"
backup "$config"

CODEX_BIN_DIR="$BIN_DIR" CODEX_EXISTING_PATH="${PATH:-}" python3 - "$config" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

bin_dir = os.environ["CODEX_BIN_DIR"]
existing = os.environ.get("CODEX_EXISTING_PATH", "")
parts = [bin_dir] + [p for p in existing.split(":") if p and p != bin_dir]
codex_path = ":".join(parts)

desired = {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
    "PATH": codex_path,
}

def section_of(line: str):
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        return s.strip("[]")
    return None

out: list[str] = []
section = ""
seen_policy = False
seen_set = False
inserted = False

def emit_desired(target: list[str]) -> None:
    for key, value in desired.items():
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        target.append(f'{key} = "{escaped}"')

i = 0
while i < len(lines):
    line = lines[i]
    next_section = section_of(line)
    if next_section is not None:
      if section == "shell_environment_policy.set" and not inserted:
          emit_desired(out)
          inserted = True
      section = next_section
      seen_policy = seen_policy or section == "shell_environment_policy"
      seen_set = seen_set or section == "shell_environment_policy.set"
      out.append(line)
      i += 1
      continue

    if section == "shell_environment_policy.set":
        stripped = line.lstrip()
        if any(stripped.startswith(f"{key} ") or stripped.startswith(f"{key}=") for key in desired):
            i += 1
            continue

    out.append(line)
    i += 1

if section == "shell_environment_policy.set" and not inserted:
    emit_desired(out)
    inserted = True

if not seen_policy:
    if out and out[-1].strip():
        out.append("")
    out.extend(["[shell_environment_policy]", 'inherit = "core"'])

if not seen_set:
    if out and out[-1].strip():
        out.append("")
    out.append("[shell_environment_policy.set]")
    emit_desired(out)

path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
PY

printf 'Codex workflow installed into %s\n' "$CODEX_DIR"
