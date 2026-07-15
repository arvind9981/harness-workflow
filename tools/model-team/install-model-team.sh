#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/codex/lib.sh
# shellcheck disable=SC1091
. "$REPO_DIR/tools/codex/lib.sh"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_FILE="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
CLAUDE_SETTINGS_LOCAL_FILE="${CLAUDE_SETTINGS_LOCAL_FILE:-$CLAUDE_DIR/settings.local.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
STAMP="${MODEL_TEAM_STAMP:-$(date +%Y%m%d-%H%M%S)}"
CHANGED=0

backup_if_present() {
  local path="$1"
  [ -e "$path" ] || return 0
  cp -p "$path" "$path.bak-model-team-$STAMP"
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

codex_bin="$(codex_resolve_bin || true)"
if [ -z "$codex_bin" ]; then
  printf 'install-model-team: no Codex executable found on PATH, in CODEX_BIN, or in a supported app bundle\n' >&2
  exit 1
fi

install_if_changed "$REPO_DIR/claude/skills/model-team/SKILL.md" \
  "$CLAUDE_DIR/skills/model-team/SKILL.md" 0644
install_if_changed "$REPO_DIR/claude/agents/model-team-architect.md" \
  "$CLAUDE_DIR/agents/model-team-architect.md" 0644
install_if_changed "$REPO_DIR/workflow/skills/jira-live/SKILL.md" \
  "$CLAUDE_DIR/skills/jira-live/SKILL.md" 0644
install_if_changed "$REPO_DIR/tools/model-team/model-team-watch" \
  "$BIN_DIR/model-team-watch" 0755
install_if_changed "$REPO_DIR/tools/model-team/codex-worker-mcp" \
  "$BIN_DIR/codex-worker-mcp" 0755

mkdir -p "$(dirname "$CLAUDE_CONFIG_FILE")"
if [ ! -e "$CLAUDE_CONFIG_FILE" ]; then
  (umask 077 && printf '{}\n' > "$CLAUDE_CONFIG_FILE")
fi

python_bin="$(codex_python_resolve || true)"
if [ -z "$python_bin" ]; then
  printf 'install-model-team: Python 3.11+ with the standard TOML parser is required\n' >&2
  exit 1
fi

MODEL_TEAM_BACKUP_SUFFIX=".bak-model-team-$STAMP" "$python_bin" - \
  "$CLAUDE_CONFIG_FILE" "$python_bin" "$BIN_DIR/codex-worker-mcp" "$codex_bin" <<'PY'
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
python_bin = sys.argv[2]
worker_wrapper = sys.argv[3]
codex_bin = sys.argv[4]
text = path.read_text(encoding="utf-8")
try:
    config = json.loads(text or "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"install-model-team: invalid JSON in {path}: {exc}")
if not isinstance(config, dict):
    raise SystemExit(f"install-model-team: {path} must contain a JSON object")

servers = config.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    raise SystemExit(f"install-model-team: {path}.mcpServers must be a JSON object")
desired = {
    "command": python_bin,
    "args": [worker_wrapper, "--codex-bin", codex_bin],
}
changed = False
if servers.get("codex-worker") != desired:
    servers["codex-worker"] = desired
    changed = True

docker = servers.get("MCP_DOCKER")
if isinstance(docker, dict) and docker.get("command") == "docker":
    args = docker.get("args")
    if isinstance(args, list) and args[:3] == ["mcp", "gateway", "run"]:
        normalized = []
        index = 0
        while index < len(args):
            arg = args[index]
            if arg == "--tools":
                index += 2
                continue
            if isinstance(arg, str) and arg.startswith("--tools="):
                index += 1
                continue
            normalized.append(arg)
            index += 1
        normalized.extend(["--tools", "mcp-exec"])
        if normalized != args:
            docker["args"] = normalized
            changed = True

if not changed:
    raise SystemExit(0)
new_text = json.dumps(config, indent=2, ensure_ascii=False) + "\n"
suffix = os.environ.get("MODEL_TEAM_BACKUP_SUFFIX", "")
if suffix and text:
    shutil.copy2(path, Path(str(path) + suffix))

mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    os.chmod(tmp_name, mode)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY

mkdir -p "$(dirname "$CLAUDE_SETTINGS_LOCAL_FILE")"
if [ ! -e "$CLAUDE_SETTINGS_LOCAL_FILE" ]; then
  (umask 077 && printf '{}\n' > "$CLAUDE_SETTINGS_LOCAL_FILE")
fi

MODEL_TEAM_BACKUP_SUFFIX=".bak-model-team-$STAMP" "$python_bin" - \
  "$CLAUDE_SETTINGS_LOCAL_FILE" <<'PY'
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
try:
    settings = json.loads(text or "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"install-model-team: invalid JSON in {path}: {exc}")
if not isinstance(settings, dict):
    raise SystemExit(f"install-model-team: {path} must contain a JSON object")

permissions = settings.setdefault("permissions", {})
if not isinstance(permissions, dict):
    raise SystemExit(f"install-model-team: {path}.permissions must be a JSON object")
allow = permissions.setdefault("allow", [])
if not isinstance(allow, list) or not all(isinstance(item, str) for item in allow):
    raise SystemExit(f"install-model-team: {path}.permissions.allow must be a string array")

required = ["mcp__codex-worker__codex", "mcp__codex-worker__codex-reply"]
missing = [item for item in required if item not in allow]
if not missing:
    raise SystemExit(0)
allow.extend(missing)

new_text = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
suffix = os.environ.get("MODEL_TEAM_BACKUP_SUFFIX", "")
if suffix and text:
    shutil.copy2(path, Path(str(path) + suffix))

mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    os.chmod(tmp_name, mode)
    os.replace(tmp_name, path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY

printf 'Model-team installed into %s using %s (%s managed file(s) updated)\n' \
  "$CLAUDE_DIR" "$codex_bin" "$CHANGED"
