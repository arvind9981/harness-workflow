#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LIVE="${OPENCODE_DOCTOR_LIVE:-1}"
PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf 'WARN  %s\n' "$1"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

check_file() {
  local src="$1" dest="$2"
  if [ ! -f "$dest" ]; then
    fail "missing: $dest"
  elif cmp -s "$src" "$dest"; then
    pass "$(basename "$dest") matches repo source"
  else
    fail "$dest differs from repo source"
  fi
}

if command -v opencode >/dev/null 2>&1; then
  pass "OpenCode CLI available ($(opencode --version 2>/dev/null || printf unknown))"
else
  warn 'OpenCode CLI unavailable'
fi
if command -v claude >/dev/null 2>&1; then
  pass "Claude Code available ($(claude --version 2>/dev/null || printf unknown))"
else
  fail 'Claude Code CLI unavailable'
fi

for name in build plan explore scout service memory; do
  check_file "$REPO_DIR/opencode/agents/$name.md" "$OPENCODE_DIR/agents/$name.md"
done
check_file "$REPO_DIR/opencode/commands/team.md" "$OPENCODE_DIR/commands/team.md"
check_file "$REPO_DIR/opencode/plugins/workflow.ts" "$OPENCODE_DIR/plugins/workflow.ts"
check_file "$REPO_DIR/opencode/skills/model-team/SKILL.md" "$OPENCODE_DIR/skills/model-team/SKILL.md"
check_file "$REPO_DIR/opencode/instructions/workflow.md" "$OPENCODE_DIR/harness-workflow/instructions.md"
check_file "$REPO_DIR/tools/opencode/claude-worker-mcp" "$BIN_DIR/claude-worker-mcp"

for path in \
  "$OPENCODE_DIR/agents/consult.md" \
  "$OPENCODE_DIR/agents/general.md" \
  "$OPENCODE_DIR/commands/consult.md" \
  "$OPENCODE_DIR/plugins/claude-workflow-hooks.js" \
  "$OPENCODE_DIR/workflow"; do
  if [ -e "$path" ]; then fail "legacy path remains: $path"; else pass "legacy path absent: $path"; fi
done

config_file="$OPENCODE_DIR/opencode.json"
headroom_openai="${HEADROOM_OPENAI_BASE_URL:-http://127.0.0.1:8787/v1}"
headroom_anthropic="${HEADROOM_ANTHROPIC_BASE_URL:-http://127.0.0.1:8787}"
docker_mcp_available=0
if command -v docker >/dev/null 2>&1 && docker mcp --help >/dev/null 2>&1; then
  docker_mcp_available=1
fi
if [ ! -f "$config_file" ]; then
  fail "missing: $config_file"
elif jq -e \
  --arg headroom_openai "$headroom_openai" \
  --arg headroom_anthropic "$headroom_anthropic" \
  '
  (.mcp.MCP_DOCKER.command // null) as $docker_command |
  .model == "openai/gpt-5.6-sol" and
  .small_model == "openai/gpt-5.6-luna" and
  .provider.openai.options.baseURL == $headroom_openai and
  ($docker_command == null or (
    $docker_command == ["docker", "mcp", "gateway", "run", "--tools", "mcp-exec"] or
    (
      ($docker_command | length) == 8 and
      $docker_command[0:4] == ["docker", "mcp", "gateway", "run"] and
      $docker_command[4] == "--profile" and
      ($docker_command[5] | type) == "string" and
      ($docker_command[5] | length) > 0 and
      $docker_command[6:8] == ["--tools", "mcp-exec"]
    )
  )) and
  .mcp["claude-worker"].command[0] != null and
  .mcp["claude-worker"].environment.ANTHROPIC_BASE_URL == $headroom_anthropic and
  .tools["claude-worker_*"] == false and
  .tools["mempalace_*"] == false and
  .tools["MCP_DOCKER_*"] == false and
  ([.instructions[] | select(endswith("/harness-workflow/instructions.md"))] | length) == 1
' "$config_file" >/dev/null; then
  pass 'OpenCode model, MCP isolation, and instruction config are reconciled'
else
  fail 'OpenCode model-team config is incomplete'
fi

if [ "$docker_mcp_available" = 0 ]; then
  if jq -e '.mcp.MCP_DOCKER != null' "$config_file" >/dev/null 2>&1; then
    warn 'Docker MCP capability unavailable; preserving the existing optional entry'
  else
    pass 'Docker MCP is optional and remains unconfigured'
  fi
elif jq -e '.mcp.MCP_DOCKER != null' "$config_file" >/dev/null 2>&1; then
  pass 'Docker MCP capability detected and configured'
else
  warn 'Docker MCP capability is available but not configured; re-run init.sh'
fi

if jq -e '.mcp.headroom.command == ["headroom", "mcp", "serve"]' "$config_file" >/dev/null 2>&1; then
  fail 'redundant Headroom MCP entry remains'
else
  pass 'Headroom is not exposed as an OpenCode MCP'
fi

claude_bin="$(jq -r '.mcp["claude-worker"].command[-1] // empty' "$config_file" 2>/dev/null)"
if [ -x "$BIN_DIR/claude-worker-mcp" ] && [ -x "$claude_bin" ]; then
  if python3 "$REPO_DIR/tools/opencode/mcp-smoke.py" \
    --worker "$BIN_DIR/claude-worker-mcp" --claude-bin "$claude_bin" >/dev/null; then
    pass 'Claude worker MCP exposes only claude and claude-reply'
  else
    fail 'Claude worker MCP handshake failed'
  fi
else
  fail 'Claude worker MCP command is not executable'
fi

if command -v bun >/dev/null 2>&1; then
  build_out="${TMPDIR:-/tmp}/opencode-workflow-plugin-$$.js"
  if bun build "$OPENCODE_DIR/plugins/workflow.ts" --target=bun --outfile="$build_out" >/dev/null 2>&1; then
    pass 'OpenCode lifecycle plugin compiles'
  else
    fail 'OpenCode lifecycle plugin does not compile'
  fi
  rm -f "$build_out"
elif command -v opencode >/dev/null 2>&1 && opencode debug config >/dev/null 2>&1; then
  pass 'OpenCode loads the lifecycle plugin with its bundled runtime'
else
  warn 'No OpenCode/Bun runtime available for plugin validation'
fi

if [ "$LIVE" = 1 ]; then
  if command -v mempalace-mcp >/dev/null 2>&1; then pass 'Mempalace MCP executable available'; else warn 'Mempalace MCP unavailable'; fi
  if curl -fsS --max-time 2 http://127.0.0.1:8787/health >/dev/null 2>&1; then
    pass 'Headroom proxy healthy'
  else
    warn 'Headroom proxy health endpoint unavailable'
  fi
  if command -v opencode >/dev/null 2>&1 && opencode debug config >/dev/null 2>&1; then
    pass 'OpenCode resolves the merged configuration'
  else
    fail 'OpenCode cannot resolve the merged configuration'
  fi
  if ! jq -e '.mcp.MCP_DOCKER != null' "$config_file" >/dev/null 2>&1; then
    warn 'Docker MCP gateway is not configured (optional)'
  else
    mcp_list="$(opencode mcp list 2>/dev/null || true)"
    if printf '%s\n' "$mcp_list" | grep -Eq 'MCP_DOCKER.*connected'; then
      pass 'Docker MCP gateway connected through OpenCode'
    else
      warn 'Docker MCP gateway is configured but not connected'
    fi
  fi
fi

printf '\nOpenCode workflow doctor: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
