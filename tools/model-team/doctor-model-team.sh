#!/usr/bin/env bash

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/codex/lib.sh
. "$REPO_DIR/tools/codex/lib.sh"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_FILE="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
CLAUDE_SETTINGS_LOCAL_FILE="${CLAUDE_SETTINGS_LOCAL_FILE:-$CLAUDE_DIR/settings.local.json}"
PASS=0
FAIL=0

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

codex_bin="$(codex_resolve_bin || true)"
python_bin="$(codex_python_resolve || true)"

if [ -f "$CLAUDE_DIR/skills/model-team/SKILL.md" ]; then
  pass 'model-team skill installed'
else
  fail 'model-team skill missing'
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

if [ -n "$codex_bin" ] && [ -n "$python_bin" ] && [ -f "$CLAUDE_CONFIG_FILE" ] \
  && "$python_bin" - "$CLAUDE_CONFIG_FILE" "$codex_bin" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
worker = config.get("mcpServers", {}).get("codex-worker", {})
assert worker.get("command") == sys.argv[2]
assert worker.get("args") == ["mcp-server", "-c", "mcp_servers.MCP_DOCKER.enabled=false"]
PY
then
  pass 'codex-worker MCP registration is isolated from Jira'
else
  fail 'codex-worker MCP registration is missing or drifted'
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
  && "$python_bin" "$REPO_DIR/tools/model-team/mcp-smoke.py" --codex-bin "$codex_bin" 2>/dev/null \
    | grep -Fq 'codex,codex-reply'; then
  pass 'Codex MCP exposes codex and codex-reply'
else
  fail 'Codex MCP handshake failed'
fi

printf '\nModel-team doctor: %s pass, %s fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
