#!/usr/bin/env bash

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/codex/lib.sh
# shellcheck disable=SC1091
. "$REPO_DIR/tools/codex/lib.sh"

CODEX_DIR="${CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
RUNTIME="${MODEL_TEAM_DOCTOR_RUNTIME:-1}"
PASS=0
WARN=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
warn() { WARN=$((WARN + 1)); printf 'WARN %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

python_bin="$(codex_python_resolve || command -v python3 || true)"
config="$CODEX_DIR/config.toml"
wrapper="$BIN_DIR/claude-worker-mcp"
watcher="$BIN_DIR/claude-worker-watch"

if [ -f "$CODEX_DIR/skills/model-team/SKILL.md" ]; then
  pass 'Codex model-team skill installed'
else
  fail 'Codex model-team skill missing'
fi
for agent in terra-explorer sol-reviewer; do
  if [ -f "$CODEX_DIR/agents/$agent.toml" ]; then
    pass "$agent agent installed"
  else
    fail "$agent agent missing"
  fi
done
if [ -x "$wrapper" ]; then pass 'Claude MCP worker installed'; else fail 'Claude MCP worker missing'; fi
if [ -x "$watcher" ]; then pass 'Claude worker watcher installed'; else fail 'Claude worker watcher missing'; fi

claude_bin="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ -n "$python_bin" ] && [ -f "$config" ]; then
  parsed="$($python_bin - "$config" <<'PY' 2>/dev/null || true
import json, sys, tomllib
with open(sys.argv[1], "rb") as handle:
    worker = tomllib.load(handle).get("mcp_servers", {}).get("claude-worker", {})
print(json.dumps(worker))
PY
)"
else
  parsed=""
fi

if [ -n "$parsed" ] && "$python_bin" - "$parsed" "$python_bin" "$wrapper" <<'PY'
import json, sys
worker = json.loads(sys.argv[1])
assert worker.get("command") == sys.argv[2]
args = worker.get("args")
assert isinstance(args, list) and args and args[0] == sys.argv[3]
assert worker.get("enabled") is True
assert worker.get("tool_timeout_sec", 0) >= 1800
PY
then
  pass 'Codex claude-worker MCP registration is current'
  configured_claude="$($python_bin - "$parsed" <<'PY'
import json, sys
args = json.loads(sys.argv[1]).get("args", [])
print(args[args.index("--claude-bin") + 1] if "--claude-bin" in args else "")
PY
)"
  [ -n "$configured_claude" ] && claude_bin="$configured_claude"
else
  fail 'Codex claude-worker MCP registration is missing or drifted'
fi

if [ -n "$claude_bin" ] && [ -x "$claude_bin" ]; then
  pass "Claude CLI available at $claude_bin"
  if [ -n "$python_bin" ] && "$python_bin" "$REPO_DIR/tools/model-team/mcp-smoke.py" \
      --worker "$wrapper" --claude-bin "$claude_bin" 2>/dev/null | grep -Fq 'claude,claude-reply'; then
    pass 'Claude MCP exposes claude and claude-reply'
  else
    fail 'Claude MCP handshake failed'
  fi
else
  warn 'Claude CLI unavailable; Sonnet/Fable workers remain dormant'
fi

if [ "$RUNTIME" = 1 ]; then
  health="$(curl -fsS --max-time 3 "${HEADROOM_HEALTH_URL:-http://127.0.0.1:8787/health}" 2>/dev/null || true)"
  if printf '%s\n' "$health" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"'; then
    pass 'Headroom proxy is healthy for Claude worker traffic'
  else
    warn 'Headroom proxy is not healthy; Claude worker routing needs attention'
  fi
fi

printf '\nModel-team doctor: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
