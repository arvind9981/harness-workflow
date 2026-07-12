#!/usr/bin/env bash
# Check the optional OpenCode workflow adapter without changing any files.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
PASS=0
FAIL=0
WARN=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN  %s\n' "$1"; WARN=$((WARN + 1)); }

check_file() {  # <relative source path> <relative installed path>
  local src="$REPO_DIR/opencode/$1" dest="$OPENCODE_DIR/$2"
  if [ ! -f "$dest" ]; then
    fail "missing: $dest"
  elif cmp -s "$src" "$dest"; then
    pass "$2 matches repo source"
  else
    fail "$2 differs from repo source"
  fi
}

if command -v opencode >/dev/null 2>&1; then
  pass "OpenCode CLI available ($(opencode --version 2>/dev/null || printf 'version unavailable'))"
else
  warn "OpenCode CLI not installed (install with: npm install -g opencode-ai)"
fi

check_file 'agents/consult.md' 'agents/consult.md'
check_file 'commands/consult.md' 'commands/consult.md'
check_file 'plugins/workflow.ts' 'plugins/workflow.ts'

skill_bad=0
while IFS= read -r -d '' src; do
  rel="${src#"$REPO_DIR/workflow/skills/"}"
  dest="$OPENCODE_DIR/skills/$rel"
  if [ ! -f "$dest" ]; then
    fail "shared skill missing: $dest"
    skill_bad=1
  elif ! cmp -s "$src" "$dest"; then
    fail "shared skill differs: $dest"
    skill_bad=1
  fi
done < <(find "$REPO_DIR/workflow/skills" -type f -print0)
if [ "$skill_bad" -eq 0 ]; then
  pass "all shared workflow skills are installed in OpenCode"
fi

for src in "$REPO_DIR"/workflow/hooks/*.sh; do
  [ -e "$src" ] || continue
  dest="$OPENCODE_DIR/workflow/hooks/$(basename "$src")"
  if [ -x "$dest" ] && cmp -s "$src" "$dest"; then
    :
  else
    fail "workflow helper missing or differs: $dest"
  fi
done
if [ "$FAIL" -eq 0 ]; then
  pass "all OpenCode lifecycle helpers match repo source"
fi

if command -v opencode >/dev/null 2>&1; then
  mcp_list="$(opencode mcp list 2>/dev/null || true)"
  if printf '%s' "$mcp_list" | grep -q 'mempalace'; then
    pass "Mempalace MCP is configured"
  else
    warn "Mempalace MCP is not configured (run: opencode mcp add mempalace -- mempalace-mcp)"
  fi
  if printf '%s' "$mcp_list" | grep -q 'headroom'; then
    pass "Headroom MCP is configured"
  else
    warn "Headroom MCP is not configured (run: opencode mcp add headroom -- headroom mcp serve)"
  fi
fi

printf '\nOpenCode workflow doctor: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
