#!/usr/bin/env bash

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILURES=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file_contains() {
  local file="$1" needle="$2" label="$3"
  if [ -f "$file" ] && grep -Fq -- "$needle" "$file"; then pass "$label"; else fail "$label"; fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" label="$3"
  if [ -f "$file" ] && ! grep -Fq -- "$needle" "$file"; then pass "$label"; else fail "$label"; fi
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
    fail "$label"
  fi
}

assert_text_contains() {
  local text="$1" needle="$2" label="$3"
  if printf '%s\n' "$text" | grep -Fq -- "$needle"; then pass "$label"; else fail "$label"; fi
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    cksum "$1" | awk '{print $1 ":" $2}'
  fi
}

make_fake_codex() {
  local path="$1"
  cat > "$path" <<'PY'
#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"id": msg["id"], "result": {"serverInfo": {"name": "fake-codex", "version": "1"}}}), flush=True)
    elif method == "tools/list":
        print(json.dumps({"id": msg["id"], "result": {"tools": [{"name": "codex"}, {"name": "codex-reply"}]}}), flush=True)
PY
  chmod +x "$path"
}

test_sources() {
  local model_skill="$REPO_DIR/claude/skills/model-team/SKILL.md"
  local jira_skill="$REPO_DIR/workflow/skills/jira-live/SKILL.md"
  local claude_settings="$REPO_DIR/claude/settings.local.json"
  local watcher="$REPO_DIR/tools/model-team/model-team-watch"

  assert_file_contains "$model_skill" 'name: model-team' 'model-team skill has a stable name'
  assert_file_contains "$model_skill" 'explicit single-agent' 'single-agent opt-out has highest precedence'
  assert_file_contains "$model_skill" 'Automatic activation' 'model-team supports automatic activation'
  assert_file_contains "$model_skill" '/model-team' 'model-team supports explicit activation'
  assert_file_contains "$model_skill" 'mcp__codex-worker__codex' 'model-team dispatches the Codex MCP worker'
  assert_file_contains "$model_skill" 'mcp__codex-worker__codex-reply' 'model-team continues the same Codex thread'
  assert_file_contains "$model_skill" 'MCP server process' 'model-team documents reply thread lifetime'
  assert_file_contains "$model_skill" 'danger-full-access' 'model-team preserves full troubleshooting access'
  assert_file_contains "$model_skill" 'five bullets' 'model-team bounds memory handoff size'
  assert_file_contains "$model_skill" 'Never forward' 'model-team forbids transcript forwarding'
  assert_file_contains "$model_skill" 'MODEL-TEAM DISPATCH' 'model-team announces worker dispatch'
  assert_file_contains "$model_skill" 'MODEL-TEAM REVIEW' 'model-team announces controller review'
  assert_file_contains "$model_skill" 'MODEL-TEAM COMPLETE' 'model-team emits a completion receipt'
  if [ -x "$watcher" ]; then
    pass 'model-team watcher exists and is executable'
  else
    fail 'model-team watcher exists and is executable'
  fi

  assert_file_contains "$jira_skill" 'name: jira-live' 'Jira policy is an on-demand skill'
  assert_file_contains "$jira_skill" 'MCP_DOCKER' 'Jira skill uses the configured Docker MCP'
  assert_file_contains "$jira_skill" 'retry the identical read-only Jira tool call once' 'Jira skill preserves bounded retry'
  assert_file_contains "$jira_skill" 'docker mcp tools call' 'Jira skill preserves direct gateway fallback'
  assert_file_contains "$jira_skill" 'Never automatically replay a Jira write' 'Jira skill protects ambiguous writes'
  assert_file_not_contains "$REPO_DIR/codex/AGENTS.md" '## Jira' 'Jira policy is absent from AGENTS'
  assert_file_contains "$claude_settings" 'mcp__codex-worker__codex"' 'Claude template permits Codex worker dispatch'
  assert_file_contains "$claude_settings" 'mcp__codex-worker__codex-reply"' 'Claude template permits Codex worker continuation'
}

