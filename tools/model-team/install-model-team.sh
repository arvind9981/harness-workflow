#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/codex/lib.sh
# shellcheck disable=SC1091
. "$REPO_DIR/tools/codex/lib.sh"

CODEX_DIR="${CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_FILE="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
CLAUDE_SETTINGS_LOCAL_FILE="${CLAUDE_SETTINGS_LOCAL_FILE:-$CLAUDE_DIR/settings.local.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
STAMP="${MODEL_TEAM_STAMP:-$(date +%Y%m%d-%H%M%S)}"
CHANGED=0

backup_if_present() {
  [ -e "$1" ] && cp -p "$1" "$1.bak-model-team-$STAMP"
  return 0
}

install_if_changed() {
  local src="$1" dest="$2" mode="$3"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 0
  fi
  backup_if_present "$dest"
  install -m "$mode" "$src" "$dest"
  CHANGED=$((CHANGED + 1))
}

remove_legacy() {
  [ -e "$1" ] || return 0
  backup_if_present "$1"
  rm -f "$1"
  CHANGED=$((CHANGED + 1))
}

python_bin="$(codex_python_resolve || command -v python3 || true)"
if [ -z "$python_bin" ]; then
  printf 'install-model-team: Python 3.11+ is required\n' >&2
  exit 1
fi

claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"

mkdir -p "$CODEX_DIR/skills/model-team" "$CODEX_DIR/agents" "$BIN_DIR"
install_if_changed "$REPO_DIR/workflow/skills/model-team/SKILL.md" \
  "$CODEX_DIR/skills/model-team/SKILL.md" 0644
install_if_changed "$REPO_DIR/codex/agents/terra-explorer.toml" \
  "$CODEX_DIR/agents/terra-explorer.toml" 0644
install_if_changed "$REPO_DIR/codex/agents/sol-reviewer.toml" \
  "$CODEX_DIR/agents/sol-reviewer.toml" 0644
install_if_changed "$REPO_DIR/tools/model-team/claude-worker-mcp" \
  "$BIN_DIR/claude-worker-mcp" 0755
install_if_changed "$REPO_DIR/tools/model-team/claude-worker-watch" \
  "$BIN_DIR/claude-worker-watch" 0755

# Remove only names previously owned by this repository. Backups preserve any
# local divergence while preventing the obsolete Claude-led topology from loading.
remove_legacy "$CLAUDE_DIR/skills/model-team/SKILL.md"
remove_legacy "$CLAUDE_DIR/agents/model-team-architect.md"
remove_legacy "$BIN_DIR/codex-worker-mcp"
remove_legacy "$BIN_DIR/model-team-watch"

config="$CODEX_DIR/config.toml"
mkdir -p "$CODEX_DIR"
[ -e "$config" ] || (umask 077 && : > "$config")
before="$(mktemp "${TMPDIR:-/tmp}/model-team-config.XXXXXX")"
cp -p "$config" "$before"

MODEL_TEAM_BACKUP_SUFFIX=".bak-model-team-$STAMP" "$python_bin" - \
  "$config" "$python_bin" "$BIN_DIR/claude-worker-mcp" "$claude_bin" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import tomllib

path = Path(sys.argv[1])
python_bin, wrapper, claude_bin = sys.argv[2:5]
text = path.read_text(encoding="utf-8")
try:
    tomllib.loads(text)
except tomllib.TOMLDecodeError as exc:
    raise SystemExit(f"install-model-team: invalid TOML in {path}: {exc}")

args = [wrapper]
if claude_bin:
    args.extend(["--claude-bin", claude_bin])

header = "[mcp_servers.claude-worker]"
lines = text.splitlines()
out = []
inside = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if stripped == header:
            inside = True
            continue
        if inside:
            inside = False
    if not inside:
        out.append(line)

while out and not out[-1].strip():
    out.pop()
if out:
    out.append("")
out.extend([
    header,
    f"command = {json.dumps(python_bin)}",
    f"args = {json.dumps(args)}",
    "enabled = true",
    "startup_timeout_sec = 10",
    "tool_timeout_sec = 1900",
])
new_text = "\n".join(out) + "\n"
tomllib.loads(new_text)
if new_text == text:
    raise SystemExit(0)

suffix = os.environ.get("MODEL_TEAM_BACKUP_SUFFIX", "")
if suffix and text:
    shutil.copy2(path, Path(str(path) + suffix))
fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

if ! cmp -s "$before" "$config"; then CHANGED=$((CHANGED + 1)); fi
rm -f "$before"

# Clean only the legacy Claude-side MCP and permission entries. Preserve every
# unrelated server, permission, plugin, credential, and preference.
for target in "$CLAUDE_CONFIG_FILE" "$CLAUDE_SETTINGS_LOCAL_FILE"; do
  [ -e "$target" ] || continue
  before="$(mktemp "${TMPDIR:-/tmp}/model-team-legacy.XXXXXX")"
  cp -p "$target" "$before"
  MODEL_TEAM_BACKUP_SUFFIX=".bak-model-team-$STAMP" "$python_bin" - \
    "$target" "$CLAUDE_CONFIG_FILE" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
text = path.read_text(encoding="utf-8")
try:
    data = json.loads(text or "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"install-model-team: invalid JSON in {path}: {exc}")
if not isinstance(data, dict):
    raise SystemExit(f"install-model-team: {path} must contain a JSON object")

if path == config_path:
    servers = data.get("mcpServers")
    if isinstance(servers, dict):
        servers.pop("codex-worker", None)
else:
    permissions = data.get("permissions")
    if isinstance(permissions, dict):
        allow = permissions.get("allow")
        if isinstance(allow, list):
            obsolete = {"mcp__codex-worker__codex", "mcp__codex-worker__codex-reply"}
            permissions["allow"] = [item for item in allow if item not in obsolete]

new_text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
if new_text == text:
    raise SystemExit(0)
suffix = os.environ.get("MODEL_TEAM_BACKUP_SUFFIX", "")
if suffix and text:
    shutil.copy2(path, Path(str(path) + suffix))
fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    os.chmod(temporary, path.stat().st_mode & 0o777)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
  if ! cmp -s "$before" "$target"; then CHANGED=$((CHANGED + 1)); fi
  rm -f "$before"
done

if [ -z "$claude_bin" ]; then
  printf 'install-model-team: Claude CLI not found; worker registered for later PATH discovery\n' >&2
fi

printf 'Codex-led model-team installed into %s (%s file(s) updated)\n' "$CODEX_DIR" "$CHANGED"
