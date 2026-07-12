#!/usr/bin/env bash
# Install the workflow's shared hooks and Codex instructions into Codex.
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

CHANGED=0
# Install src -> dest only when the content differs (backup-first). Skipping identical
# writes keeps file mtimes/hashes stable, so an unchanged redeploy does NOT re-trigger
# Codex's per-hook trust review. A genuine hook change still writes (and rightly needs
# re-trust). cmp -s is portable to BSD/macOS.
install_if_changed() {  # <src> <dest> <mode>
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 0
  fi
  backup "$dest"
  install -m "$mode" "$src" "$dest"
  CHANGED=$((CHANGED + 1))
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'install-codex: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require python3
require sed

mkdir -p "$CODEX_DIR/hooks" "$CODEX_DIR/skills"

for hook in "$REPO_DIR"/workflow/hooks/*.sh; do
  [ -e "$hook" ] || continue
  install_if_changed "$hook" "$CODEX_DIR/hooks/$(basename "$hook")" 0755
done

# Install shared workflow skills without touching unrelated personal skills.
if [ -d "$REPO_DIR/workflow/skills" ]; then
  while IFS= read -r -d '' src; do
    rel="${src#"$REPO_DIR/workflow/skills/"}"
    dest="$CODEX_DIR/skills/$rel"
    mkdir -p "$(dirname "$dest")"
    mode=0644
    [ -x "$src" ] && mode=0755
    install_if_changed "$src" "$dest" "$mode"
  done < <(find "$REPO_DIR/workflow/skills" -type f -print0)
fi

# Older Codex builds do not register ~/.codex/commands. Remove only the
# obsolete command this workflow previously installed; leave user files alone.
rm -f "$CODEX_DIR/commands/consult.md"

# Render __HOME__ first, then write hooks.json only if the result differs.
rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooksjson.XXXXXX")"
sed "s#__HOME__#$HOME#g" "$REPO_DIR/codex/hooks.json" > "$rendered"
install_if_changed "$rendered" "$CODEX_DIR/hooks.json" 0644
rm -f "$rendered"

install_if_changed "$REPO_DIR/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md" 0644
install_if_changed "$REPO_DIR/codex/fast.config.toml" "$CODEX_DIR/fast.config.toml" 0644

config="$CODEX_DIR/config.toml"
touch "$config"

CODEX_BIN_DIR="$BIN_DIR" CODEX_EXISTING_PATH="${PATH:-}" CODEX_BACKUP_SUFFIX=".bak-codex-$STAMP" python3 - "$config" <<'PY'
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
    "OPENAI_BASE_URL": "http://127.0.0.1:8787/v1",
    "PATH": codex_path,
    "TERM": "xterm-256color",
}
desired_top = {
    "openai_base_url": "http://127.0.0.1:8787/v1",
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
inserted_top = False

def emit_desired(target: list[str]) -> None:
    for key, value in desired.items():
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        target.append(f'{key} = "{escaped}"')

def emit_desired_top(target: list[str]) -> None:
    for key, value in desired_top.items():
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        target.append(f'{key} = "{escaped}"')

i = 0
while i < len(lines):
    line = lines[i]
    next_section = section_of(line)
    if next_section is not None:
      if section == "" and not inserted_top:
          emit_desired_top(out)
          inserted_top = True
      if section == "shell_environment_policy.set" and not inserted:
          emit_desired(out)
          inserted = True
      section = next_section
      seen_policy = seen_policy or section == "shell_environment_policy"
      seen_set = seen_set or section == "shell_environment_policy.set"
      out.append(line)
      i += 1
      continue

    if section == "":
        stripped = line.lstrip()
        if any(stripped.startswith(f"{key} ") or stripped.startswith(f"{key}=") for key in desired_top):
            i += 1
            continue

    if section == "shell_environment_policy.set":
        stripped = line.lstrip()
        if any(stripped.startswith(f"{key} ") or stripped.startswith(f"{key}=") for key in desired):
            i += 1
            continue

    out.append(line)
    i += 1

if section == "" and not inserted_top:
    emit_desired_top(out)
    inserted_top = True

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

new_text = "\n".join(out).rstrip() + "\n"
if new_text != text:
    suffix = os.environ.get("CODEX_BACKUP_SUFFIX", "")
    if suffix and text:
        Path(str(path) + suffix).write_text(text, encoding="utf-8")
    path.write_text(new_text, encoding="utf-8")
PY

printf 'Codex workflow installed into %s (%s hook/instruction file(s) updated)\n' "$CODEX_DIR" "$CHANGED"
