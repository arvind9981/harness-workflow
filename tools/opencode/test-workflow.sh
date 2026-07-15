#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-all}"
PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

assert_file() {
  if [ -f "$1" ]; then pass "file exists: $1"; else fail "missing file: $1"; fi
}

assert_absent() {
  if [ ! -e "$1" ]; then pass "legacy path removed: $1"; else fail "legacy path remains: $1"; fi
}

run_layout() {
  local rel
  for rel in \
    opencode/agents/build.md \
    opencode/agents/plan.md \
    opencode/agents/explore.md \
    opencode/agents/scout.md \
    opencode/agents/service.md \
    opencode/agents/memory.md \
    opencode/commands/team.md \
    opencode/opencode.json \
    opencode/instructions/workflow.md \
    opencode/plugins/workflow.ts \
    opencode/skills/model-team/SKILL.md \
    tools/opencode/claude-worker-mcp \
    tools/opencode/mcp-smoke.py \
    tools/opencode/test-plugin.mjs; do
    assert_file "$REPO_DIR/$rel"
  done

  for rel in \
    opencode/README.md \
    opencode/agents/consult.md \
    opencode/agents/general.md \
    opencode/commands/consult.md; do
    if [ -e "$REPO_DIR/$rel" ]; then
      fail "obsolete repo path remains: $rel"
    else
      pass "obsolete repo path absent: $rel"
    fi
  done

  grep -Fq 'score 0-2' "$REPO_DIR/opencode/skills/model-team/SKILL.md" \
    && pass 'routing skill defines the small-task threshold' \
    || fail 'routing skill lacks the small-task threshold'
  grep -Fq 'Do not wait for the user to invoke an agent' "$REPO_DIR/opencode/skills/model-team/SKILL.md" \
    && pass 'routing skill requires automatic dispatch' \
    || fail 'routing skill does not require automatic dispatch'
  grep -Fq 'claude-worker_claude' "$REPO_DIR/opencode/agents/build.md" \
    && pass 'build agent enables the bounded Claude worker' \
    || fail 'build agent does not enable the bounded Claude worker'
  ! grep -Fq 'MCP_DOCKER_*: true' "$REPO_DIR/opencode/agents/build.md" \
    && grep -Fq 'service: allow' "$REPO_DIR/opencode/agents/build.md" \
    && grep -Fq 'MCP_DOCKER_*: true' "$REPO_DIR/opencode/agents/service.md" \
    && pass 'Docker MCP schemas are isolated behind the automatic service agent' \
    || fail 'Docker MCP schemas leak into ordinary build sessions'
  ! grep -Fq 'mempalace_*: true' "$REPO_DIR/opencode/agents/build.md" \
    && grep -Fq 'memory: allow' "$REPO_DIR/opencode/agents/build.md" \
    && grep -Fq 'mempalace_*: true' "$REPO_DIR/opencode/agents/memory.md" \
    && pass 'Mempalace schemas are isolated behind the automatic memory agent' \
    || fail 'Mempalace schemas leak into ordinary build sessions'
  grep -Fq 'permission:' "$REPO_DIR/opencode/agents/explore.md" \
    && grep -Fq 'edit: deny' "$REPO_DIR/opencode/agents/explore.md" \
    && ! grep -Fq 'Graphify' "$REPO_DIR/opencode/agents/explore.md" \
    && pass 'explore agent is explicitly read-only' \
    || fail 'explore agent has an impossible read-only contract'
  grep -Fq '"name": "jira_<operation>"' "$REPO_DIR/workflow/skills/jira-live/SKILL.md" \
    && grep -Fq '"arguments": {"<argument>": "<value>"}' "$REPO_DIR/workflow/skills/jira-live/SKILL.md" \
    && pass 'Jira skill documents dynamic Docker execution' \
    || fail 'Jira skill does not document dynamic Docker execution'
  grep -Fq 'sys.version_info < (3, 10)' "$REPO_DIR/tools/opencode/install-opencode.sh" \
    && pass 'installer rejects unsupported Python versions' \
    || fail 'installer does not reject unsupported Python versions'
  jq -e '
    .model == "openai/gpt-5.6-sol" and
    .small_model == "openai/gpt-5.6-luna" and
    .provider.openai.options.baseURL == "http://127.0.0.1:8787/v1" and
    .mcp.mempalace.command == ["mempalace-mcp"] and
    .tools["MCP_DOCKER_*"] == false
  ' "$REPO_DIR/opencode/opencode.json" >/dev/null \
    && pass 'tracked OpenCode baseline contains portable workflow defaults' \
    || fail 'tracked OpenCode baseline is missing portable workflow defaults'
  grep -Fq 'automatically routes medium work through Sonnet 5' "$REPO_DIR/README.md" \
    && grep -Fq 'high-risk work through Fable 5' "$REPO_DIR/README.md" \
    && pass 'README documents automatic OpenCode routing' \
    || fail 'README does not document automatic OpenCode routing'
  grep -Fq 'routes OpenAI traffic through Headroom' "$REPO_DIR/README.md" \
    && pass 'README documents direct OpenCode Headroom routing' \
    || fail 'README does not document direct OpenCode Headroom routing'
  if grep -Fq 'Claude worker MCP used for automatic Sonnet/Fable planning and review' "$REPO_DIR/init.sh"; then
    pass 'init describes the Claude worker MCP install'
  else
    fail 'init still describes the legacy OpenCode adapter'
  fi
}

