#!/usr/bin/env bash

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/codex/lib.sh
. "$REPO_DIR/tools/codex/lib.sh"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_FILE="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
CLAUDE_SETTINGS_LOCAL_FILE="${CLAUDE_SETTINGS_LOCAL_FILE:-$CLAUDE_DIR/settings.local.json}"
CODEX_CONFIG_FILE="${CODEX_CONFIG_FILE:-${CODEX_HOME:-$HOME/.codex}/config.toml}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
WORKER_WRAPPER="${MODEL_TEAM_WORKER_WRAPPER:-$(command -v codex-worker-mcp 2>/dev/null || true)}"
[ -n "$WORKER_WRAPPER" ] || WORKER_WRAPPER="$BIN_DIR/codex-worker-mcp"
PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf 'WARN %s\n' "$1"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

codex_bin="$(codex_resolve_bin || true)"
python_bin="$(codex_python_resolve || true)"

if [ -f "$CLAUDE_DIR/skills/model-team/SKILL.md" ]; then
  pass 'model-team skill installed'
else
  fail 'model-team skill missing'
fi
if [ -f "$CLAUDE_DIR/agents/model-team-architect.md" ] \
  && grep -Fq 'model: fable' "$CLAUDE_DIR/agents/model-team-architect.md" \
  && grep -Fq 'tools: Read, Grep, Glob' "$CLAUDE_DIR/agents/model-team-architect.md"; then
  pass 'Fable architect agent installed'
else
  fail 'Fable architect agent missing or not read-only'
fi
if [ -f "$CLAUDE_DIR/skills/jira-live/SKILL.md" ]; then
  pass 'jira-live skill installed'
else
  fail 'jira-live skill missing'
fi

if command -v model-team-watch >/dev/null 2>&1; then
  pass 'model-team-watch is installed'
else
  fail 'model-team-watch is missing from PATH'
fi
if [ -x "$WORKER_WRAPPER" ]; then
  pass 'instrumented Codex MCP wrapper is installed'
else
  fail 'instrumented Codex MCP wrapper is missing'
fi

if [ -n "$codex_bin" ] && [ -n "$python_bin" ] && [ -f "$CLAUDE_CONFIG_FILE" ] \
  && "$python_bin" - "$CLAUDE_CONFIG_FILE" "$python_bin" \
    "$WORKER_WRAPPER" "$codex_bin" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
worker = config.get("mcpServers", {}).get("codex-worker", {})
assert worker.get("command") == sys.argv[2]
assert worker.get("args") == [sys.argv[3], "--codex-bin", sys.argv[4]]
PY
then
  pass 'codex-worker MCP registration uses the isolated wrapper'
else
  fail 'codex-worker MCP registration is missing or drifted'
fi

worker_home=""
if [ -n "$codex_bin" ] && [ -n "$python_bin" ] && [ -x "$WORKER_WRAPPER" ]; then
  worker_home="$(MODEL_TEAM_PRIMARY_CODEX_HOME="${CODEX_HOME:-$(dirname "$CODEX_CONFIG_FILE")}" \
    "$python_bin" "$WORKER_WRAPPER" --codex-bin "$codex_bin" --prepare-only 2>/dev/null || true)"
fi
if [ -n "$worker_home" ] && [ -f "$worker_home/config.toml" ] \
  && CODEX_HOME="$worker_home" CODEX_SQLITE_HOME="$worker_home" \
    "$codex_bin" mcp list 2>/dev/null | grep -Fq 'No MCP servers configured'; then
  pass 'Codex worker has zero inner MCP servers'
else
  fail 'Codex worker inherited one or more inner MCP servers'
fi
case "$worker_home" in
  */model-team/codex-homes/*) rm -rf "$worker_home" ;;
esac

worker_model=""
if [ -n "$python_bin" ] && [ -f "$CODEX_CONFIG_FILE" ]; then
  worker_model="$($python_bin - "$CODEX_CONFIG_FILE" <<'PY' 2>/dev/null || true
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle).get("model", ""))
PY
)"
fi
if [ "$worker_model" = 'gpt-5.6-sol' ]; then
  pass 'Codex worker default model is gpt-5.6-sol'
elif [ -n "$worker_model" ]; then
  warn "Codex worker default model is $worker_model, not gpt-5.6-sol"
else
  warn 'Codex worker default model is machine-managed or unavailable'
fi

if [ -n "$python_bin" ] && [ -f "$CLAUDE_SETTINGS_LOCAL_FILE" ] \
  && "$python_bin" - "$CLAUDE_SETTINGS_LOCAL_FILE" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1]))
allow = settings.get("permissions", {}).get("allow", [])
assert "mcp__codex-worker__codex" in allow
assert "mcp__codex-worker__codex-reply" in allow
PY
then
  pass 'Codex worker permissions are installed'
else
  fail 'Codex worker permissions are missing'
fi

health="$(curl -fsS --max-time 3 "${HEADROOM_HEALTH_URL:-http://127.0.0.1:8787/health}" 2>/dev/null || true)"
if printf '%s\n' "$health" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' \
  && printf '%s\n' "$health" | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true'; then
  pass 'Headroom proxy is healthy'
else
  fail 'Headroom proxy health check failed'
fi

if command -v mempalace >/dev/null 2>&1 && command -v mempalace-mcp >/dev/null 2>&1; then
  pass 'Mempalace CLI and MCP are available'
else
  fail 'Mempalace CLI or MCP is unavailable'
fi

if [ -n "$codex_bin" ] && [ -n "$python_bin" ] \
  && [ -x "$WORKER_WRAPPER" ] \
  && "$python_bin" "$REPO_DIR/tools/model-team/mcp-smoke.py" --codex-bin "$codex_bin" \
    --worker-wrapper "$WORKER_WRAPPER" 2>/dev/null \
    | grep -Fq 'codex,codex-reply'; then
  pass 'Codex MCP exposes codex and codex-reply'
else
  fail 'Codex MCP handshake failed'
fi

printf '\nModel-team doctor: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
