#!/usr/bin/env bash

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

contains() {
  if grep -Fq "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

absent() {
  if [ ! -e "$1" ]; then pass "$2"; else fail "$2"; fi
}

test_sources() {
  local skill="$REPO_DIR/workflow/skills/model-team/SKILL.md"
  local agents="$REPO_DIR/codex/agents"
  local retired="open""code"

  absent "$REPO_DIR/$retired" 'retired harness configuration removed'
  absent "$REPO_DIR/tools/$retired" 'retired harness tooling removed'
  contains "$skill" 'Codex is the control plane and only writer' 'Codex owns orchestration and writes'
  contains "$skill" 'genuinely independent question' 'Terra fanout is evidence-driven'
  contains "$skill" 'at most two Claude calls' 'standard Claude usage is bounded'
  contains "$skill" 'at most three Claude calls' 'high-risk Claude usage is bounded'
  contains "$skill" 'mcp__claude-worker__claude' 'skill invokes the Claude MCP worker'
  contains "$skill" 'Never retry a blocked' 'provider limits do not trigger retries'
  contains "$agents/terra-explorer.toml" 'model = "gpt-5.6-terra"' 'Terra explorer pins Terra'
  contains "$agents/terra-explorer.toml" 'sandbox_mode = "read-only"' 'Terra explorer is read-only'
  contains "$agents/sol-reviewer.toml" 'model = "gpt-5.6-sol"' 'Sol reviewer pins Sol'
  contains "$agents/sol-reviewer.toml" 'sandbox_mode = "read-only"' 'Sol reviewer is read-only'
  contains "$REPO_DIR/codex/AGENTS.md" 'Do not rerun an unchanged test' 'AGENTS enforces proportional verification'
}

write_fake_claude() {
  local path="$1"
  cat > "$path" <<'PY'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
role = "critical-review" if any("ROLE: critical-review" in arg for arg in args) else "advisor"
review = role == "critical-review" or any("ROLE: routine-review" in arg for arg in args)
model = "claude-fable-5" if role == "critical-review" else "claude-sonnet-5"
print(json.dumps({"type": "system", "subtype": "init", "session_id": "session-test"}), flush=True)
print(json.dumps({
    "type": "result",
    "result": "REPLY_OK" if review else "START_OK",
    "session_id": "session-test",
    "is_error": False,
    "modelUsage": {model: {
        "inputTokens": 120,
        "outputTokens": 30,
        "cacheReadInputTokens": 40,
        "cacheCreationInputTokens": 10,
        "costUSD": 0.0123,
    }},
}), flush=True)
PY
  chmod +x "$path"
}

test_installer() {
  local temp home codex_home claude_home bin_dir fake second config
  temp="$(mktemp -d "${TMPDIR:-/tmp}/codex-model-team.XXXXXX")"
  home="$temp/home"
  codex_home="$home/.codex"
  claude_home="$home/.claude"
  bin_dir="$home/.local/bin"
  fake="$temp/claude"
  mkdir -p "$codex_home" "$claude_home/skills/model-team" \
    "$claude_home/agents" "$bin_dir"
  write_fake_claude "$fake"

  cat > "$codex_home/config.toml" <<'TOML'
model = "gpt-5.6-sol"

[mcp_servers.personal]
command = "personal-mcp"
TOML
  cat > "$home/.claude.json" <<'JSON'
{"mcpServers":{"personal":{"command":"personal"},"codex-worker":{"command":"legacy"}}}
JSON
  cat > "$claude_home/settings.local.json" <<'JSON'
{"permissions":{"allow":["keep-me","mcp__codex-worker__codex","mcp__codex-worker__codex-reply"]}}
JSON
  printf 'legacy\n' > "$claude_home/skills/model-team/SKILL.md"
  printf 'legacy\n' > "$claude_home/agents/model-team-architect.md"

  HOME="$home" CODEX_DIR="$codex_home" CLAUDE_DIR="$claude_home" \
    CLAUDE_CONFIG_FILE="$home/.claude.json" BIN_DIR="$bin_dir" CLAUDE_BIN="$fake" \
    MODEL_TEAM_STAMP=test bash "$REPO_DIR/tools/model-team/install-model-team.sh" >/dev/null
  second="$(HOME="$home" CODEX_DIR="$codex_home" CLAUDE_DIR="$claude_home" \
    CLAUDE_CONFIG_FILE="$home/.claude.json" BIN_DIR="$bin_dir" CLAUDE_BIN="$fake" \
    MODEL_TEAM_STAMP=test bash "$REPO_DIR/tools/model-team/install-model-team.sh")"

  config="$codex_home/config.toml"
  if python3 - "$config" "$bin_dir" "$fake" <<'PY'
import sys, tomllib
from pathlib import Path
cfg = tomllib.loads(Path(sys.argv[1]).read_text())
assert cfg["mcp_servers"]["personal"]["command"] == "personal-mcp", cfg
worker = cfg["mcp_servers"]["claude-worker"]
expected = [str(Path(sys.argv[2]) / "claude-worker-mcp"), "--claude-bin", sys.argv[3]]
actual = [str(Path(value).resolve()) if index in (0, 2) else value for index, value in enumerate(worker["args"])]
expected = [str(Path(value).resolve()) if index in (0, 2) else value for index, value in enumerate(expected)]
assert actual == expected, (actual, expected)
assert worker["enabled"] is True, worker
PY
  then
    pass 'installer preserves config and registers Claude worker'
  else
    fail 'installer preserves config and registers Claude worker'
  fi
  if python3 - "$home/.claude.json" "$claude_home/settings.local.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
settings = json.load(open(sys.argv[2]))
assert config["mcpServers"] == {"personal": {"command": "personal"}}
assert settings["permissions"]["allow"] == ["keep-me"]
PY
  then
    pass 'installer cleans only legacy model-team ownership'
  else
    fail 'installer cleans only legacy model-team ownership'
  fi
  absent "$claude_home/skills/model-team/SKILL.md" 'legacy Claude model-team skill removed'
  absent "$claude_home/agents/model-team-architect.md" 'legacy Claude architect removed'
  if printf '%s' "$second" | grep -Fq '(0 file(s) updated)'; then
    pass 'second model-team install is idempotent'
  else
    fail 'second model-team install is idempotent'
  fi

  if HOME="$home" CODEX_HOME="$codex_home" CODEX_DIR="$codex_home" \
      CLAUDE_DIR="$claude_home" BIN_DIR="$bin_dir" CLAUDE_BIN="$fake" \
      MODEL_TEAM_DOCTOR_RUNTIME=0 bash "$REPO_DIR/tools/model-team/doctor-model-team.sh" >/dev/null; then
    pass 'doctor accepts isolated installed state'
  else
    fail 'doctor accepts isolated installed state'
  fi
  rm -rf "$temp"
}

test_mcp() {
  local temp fake
  temp="$(mktemp -d "${TMPDIR:-/tmp}/claude-mcp-smoke.XXXXXX")"
  fake="$temp/claude"
  write_fake_claude "$fake"
  if CLAUDE_WORKER_STATE_DIR="$temp/state" \
      python3 "$REPO_DIR/tools/model-team/mcp-smoke.py" \
        --worker "$REPO_DIR/tools/model-team/claude-worker-mcp" \
        --claude-bin "$fake" --invoke | grep -Fq 'claude,claude-reply'; then
    pass 'token-free fake-backed MCP start and review pass'
  else
    fail 'token-free fake-backed MCP start and review pass'
  fi
  rm -rf "$temp"
}

test_sources
test_installer
test_mcp

printf '\nModel-team tests: %s pass, %s fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