run_install() {
  local temp home config claude_dir bin_dir fake_bin first second third
  local no_docker_home no_docker_config no_docker_claude no_docker_bin no_docker_output
  local missing_home missing_config missing_claude missing_bin missing_output
  temp="$(mktemp -d)"
  home="$temp/home"
  config="$home/.config/opencode"
  claude_dir="$home/.claude"
  bin_dir="$home/.local/bin"
  fake_bin="$temp/fake-bin"
  mkdir -p "$config/agents" "$config/commands" "$config/plugins" \
    "$config/workflow/hooks" "$claude_dir/agents" "$bin_dir" "$fake_bin"

  cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'mcp --help') [ "${FAKE_DOCKER_MCP:-1}" = 1 ] ;;
  'mcp profile list') printf '%s\n' "${FAKE_DOCKER_PROFILES:-portable-test}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fake_bin/docker"

  printf '%s\n' '<!-- claude-workflow: managed opencode consult agent -->' > "$config/agents/consult.md"
  printf '%s\n' '<!-- claude-workflow: managed opencode consult command -->' > "$config/commands/consult.md"
  git -C "$REPO_DIR" show HEAD:opencode/plugins/workflow.ts > "$config/plugins/workflow.ts"
  printf '%s\n' 'claude-workflow managed OpenCode helpers' > "$config/workflow/.claude-workflow-managed"
  printf '%s\n' 'old helper' > "$config/workflow/hooks/old.sh"
  printf '%s\n' 'export const ClaudeWorkflowHooks = true' 'const GRAPHIFY_EVENTS = new Set()' 'const marker = "headroom-init-opencode"' \
    > "$config/plugins/claude-workflow-hooks.js"
  printf '%s\n' '# OpenCode Instructions' '' '- OpenCode loads `~/.config/opencode/plugins/claude-workflow-hooks.js`; that' \
    '  plugin refreshes an existing graphify graph after file edits.' > "$config/AGENTS.md"

  jq -n --arg instruction "$config/AGENTS.md" '{
    model: "openai/gpt-5.5",
    small_model: "openai/gpt-5.5",
    instructions: [$instruction],
    plugin: ["keep-me"],
    provider: {openai: {options: {apiKey: "preserve-me", baseURL: "https://replace.invalid/v1"}}},
    mcp: {
      headroom: {type: "local", command: ["headroom", "mcp", "serve"]},
      mempalace: {type: "local", command: ["mempalace-mcp"]},
      personal: {type: "local", command: ["personal-mcp"]}
    },
    permission: {bash: {"git status*": "allow"}}
  }' > "$config/opencode.json"

  first="$(PATH="$fake_bin:$PATH" HOME="$home" OPENCODE_DIR="$config" CLAUDE_DIR="$claude_dir" BIN_DIR="$bin_dir" \
    MCP_DOCKER_PROFILE=portable-test \
    OPENCODE_INSTALL_LIVE=0 bash "$REPO_DIR/tools/opencode/install-opencode.sh")"
  second="$(PATH="$fake_bin:$PATH" HOME="$home" OPENCODE_DIR="$config" CLAUDE_DIR="$claude_dir" BIN_DIR="$bin_dir" \
    MCP_DOCKER_PROFILE=portable-test \
    OPENCODE_INSTALL_LIVE=0 bash "$REPO_DIR/tools/opencode/install-opencode.sh")"
  third="$(PATH="$fake_bin:$PATH" HOME="$home" OPENCODE_DIR="$config" CLAUDE_DIR="$claude_dir" BIN_DIR="$bin_dir" \
    OPENCODE_INSTALL_LIVE=0 bash "$REPO_DIR/tools/opencode/install-opencode.sh")"

  assert_absent "$config/agents/consult.md"
  assert_absent "$config/commands/consult.md"
  assert_absent "$config/plugins/claude-workflow-hooks.js"
  assert_absent "$config/workflow"
  assert_absent "$config/agents/general.md"
  assert_file "$config/agents/build.md"
  assert_file "$config/agents/service.md"
  assert_file "$config/agents/memory.md"
  assert_file "$config/commands/team.md"
  assert_file "$config/plugins/workflow.ts"
  assert_file "$config/skills/model-team/SKILL.md"
  assert_file "$config/harness-workflow/instructions.md"
  assert_absent "$claude_dir/agents/opencode-model-team.md"
  assert_file "$bin_dir/claude-worker-mcp"

  jq -e '
    .model == "openai/gpt-5.6-sol" and
    .small_model == "openai/gpt-5.6-luna" and
    .plugin == ["keep-me"] and
    .provider.openai.options.baseURL == "http://127.0.0.1:8787/v1" and
    .provider.openai.options.apiKey == "preserve-me" and
    .mcp.headroom == null and
    .mcp.mempalace.command == ["mempalace-mcp"] and
    .mcp.personal.command == ["personal-mcp"] and
    .mcp.MCP_DOCKER.command == ["docker", "mcp", "gateway", "run", "--profile", "portable-test", "--tools", "mcp-exec"] and
    .mcp["claude-worker"].command[0] != null and
    .mcp["claude-worker"].environment.ANTHROPIC_BASE_URL == "http://127.0.0.1:8787" and
    .tools["claude-worker_*"] == false and
    .tools["mempalace_*"] == false and
    .tools["MCP_DOCKER_*"] == false and
    .permission.bash["git status*"] == "allow" and
    ([.instructions[] | select(endswith("/harness-workflow/instructions.md"))] | length) == 1
  ' "$config/opencode.json" >/dev/null \
    && pass 'installer reconciles only workflow-owned config keys' \
    || fail 'installer did not preserve or reconcile config correctly'

  grep -Fq 'claude-workflow-hooks.js' "$config/AGENTS.md" \
    && fail 'stale OpenCode AGENTS plugin reference remains' \
    || pass 'stale OpenCode AGENTS plugin reference removed'

  printf '%s' "$first" | grep -Eq 'updated|installed' \
    && pass 'first install reports applied changes' \
    || fail 'first install did not report changes'
  printf '%s' "$second" | grep -Fq '(0 file(s) updated)' \
    && pass 'second install is idempotent' \
    || fail 'second install is not idempotent'
  printf '%s' "$third" | grep -Fq '(0 file(s) updated)' \
    && jq -e '.mcp.MCP_DOCKER.command == ["docker", "mcp", "gateway", "run", "--profile", "portable-test", "--tools", "mcp-exec"]' \
      "$config/opencode.json" >/dev/null 2>&1 \
    && pass 'installer preserves the configured Docker profile when no override is supplied' \
    || fail 'installer replaced the configured Docker profile without an override'

  if PATH="$fake_bin:$PATH" HOME="$home" OPENCODE_DIR="$config" CLAUDE_DIR="$claude_dir" BIN_DIR="$bin_dir" \
    OPENCODE_DOCTOR_LIVE=0 \
    bash "$REPO_DIR/tools/opencode/doctor-workflow.sh" >/dev/null; then
    pass 'doctor accepts the isolated installed state'
  else
    fail 'doctor rejects the isolated installed state'
  fi

  no_docker_home="$temp/no-docker-home"
  no_docker_config="$no_docker_home/.config/opencode"
  no_docker_claude="$no_docker_home/.claude"
  no_docker_bin="$no_docker_home/.local/bin"
  no_docker_output="$(PATH="$fake_bin:$PATH" FAKE_DOCKER_MCP=0 HOME="$no_docker_home" \
    OPENCODE_DIR="$no_docker_config" CLAUDE_DIR="$no_docker_claude" BIN_DIR="$no_docker_bin" \
    OPENCODE_INSTALL_LIVE=0 bash "$REPO_DIR/tools/opencode/install-opencode.sh")"
  if jq -e '.mcp.MCP_DOCKER == null' "$no_docker_config/opencode.json" >/dev/null \
    && printf '%s' "$no_docker_output" | grep -Fq 'Docker MCP unavailable; optional gateway skipped'; then
    pass 'installer skips Docker MCP cleanly when the capability is unavailable'
  else
    fail 'installer left a Docker MCP entry when the capability is unavailable'
  fi
  if PATH="$fake_bin:$PATH" FAKE_DOCKER_MCP=0 HOME="$no_docker_home" \
    OPENCODE_DIR="$no_docker_config" CLAUDE_DIR="$no_docker_claude" BIN_DIR="$no_docker_bin" \
    OPENCODE_DOCTOR_LIVE=0 bash "$REPO_DIR/tools/opencode/doctor-workflow.sh" >/dev/null; then
    pass 'doctor accepts an installation without optional Docker MCP support'
  else
    fail 'doctor treats missing optional Docker MCP support as fatal'
  fi

  missing_home="$temp/missing-profile-home"
  missing_config="$missing_home/.config/opencode"
  missing_claude="$missing_home/.claude"
  missing_bin="$missing_home/.local/bin"
  missing_output="$(PATH="$fake_bin:$PATH" FAKE_DOCKER_PROFILES=portable-test HOME="$missing_home" \
    OPENCODE_DIR="$missing_config" CLAUDE_DIR="$missing_claude" BIN_DIR="$missing_bin" \
    MCP_DOCKER_PROFILE=missing-profile OPENCODE_INSTALL_LIVE=0 \
    bash "$REPO_DIR/tools/opencode/install-opencode.sh")"
  if jq -e '.mcp.MCP_DOCKER.command == ["docker", "mcp", "gateway", "run", "--tools", "mcp-exec"]' \
    "$missing_config/opencode.json" >/dev/null \
    && printf '%s' "$missing_output" | grep -Fq 'Docker MCP profile unavailable: missing-profile; using profile-free gateway'; then
    pass 'installer falls back safely when the requested Docker profile is unavailable'
  else
    fail 'installer wrote an unavailable Docker MCP profile'
  fi
  rm -rf "$temp"
}