test_installer() {
  local installer="$REPO_DIR/tools/model-team/install-model-team.sh"
  local tmp home bin_dir config settings fake_codex python_bin first_hash second_hash first_settings_hash
  local second_settings_hash first_backups second_backups
  if [ ! -x "$installer" ]; then
    fail 'model-team installer exists and is executable'
    return
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/model-team-installer.XXXXXX")"
  home="$tmp/home"
  bin_dir="$home/.local/bin"
  config="$home/.claude.json"
  settings="$home/.claude/settings.local.json"
  fake_codex="$tmp/codex"
  python_bin="$(command -v python3)"
  mkdir -p "$home/.claude" "$bin_dir"
  make_fake_codex "$fake_codex"
  cat > "$config" <<'JSON'
{
  "keep": "yes",
  "mcpServers": {
    "MCP_DOCKER": {"command": "docker", "args": ["mcp", "gateway", "run", "--profile", "xebia"]},
    "sentinel": {"command": "sentinel", "args": []}
  }
}
JSON
  cat > "$settings" <<'JSON'
{
  "permissions": {
    "allow": ["sentinel-permission"],
    "deny": ["sentinel-deny"]
  },
  "sentinel": true
}
JSON

  if HOME="$home" CLAUDE_DIR="$home/.claude" CLAUDE_CONFIG_FILE="$config" \
      CLAUDE_SETTINGS_LOCAL_FILE="$settings" BIN_DIR="$bin_dir" CODEX_BIN="$fake_codex" \
      CODEX_PYTHON_BIN="$python_bin" PATH="/usr/bin:/bin" \
      "$installer" >/dev/null; then
    pass 'model-team installer completes in an isolated home'
  else
    fail 'model-team installer completes in an isolated home'
    rm -rf "$tmp"
    return
  fi

  if python3 - "$settings" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1]))
allow = settings["permissions"]["allow"]
assert settings["sentinel"] is True
assert settings["permissions"]["deny"] == ["sentinel-deny"]
assert "sentinel-permission" in allow
assert "mcp__codex-worker__codex" in allow
assert "mcp__codex-worker__codex-reply" in allow
PY
  then
    pass 'installer merges worker permissions without replacing Claude settings'
  else
    fail 'installer merges worker permissions without replacing Claude settings'
  fi

  if python3 - "$config" "$fake_codex" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
assert config["keep"] == "yes"
assert config["mcpServers"]["MCP_DOCKER"]["command"] == "docker"
assert config["mcpServers"]["sentinel"]["command"] == "sentinel"
worker = config["mcpServers"]["codex-worker"]
assert worker["command"] == sys.argv[2]
assert worker["args"] == ["mcp-server", "-c", "mcp_servers.MCP_DOCKER.enabled=false"]
PY
  then
    pass 'installer preserves unrelated Claude config and isolates Jira from worker'
  else
    fail 'installer preserves unrelated Claude config and isolates Jira from worker'
  fi

  if [ -f "$home/.claude/skills/model-team/SKILL.md" ]; then
    pass 'installer deploys model-team skill'
  else
    fail 'installer deploys model-team skill'
  fi
  if [ -f "$home/.claude/skills/jira-live/SKILL.md" ]; then
    pass 'installer deploys Jira skill to Claude'
  else
    fail 'installer deploys Jira skill to Claude'
  fi
  if [ -x "$bin_dir/model-team-watch" ]; then
    pass 'installer deploys model-team watcher'
  else
    fail 'installer deploys model-team watcher'
  fi

  first_hash="$(hash_file "$config")"
  first_settings_hash="$(hash_file "$settings")"
  first_backups="$(find "$home" -type f -name '*.bak-model-team-*' | wc -l | tr -d ' ')"
  HOME="$home" CLAUDE_DIR="$home/.claude" CLAUDE_CONFIG_FILE="$config" \
    CLAUDE_SETTINGS_LOCAL_FILE="$settings" BIN_DIR="$bin_dir" CODEX_BIN="$fake_codex" \
    CODEX_PYTHON_BIN="$python_bin" PATH="/usr/bin:/bin" \
    "$installer" >/dev/null
  second_hash="$(hash_file "$config")"
  second_settings_hash="$(hash_file "$settings")"
  second_backups="$(find "$home" -type f -name '*.bak-model-team-*' | wc -l | tr -d ' ')"
  assert_eq "$first_hash" "$second_hash" 'second model-team install preserves config hash'
  assert_eq "$first_settings_hash" "$second_settings_hash" 'second model-team install preserves settings hash'
  assert_eq "$first_backups" "$second_backups" 'second model-team install creates no backups'

  rm -rf "$tmp"
}

