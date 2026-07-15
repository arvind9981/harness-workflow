#!/usr/bin/env bash

# Install the repository-owned OpenCode model-team layer without replacing
# credentials, providers, unrelated plugins, permissions, or personal MCPs.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
OWNED_DIR="$OPENCODE_DIR/harness-workflow"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARKER='harness-workflow: managed'
OLD_MARKER='claude-workflow: managed'
CHANGED=0

backup_path() {
  local path="$1"
  [ -e "$path" ] || return 0
  if [ -d "$path" ]; then
    cp -R "$path" "$path.bak-opencode-$STAMP"
  else
    cp -p "$path" "$path.bak-opencode-$STAMP"
  fi
}

install_managed() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then return 0; fi
  if [ -e "$dest" ] \
    && ! grep -Fq "$MARKER" "$dest" 2>/dev/null \
    && ! grep -Fq "$OLD_MARKER" "$dest" 2>/dev/null \
    && { [[ "$dest" != "$OWNED_DIR/"* ]] || [ ! -f "$OWNED_DIR/.harness-workflow-managed" ]; }; then
    printf 'install-opencode: refusing to replace unmanaged file: %s\n' "$dest" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  backup_path "$dest"
  install -m "$mode" "$src" "$dest"
  CHANGED=$((CHANGED + 1))
}

remove_managed_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  if grep -Fq "$MARKER" "$path" || grep -Fq "$OLD_MARKER" "$path"; then
    backup_path "$path"
    rm -f "$path"
    CHANGED=$((CHANGED + 1))
  fi
}

remove_managed_file "$OPENCODE_DIR/agents/consult.md"
remove_managed_file "$OPENCODE_DIR/agents/general.md"
remove_managed_file "$OPENCODE_DIR/commands/consult.md"

legacy_plugin="$OPENCODE_DIR/plugins/claude-workflow-hooks.js"
if [ -f "$legacy_plugin" ] \
  && grep -Fq 'ClaudeWorkflowHooks' "$legacy_plugin" \
  && grep -Fq 'GRAPHIFY_EVENTS' "$legacy_plugin" \
  && grep -Fq 'headroom-init-opencode' "$legacy_plugin"; then
  backup_path "$legacy_plugin"
  rm -f "$legacy_plugin"
  CHANGED=$((CHANGED + 1))
fi

if [ -d "$OPENCODE_DIR/workflow" ] \
  && [ -f "$OPENCODE_DIR/workflow/.claude-workflow-managed" ]; then
  backup_path "$OPENCODE_DIR/workflow"
  rm -rf "$OPENCODE_DIR/workflow"
  CHANGED=$((CHANGED + 1))
fi

# Remove only unchanged skill copies produced by the previous adapter. OpenCode
# discovers the canonical copies through ~/.claude/skills and ~/.agents/skills.
while IFS= read -r -d '' src; do
  rel="${src#"$REPO_DIR/workflow/skills/"}"
  dest="$OPENCODE_DIR/skills/$rel"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    backup_path "$dest"
    rm -f "$dest"
    CHANGED=$((CHANGED + 1))
  fi
done < <(find "$REPO_DIR/workflow/skills" -type f -print0)

for name in build plan explore scout service memory; do
  install_managed "$REPO_DIR/opencode/agents/$name.md" "$OPENCODE_DIR/agents/$name.md" 0644
done
install_managed "$REPO_DIR/opencode/commands/team.md" "$OPENCODE_DIR/commands/team.md" 0644
install_managed "$REPO_DIR/opencode/plugins/workflow.ts" "$OPENCODE_DIR/plugins/workflow.ts" 0644
install_managed "$REPO_DIR/opencode/skills/model-team/SKILL.md" "$OPENCODE_DIR/skills/model-team/SKILL.md" 0644
install_managed "$REPO_DIR/opencode/instructions/workflow.md" "$OWNED_DIR/instructions.md" 0644
remove_managed_file "$CLAUDE_DIR/agents/opencode-model-team.md"
install_managed "$REPO_DIR/tools/opencode/claude-worker-mcp" "$BIN_DIR/claude-worker-mcp" 0755