run_mcp() {
  local temp fake log
  temp="$(mktemp -d)"
  fake="$temp/claude"
  log="$temp/claude.log"
  cat > "$fake" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import sys
import time

arguments = sys.argv[1:]
with open(os.environ["FAKE_CLAUDE_LOG"], "a", encoding="utf-8") as handle:
    handle.write(" ".join(arguments) + "\n")

if any("BLOCK_UNTIL_CANCELLED" in argument for argument in arguments):
    with open(os.environ["FAKE_CLAUDE_PID_FILE"], "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))

    def cancelled(_signum, _frame):
        with open(os.environ["FAKE_CLAUDE_CANCEL_LOG"], "w", encoding="utf-8") as handle:
            handle.write("cancelled\n")
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    while True:
        time.sleep(0.1)

resumed = "--resume" in arguments
print(json.dumps({
    "result": "REPLY_OK" if resumed else "START_OK",
    "session_id": "session-test",
    "is_error": False,
    "modelUsage": {
        "claude-fable-5" if resumed else "claude-sonnet-5": {
            "inputTokens": 120,
            "outputTokens": 30,
            "cacheReadInputTokens": 40,
            "cacheCreationInputTokens": 10,
            "costUSD": 0.0123,
        }
    },
}))
PY
  chmod +x "$fake"

  FAKE_CLAUDE_LOG="$log" python3 "$REPO_DIR/tools/opencode/mcp-smoke.py" \
    --worker "$REPO_DIR/tools/opencode/claude-worker-mcp" \
    --claude-bin "$fake" --invoke >/dev/null \
    && pass 'Claude worker MCP exposes and invokes start/reply tools' \
    || fail 'Claude worker MCP smoke failed'

  grep -Fq -- '--model sonnet' "$log" \
    && grep -Fq -- '--effort high' "$log" \
    && grep -Fq -- '--safe-mode' "$log" \
    && grep -Fq -- '--system-prompt' "$log" \
    && grep -Fq -- '--max-budget-usd' "$log" \
    && ! grep -Fq -- '--agent opencode-model-team' "$log" \
    && pass 'advisor role uses an isolated, budgeted Sonnet 5 process' \
    || fail 'advisor role is not isolated and budgeted correctly'
  grep -Fq -- '--resume session-test' "$log" \
    && grep -Fq -- 'ROLE: routine-review' "$log" \
    && pass 'reply resumes the original Claude session in review mode' \
    || fail 'reply did not resume the original Claude session in review mode'

  if FAKE_CLAUDE_LOG="$log" FAKE_CLAUDE_PID_FILE="$temp/claude.pid" \
    FAKE_CLAUDE_CANCEL_LOG="$temp/cancelled" \
    python3 - "$REPO_DIR/tools/opencode/claude-worker-mcp" "$fake" \
      "$temp/claude.pid" "$temp/cancelled" <<'PY'
import json
import os
import selectors
import subprocess
import sys
import time

worker, fake, pid_file, cancel_file = sys.argv[1:]
process = subprocess.Popen(
    [sys.executable, worker, "--claude-bin", fake],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
)

def send(message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    assert selector.select(2), "worker did not initialize"
    assert json.loads(process.stdout.readline())["id"] == 1
    send({
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "claude", "arguments": {
            "role": "advisor", "prompt": "BLOCK_UNTIL_CANCELLED"
        }},
    })
    deadline = time.monotonic() + 3
    while not os.path.exists(pid_file) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert os.path.exists(pid_file), "fake Claude did not start"
    send({
        "jsonrpc": "2.0", "method": "notifications/cancelled",
        "params": {"requestId": 7, "reason": "test cancellation"},
    })
    deadline = time.monotonic() + 3
    while not os.path.exists(cancel_file) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert os.path.exists(cancel_file), "cancelled Claude process kept running"
finally:
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
PY
  then
    pass 'Claude worker terminates cancelled model calls'
  else
    fail 'Claude worker leaves cancelled model calls running'
  fi
  rm -rf "$temp"
}

run_plugin() {
  if ! command -v node >/dev/null 2>&1; then
    fail 'Node.js is required for the OpenCode lifecycle event test'
    return
  fi
  if node --experimental-strip-types "$REPO_DIR/tools/opencode/test-plugin.mjs" \
    "$REPO_DIR/opencode/plugins/workflow.ts"; then
    pass 'OpenCode lifecycle events inject context, isolate subagents, refresh graphs, and write recaps'
  else
    fail 'OpenCode lifecycle event test failed'
  fi
}

case "$MODE" in
  all) run_layout; run_install; run_mcp; run_plugin ;;
  layout) run_layout ;;
  install) run_install ;;
  mcp) run_mcp ;;
  plugin) run_plugin ;;
  *) printf 'usage: %s [all|layout|install|mcp|plugin]\n' "$0" >&2; exit 2 ;;
esac

printf '\nOpenCode workflow tests: %s pass, %s fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