test_protocol() {
  local smoke="$REPO_DIR/tools/model-team/mcp-smoke.py"
  local tmp fake_codex output
  if [ ! -f "$smoke" ]; then
    fail 'token-free MCP smoke client exists'
    return
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/model-team-mcp.XXXXXX")"
  fake_codex="$tmp/codex"
  make_fake_codex "$fake_codex"
  output="$(python3 "$smoke" --codex-bin "$fake_codex" 2>&1)"
  assert_text_contains "$output" 'codex,codex-reply' 'MCP smoke requires start and reply tools'
  rm -rf "$tmp"
}

test_doctor() {
  local doctor="$REPO_DIR/tools/model-team/doctor-model-team.sh"
  local installer="$REPO_DIR/tools/model-team/install-model-team.sh"
  local tmp home config settings fake_codex fake_bin python_bin output
  if [ ! -x "$doctor" ] || [ ! -x "$installer" ]; then
    fail 'model-team doctor and installer exist'
    return
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/model-team-doctor.XXXXXX")"
  home="$tmp/home"
  config="$home/.claude.json"
  settings="$home/.claude/settings.local.json"
  fake_codex="$tmp/codex"
  fake_bin="$tmp/bin"
  python_bin="$(command -v python3)"
  mkdir -p "$home" "$fake_bin"
  make_fake_codex "$fake_codex"
  for command in headroom mempalace mempalace-mcp; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/$command"
    chmod +x "$fake_bin/$command"
  done
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"service":"headroom-proxy","status":"healthy","ready":true}\n'
EOF
  chmod +x "$fake_bin/curl"

  HOME="$home" CLAUDE_DIR="$home/.claude" CLAUDE_CONFIG_FILE="$config" \
    CLAUDE_SETTINGS_LOCAL_FILE="$settings" BIN_DIR="$fake_bin" CODEX_BIN="$fake_codex" \
    CODEX_PYTHON_BIN="$python_bin" PATH="/usr/bin:/bin" \
    "$installer" >/dev/null
  output="$(HOME="$home" CLAUDE_DIR="$home/.claude" CLAUDE_CONFIG_FILE="$config" \
    CLAUDE_SETTINGS_LOCAL_FILE="$settings" CODEX_BIN="$fake_codex" \
    CODEX_PYTHON_BIN="$python_bin" \
    PATH="$fake_bin:/usr/bin:/bin" "$doctor" 2>&1)"
  assert_text_contains "$output" 'PASS model-team skill installed' 'doctor checks model-team skill'
  assert_text_contains "$output" 'PASS jira-live skill installed' 'doctor checks Jira skill'
  assert_text_contains "$output" 'PASS codex-worker MCP registration is isolated from Jira' 'doctor checks worker isolation'
  assert_text_contains "$output" 'PASS Codex worker permissions are installed' 'doctor checks worker permissions'
  assert_text_contains "$output" 'PASS Headroom proxy is healthy' 'doctor checks Headroom health'
  assert_text_contains "$output" 'PASS Mempalace CLI and MCP are available' 'doctor checks Mempalace availability'
  assert_text_contains "$output" 'PASS Codex MCP exposes codex and codex-reply' 'doctor runs token-free MCP handshake'
  assert_text_contains "$output" 'PASS model-team-watch is installed' 'doctor checks watcher installation'
  rm -rf "$tmp"
}