mkdir -p "$OWNED_DIR/hooks"
for src in "$REPO_DIR"/workflow/hooks/*.sh; do
  [ -e "$src" ] || continue
  install_managed "$src" "$OWNED_DIR/hooks/$(basename "$src")" 0755
done
marker_file="$OWNED_DIR/.harness-workflow-managed"
if [ ! -f "$marker_file" ]; then
  printf 'harness-workflow: managed opencode helpers\n' > "$marker_file"
  CHANGED=$((CHANGED + 1))
fi

claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
for candidate in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  if [ -z "$claude_bin" ] && [ -x "$candidate" ]; then claude_bin="$candidate"; fi
done
if [ -z "$claude_bin" ]; then
  printf 'install-opencode: Claude Code executable not found\n' >&2
  exit 1
fi
claude_bin="$(cd "$(dirname "$claude_bin")" && pwd)/$(basename "$claude_bin")"
python_bin="$(command -v python3 2>/dev/null || true)"
if [ -z "$python_bin" ]; then
  printf 'install-opencode: Python 3 is required\n' >&2
  exit 1
fi
if ! "$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  printf 'install-opencode: Python 3.10 or newer is required\n' >&2
  exit 1
fi

config_file="$OPENCODE_DIR/opencode.json"
mkdir -p "$OPENCODE_DIR"
[ -f "$config_file" ] || printf '{}\n' > "$config_file"

docker_mcp_available=0
docker_mcp_profiles=""
if command -v docker >/dev/null 2>&1 && docker mcp --help >/dev/null 2>&1; then
  docker_mcp_available=1
  docker_mcp_profiles="$(docker mcp profile list 2>/dev/null || true)"
fi

changed_file="$OPENCODE_DIR/.harness-workflow-config-changed"
rm -f "$changed_file"
BACKUP_SUFFIX=".bak-opencode-$STAMP" \
DOCKER_MCP_AVAILABLE="$docker_mcp_available" \
DOCKER_MCP_PROFILES="$docker_mcp_profiles" \
"$python_bin" - \
  "$config_file" "$REPO_DIR/opencode/opencode.json" "$OWNED_DIR/instructions.md" \
  "$python_bin" "$BIN_DIR/claude-worker-mcp" "$claude_bin" "$changed_file" <<'PY'
import copy
import json
import os
from pathlib import Path
import shutil
import sys

path, baseline_path, instruction, python_bin, worker, claude_bin, changed_file = map(Path, sys.argv[1:])
text = path.read_text(encoding="utf-8")
try:
    config = json.loads(text or "{}")
except json.JSONDecodeError as exc:
    raise SystemExit(f"install-opencode: invalid JSON in {path}: {exc}")
if not isinstance(config, dict):
    raise SystemExit(f"install-opencode: {path} must contain a JSON object")

try:
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"install-opencode: invalid baseline {baseline_path}: {exc}")
if not isinstance(baseline, dict):
    raise SystemExit(f"install-opencode: {baseline_path} must contain a JSON object")

config.setdefault("$schema", baseline["$schema"])
config["model"] = os.environ.get("OPENCODE_BUILD_MODEL", baseline["model"])
config["small_model"] = os.environ.get("OPENCODE_SMALL_MODEL", baseline["small_model"])
headroom_openai = os.environ.get(
    "HEADROOM_OPENAI_BASE_URL",
    baseline["provider"]["openai"]["options"]["baseURL"],
)
headroom_anthropic = os.environ.get("HEADROOM_ANTHROPIC_BASE_URL", "http://127.0.0.1:8787")
mcp_docker_profile = os.environ.get("MCP_DOCKER_PROFILE")

providers = config.setdefault("provider", {})
if not isinstance(providers, dict):
    raise SystemExit("install-opencode: provider must be an object")
openai = providers.setdefault("openai", {})
if not isinstance(openai, dict):
    raise SystemExit("install-opencode: provider.openai must be an object")
options = openai.setdefault("options", {})
if not isinstance(options, dict):
    raise SystemExit("install-opencode: provider.openai.options must be an object")
options["baseURL"] = headroom_openai

instructions = config.setdefault("instructions", [])
if not isinstance(instructions, list):
    raise SystemExit("install-opencode: instructions must be an array")
instruction_text = str(instruction)
if instruction_text not in instructions:
    instructions.append(instruction_text)

mcp = config.setdefault("mcp", {})
if not isinstance(mcp, dict):
    raise SystemExit("install-opencode: mcp must be an object")
headroom = mcp.get("headroom")
if isinstance(headroom, dict) and headroom.get("command") == ["headroom", "mcp", "serve"]:
    del mcp["headroom"]
mcp.setdefault("mempalace", copy.deepcopy(baseline["mcp"]["mempalace"]))

existing_docker = mcp.get("MCP_DOCKER")
if not mcp_docker_profile and isinstance(existing_docker, dict):
    existing_command = existing_docker.get("command")
    if isinstance(existing_command, list) and "--profile" in existing_command:
        profile_index = existing_command.index("--profile") + 1
        if profile_index < len(existing_command):
            candidate = existing_command[profile_index]
            if isinstance(candidate, str) and candidate:
                mcp_docker_profile = candidate

docker_mcp_available = os.environ.get("DOCKER_MCP_AVAILABLE") == "1"
available_profiles = set()
for line in os.environ.get("DOCKER_MCP_PROFILES", "").splitlines():
    fields = line.split()
    if fields and fields[0] not in {"ID", "----"}:
        available_profiles.add(fields[0])

if docker_mcp_available:
    if mcp_docker_profile and mcp_docker_profile not in available_profiles:
        print(
            f"Docker MCP profile unavailable: {mcp_docker_profile}; "
            "using profile-free gateway"
        )
        mcp_docker_profile = None
    docker_command = ["docker", "mcp", "gateway", "run"]
    if mcp_docker_profile:
        docker_command.extend(["--profile", mcp_docker_profile])
    docker_command.extend(["--tools", "mcp-exec"])
    mcp["MCP_DOCKER"] = {
        "type": "local",
        "command": docker_command,
        "enabled": True,
        "timeout": 300000,
    }
elif existing_docker is None:
    print("Docker MCP unavailable; optional gateway skipped")
else:
    print("Docker MCP unavailable; preserving existing MCP_DOCKER configuration")

mcp["claude-worker"] = {
    "type": "local",
    "command": [str(python_bin), str(worker), "--claude-bin", str(claude_bin)],
    "environment": {"ANTHROPIC_BASE_URL": headroom_anthropic},
    "enabled": True,
    "timeout": 900000,
}

tools = config.setdefault("tools", {})
if not isinstance(tools, dict):
    raise SystemExit("install-opencode: tools must be an object")
for name, enabled in baseline["tools"].items():
    tools[name] = enabled

new_text = json.dumps(config, indent=2, ensure_ascii=False) + "\n"
if new_text != text:
    if text:
        shutil.copy2(path, Path(str(path) + os.environ["BACKUP_SUFFIX"]))
    path.write_text(new_text, encoding="utf-8")
    changed_file.write_text("1\n", encoding="utf-8")
PY
if [ -f "$changed_file" ]; then
  CHANGED=$((CHANGED + 1))
  rm -f "$changed_file"
fi

# Retire the one exact stale sentence from the previous unmarked instruction
# file while preserving every other user instruction.
agents_file="$OPENCODE_DIR/AGENTS.md"
if [ -f "$agents_file" ]; then
  changed_file="$OPENCODE_DIR/.harness-workflow-agents-changed"
  rm -f "$changed_file"
  BACKUP_SUFFIX=".bak-opencode-$STAMP" "$python_bin" - "$agents_file" "$changed_file" <<'PY'
import os
from pathlib import Path
import shutil
import sys

path, changed = map(Path, sys.argv[1:])
text = path.read_text(encoding="utf-8")
stale = (
    "- OpenCode loads `~/.config/opencode/plugins/claude-workflow-hooks.js`; that\n"
    "  plugin refreshes an existing graphify graph after file edits.\n"
)
new_text = text.replace(stale, "")
if new_text != text:
    shutil.copy2(path, Path(str(path) + os.environ["BACKUP_SUFFIX"]))
    path.write_text(new_text, encoding="utf-8")
    changed.write_text("1\n", encoding="utf-8")
PY
  if [ -f "$changed_file" ]; then
    CHANGED=$((CHANGED + 1))
    rm -f "$changed_file"
  fi
fi

printf 'OpenCode model-team installed into %s (%s file(s) updated)\n' "$OPENCODE_DIR" "$CHANGED"