test_watchers() {
  local watcher="$REPO_DIR/tools/model-team/model-team-watch"
  local headroom_watcher="$REPO_DIR/tools/headroom/headroom-watch"
  local tmp stats health processes repo output json_output

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/model-team-watch.XXXXXX")"
  stats="$tmp/stats.json"
  health="$tmp/health.json"
  processes="$tmp/processes.txt"
  repo="$tmp/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'untracked\n' > "$repo/change.txt"
  cat > "$stats" <<'JSON'
{
  "summary": {
    "mode": "cache",
    "primary_model": "claude-fable-5",
    "api_requests": 3,
    "compression": {"requests_compressed": 1, "avg_compression_pct": 20, "best_compression_pct": 20, "best_detail": "10 → 8 tokens", "total_tokens_removed": 2},
    "uncompressed_requests": {"prefix_frozen": 1, "too_small": 0, "passthrough": 1, "no_compressible_content": 0},
    "cost": {"total_saved_usd": 0.01, "savings_pct": 1, "breakdown": {"cache_savings_usd": 0}},
    "mcp": {"compressions": 0, "tokens_removed": 0, "retrievals": 0}
  },
  "request_logs": [
    {"request_id":"claude-1","timestamp":"2026-07-15T11:59:00.000000","model":"claude-fable-5","total_latency_ms":4000,"tags":{"client":"claude-code"}},
    {"request_id":"codex-1","timestamp":"2026-07-15T12:00:00.000000","model":"gpt-5.6-terra","total_latency_ms":8000,"tags":{"client":"codex"}},
    {"request_id":"codex-2","timestamp":"2026-07-15T12:00:51.000000","model":"gpt-5.6-sol","total_latency_ms":10307,"tags":{"client":"codex"}}
  ]
}
JSON
  printf '{"status":"healthy","ready":true,"uptime_seconds":600}\n' > "$health"
  printf '38295 08:24 /Applications/ChatGPT.app/Contents/Resources/codex mcp-server -c mcp_servers.MCP_DOCKER.enabled=false\n' > "$processes"

  if [ -x "$watcher" ]; then
    output="$(MODEL_TEAM_STATS_FILE="$stats" MODEL_TEAM_HEALTH_FILE="$health" \
      MODEL_TEAM_PS_FILE="$processes" "$watcher" --once --repo "$repo" 2>&1)"
    assert_text_contains "$output" 'codex-worker  UP' 'watcher reports MCP server availability'
    assert_text_contains "$output" 'gpt-5.6-sol' 'watcher reports latest Codex model'
    assert_text_contains "$output" '12:00:51' 'watcher reports latest Codex request time'
    assert_text_contains "$output" 'changed files  1' 'watcher reports repository changes'

    json_output="$(MODEL_TEAM_STATS_FILE="$stats" MODEL_TEAM_HEALTH_FILE="$health" \
      MODEL_TEAM_PS_FILE="$processes" "$watcher" --json --repo "$repo" 2>&1)"
    if printf '%s' "$json_output" | jq -e '
      .worker.up == true and .worker.pid == 38295 and
      .activity.model == "gpt-5.6-sol" and .activity.client == "codex" and
      .activity.requests_5m == 2 and .repository.changed_files == 1 and
      .headroom.healthy == true' >/dev/null 2>&1; then
      pass 'watcher JSON output exposes verified process, activity, repo, and health state'
    else
      fail 'watcher JSON output exposes verified process, activity, repo, and health state'
    fi
  else
    fail 'watcher reports MCP server availability'
    fail 'watcher reports latest Codex model'
    fail 'watcher reports latest Codex request time'
    fail 'watcher reports repository changes'
    fail 'watcher JSON output exposes verified process, activity, repo, and health state'
  fi

  output="$(HEADROOM_STATS_FILE="$stats" HEADROOM_HEALTH_FILE="$health" \
    "$headroom_watcher" --once 2>&1)"
  assert_text_contains "$output" 'latest gpt-5.6-sol' 'headroom watcher shows latest observed model'
  assert_text_contains "$output" 'client codex' 'headroom watcher shows latest observed client'
  assert_text_contains "$output" '12:00:51' 'headroom watcher shows latest observed request time'
  rm -rf "$tmp"
}

usage() {
  printf 'Usage: %s {sources|installer|protocol|doctor|watchers|all}\n' "$0" >&2
}

group="${1:-all}"
case "$group" in
  sources) test_sources ;;
  installer) test_installer ;;
  protocol) test_protocol ;;
  doctor) test_doctor ;;
  watchers) test_watchers ;;
  all)
    test_sources
    test_installer
    test_protocol
    test_doctor
    test_watchers
    ;;
  *) usage; exit 2 ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi
