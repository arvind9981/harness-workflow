#!/usr/bin/env bash
# shellcheck disable=SC2016

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

assert_text_not_contains() {
  local text="$1" needle="$2" label="$3"
  if ! printf '%s\n' "$text" | grep -Fq -- "$needle"; then pass "$label"; else fail "$label"; fi
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
import os
from pathlib import Path
import sys
import time

capture = os.environ.get("FAKE_CODEX_CAPTURE")
if capture:
    Path(capture).write_text(json.dumps({
        "argv": sys.argv[1:],
        "codex_home": os.environ.get("CODEX_HOME", ""),
    }))

if sys.argv[1:] == ["mcp", "list"]:
    print("No MCP servers configured yet. Try `codex mcp add my-tool -- my-command`.")
    raise SystemExit(0)

for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        print(json.dumps({"id": msg["id"], "result": {"serverInfo": {"name": "fake-codex", "version": "1"}}}), flush=True)
    elif method == "tools/list":
        print(json.dumps({"id": msg["id"], "result": {"tools": [{"name": "codex"}, {"name": "codex-reply"}]}}), flush=True)
    elif method == "tools/call":
        time.sleep(float(os.environ.get("FAKE_CODEX_DELAY", "0")))
        args = msg.get("params", {}).get("arguments", {})
        if args.get("prompt") == "__fail__":
            result = {"isError": True, "content": [{"type": "text", "text": "failed"}]}
        else:
            result = {
                "content": [{"type": "text", "text": "ok"}],
                "structuredContent": {"threadId": "fake-thread", "content": "ok"},
            }
        print(json.dumps({"id": msg["id"], "result": result}), flush=True)
PY
  chmod +x "$path"
}

test_sources() {
  local model_skill="$REPO_DIR/claude/skills/model-team/SKILL.md"
  local architect="$REPO_DIR/claude/agents/model-team-architect.md"
  local jira_skill="$REPO_DIR/workflow/skills/jira-live/SKILL.md"
  local claude_settings="$REPO_DIR/claude/settings.local.json"
  local claude_global_settings="$REPO_DIR/claude/settings.json"
  local watcher="$REPO_DIR/tools/model-team/model-team-watch"
  local worker_wrapper="$REPO_DIR/tools/model-team/codex-worker-mcp"
  local readme="$REPO_DIR/README.md"

  assert_file_contains "$model_skill" 'name: model-team' 'model-team skill has a stable name'
  assert_file_contains "$model_skill" 'explicit single-agent' 'single-agent opt-out has highest precedence'
  assert_file_contains "$model_skill" 'Automatic activation' 'model-team supports automatic activation'
  assert_file_contains "$model_skill" 'score 0-2' 'model-team defines the shared small-task threshold'
  assert_file_contains "$model_skill" 'score 3-6' 'model-team defines the shared standard-team threshold'
  assert_file_contains "$model_skill" 'score 7-12' 'model-team defines the shared high-risk threshold'
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
  assert_file_contains "$architect" 'name: model-team-architect' 'architect agent has a stable name'
  assert_file_contains "$architect" 'model: fable' 'architect agent pins Fable'
  assert_file_contains "$architect" 'tools: Read, Grep, Glob' 'architect agent is read-only'
  assert_file_contains "$architect" 'MODE: PLAN' 'architect defines a structured plan contract'
  assert_file_contains "$architect" 'MODE: REVIEW' 'architect defines a structured review contract'
  assert_file_not_contains "$architect" 'Jira' 'architect keeps live-service policy generic'
  assert_file_contains "$architect" 'VERDICT: accept|repair|replan|block' 'architect defines bounded review outcomes'
  assert_file_contains "$model_skill" 'model-team-architect' 'model-team delegates judgment to the Fable architect'
  assert_file_not_contains "$model_skill" 'Jira' 'model-team keeps live-service policy in on-demand skills'
  assert_file_contains "$model_skill" 'retain its agent ID' 'model-team preserves architect context for replanning'
  assert_file_contains "$model_skill" 'at most two' 'model-team bounds parallel read-only scouts'
  assert_file_contains "$model_skill" 'model-team-watch --mark planning' 'model-team records observable orchestration phases'
  assert_file_contains "$model_skill" 'instrumented MCP wrapper' 'model-team distinguishes measured worker calls from orchestration'
  assert_file_contains "$readme" '| Fable architect | `fable`' 'README documents the pinned Fable architect'
  assert_file_contains "$readme" '### Claude Code workflow' 'README separates the Claude execution sequence'
  assert_file_contains "$readme" 'Claude recalls relevant context' 'Claude workflow starts with controller routing'
  assert_file_contains "$readme" 'Fable creates read-only plan' 'Claude workflow names the planner'
  assert_file_contains "$readme" 'Codex implements<br/>only writer' 'Claude workflow names the implementation worker'
  assert_file_contains "$readme" 'Claude independently verifies' 'Claude workflow includes independent verification'
  assert_file_contains "$readme" 'Codex repairs on same thread<br/>codex-reply' 'Claude workflow shows worker continuation'
  assert_file_not_contains "$readme" 'Harness and route' 'README removes the component map presented as a workflow'
  assert_file_contains "$readme" 'current orchestration phase' 'README documents live phase visibility'
  assert_file_contains "$readme" 'zero inner MCP servers' 'README documents Codex worker tool isolation'
  assert_file_contains "$readme" '`ACTIVE`' 'README documents the active worker state'
  assert_file_contains "$readme" '`READY` and `IDLE`' 'README documents non-working worker states'
  assert_file_not_contains "$readme" '`requests/5m`' 'README does not claim machine-wide traffic is worker activity'
  assert_file_not_contains "$readme" '`codex-worker UP`' 'README does not conflate server availability with work'
  assert_file_not_contains "$readme" '| Claude controller | Configured Claude/Fable path | Planning' 'README does not claim the controller is the architect'
  if [ -x "$watcher" ]; then
    pass 'model-team watcher exists and is executable'
  else
    fail 'model-team watcher exists and is executable'
  fi
  if [ -x "$worker_wrapper" ]; then
    pass 'instrumented Codex MCP wrapper exists and is executable'
  else
    fail 'instrumented Codex MCP wrapper exists and is executable'
  fi

  assert_file_contains "$jira_skill" 'name: jira-live' 'Jira policy is an on-demand skill'
  assert_file_contains "$jira_skill" 'MCP_DOCKER' 'Jira skill uses the configured Docker MCP'
  assert_file_contains "$jira_skill" 'retry the identical read-only Jira tool call once' 'Jira skill preserves bounded retry'
  assert_file_contains "$jira_skill" 'docker mcp tools call' 'Jira skill preserves direct gateway fallback'
  assert_file_contains "$jira_skill" 'Never automatically replay a Jira write' 'Jira skill protects ambiguous writes'
  assert_file_not_contains "$REPO_DIR/codex/AGENTS.md" '## Jira' 'Jira policy is absent from AGENTS'
  assert_file_contains "$claude_settings" 'mcp__codex-worker__codex"' 'Claude template permits Codex worker dispatch'
  assert_file_contains "$claude_settings" 'mcp__codex-worker__codex-reply"' 'Claude template permits Codex worker continuation'
  assert_file_not_contains "$claude_settings" 'mcp__headroom__' 'Claude template has no stale Headroom MCP permission'
  assert_file_contains "$claude_global_settings" '"ENABLE_TOOL_SEARCH": "true"' 'Claude keeps MCP tool schemas deferred through Headroom'

  local tmp graphify_output graphify_context
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/graphify-nudge.XXXXXX")"
  mkdir -p "$tmp/home"
  printf '%s\n' '/tmp/repository|graphify_repository' > "$tmp/repos.conf"
  graphify_output="$(HOME="$tmp/home" GRAPHIFY_REPOS_CONF="$tmp/repos.conf" \
    "$REPO_DIR/workflow/hooks/graphify-reseed-session.sh")"
  graphify_context="$(python3 - "$graphify_output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload["hookSpecificOutput"]["additionalContext"])
PY
)"
  assert_text_contains "$graphify_context" 'graphify-sync.sh' 'Graphify nudge identifies the refresh command'
  assert_text_contains "$graphify_context" 'in-process mempalace_mine' 'Graphify nudge preserves the single-writer rule'
  assert_text_contains "$graphify_context" 'Do not mine FAIL' 'Graphify nudge preserves failed-label safety'
  if [ "$(printf '%s' "$graphify_context" | wc -c | tr -d ' ')" -le 700 ]; then
    pass 'Graphify nudge stays within its 700-byte prompt budget'
  else
    fail 'Graphify nudge stays within its 700-byte prompt budget'
  fi
  rm -rf "$tmp"
}

test_installer() {
  local installer="$REPO_DIR/tools/model-team/install-model-team.sh"
  local tmp home bin_dir config settings fake_codex python_bin first_hash second_hash first_settings_hash
  local second_settings_hash first_backups second_backups first_agent_hash second_agent_hash
  local installed_wrapper
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
  installed_wrapper="$bin_dir/codex-worker-mcp"
  python_bin="$(command -v python3)"
  mkdir -p "$home/.claude/agents" "$bin_dir"
  printf '%s\n' 'sentinel agent' > "$home/.claude/agents/sentinel.md"
  make_fake_codex "$fake_codex"
  cat > "$config" <<'JSON'
{
  "keep": "yes",
  "mcpServers": {
    "MCP_DOCKER": {"command": "docker", "args": ["mcp", "gateway", "run", "--profile", "xebia"]},
    "sentinel": {"command": "sentinel", "args": ["--keep"], "env": {"KEEP": "yes"}}
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

  if python3 - "$config" "$python_bin" "$installed_wrapper" "$fake_codex" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1]))
assert config["keep"] == "yes"
assert config["mcpServers"]["MCP_DOCKER"]["command"] == "docker"
assert config["mcpServers"]["MCP_DOCKER"]["args"] == [
    "mcp", "gateway", "run", "--profile", "xebia", "--tools", "mcp-exec"
]
assert config["mcpServers"]["sentinel"] == {
    "command": "sentinel", "args": ["--keep"], "env": {"KEEP": "yes"}
}
worker = config["mcpServers"]["codex-worker"]
assert worker["command"] == sys.argv[2]
assert worker["args"] == [sys.argv[3], "--codex-bin", sys.argv[4]]
PY
  then
    pass 'installer narrows Docker MCP while preserving personal MCPs and registering the worker'
  else
    fail 'installer did not preserve personal MCPs or reconcile managed MCPs'
  fi

  if [ -f "$home/.claude/skills/model-team/SKILL.md" ]; then
    pass 'installer deploys model-team skill'
  else
    fail 'installer deploys model-team skill'
  fi
  if [ -f "$home/.claude/agents/model-team-architect.md" ] \
      && grep -Fq 'model: fable' "$home/.claude/agents/model-team-architect.md" \
      && [ "$(cat "$home/.claude/agents/sentinel.md")" = 'sentinel agent' ]; then
    pass 'installer deploys the Fable architect without replacing unrelated agents'
  else
    fail 'installer deploys the Fable architect without replacing unrelated agents'
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
  if [ -x "$installed_wrapper" ]; then
    pass 'installer deploys the instrumented Codex MCP wrapper'
  else
    fail 'installer deploys the instrumented Codex MCP wrapper'
  fi

  first_hash="$(hash_file "$config")"
  first_settings_hash="$(hash_file "$settings")"
  first_agent_hash="$(hash_file "$home/.claude/agents/model-team-architect.md")"
  first_backups="$(find "$home" -type f -name '*.bak-model-team-*' | wc -l | tr -d ' ')"
  HOME="$home" CLAUDE_DIR="$home/.claude" CLAUDE_CONFIG_FILE="$config" \
    CLAUDE_SETTINGS_LOCAL_FILE="$settings" BIN_DIR="$bin_dir" CODEX_BIN="$fake_codex" \
    CODEX_PYTHON_BIN="$python_bin" PATH="/usr/bin:/bin" \
    "$installer" >/dev/null
  second_hash="$(hash_file "$config")"
  second_settings_hash="$(hash_file "$settings")"
  second_agent_hash="$(hash_file "$home/.claude/agents/model-team-architect.md")"
  second_backups="$(find "$home" -type f -name '*.bak-model-team-*' | wc -l | tr -d ' ')"
  assert_eq "$first_hash" "$second_hash" 'second model-team install preserves config hash'
  assert_eq "$first_settings_hash" "$second_settings_hash" 'second model-team install preserves settings hash'
  assert_eq "$first_agent_hash" "$second_agent_hash" 'second model-team install preserves architect hash'
  assert_eq "$first_backups" "$second_backups" 'second model-team install creates no backups'

  rm -rf "$tmp"
}

test_protocol() {
  local smoke="$REPO_DIR/tools/model-team/mcp-smoke.py"
  local wrapper="$REPO_DIR/tools/model-team/codex-worker-mcp"
  local tmp fake_codex output
  if [ ! -f "$smoke" ]; then
    fail 'token-free MCP smoke client exists'
    return
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/model-team-mcp.XXXXXX")"
  fake_codex="$tmp/codex"
  make_fake_codex "$fake_codex"
  output="$(python3 "$smoke" --codex-bin "$fake_codex" \
    --worker-wrapper "$wrapper" --state-dir "$tmp/state" 2>&1)"
  assert_text_contains "$output" 'codex,codex-reply' 'MCP smoke requires start and reply tools'
  rm -rf "$tmp"
}

test_worker_wrapper() {
  local wrapper="$REPO_DIR/tools/model-team/codex-worker-mcp"
  local tmp fake_codex state_dir primary_home worker_home prepared primary_hash

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-worker-mcp.XXXXXX")"
  fake_codex="$tmp/codex"
  state_dir="$tmp/state"
  primary_home="$tmp/primary-codex"
  worker_home="$tmp/worker-codex"
  worker_home="$(python3 - "$worker_home" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).absolute())
PY
)"
  mkdir -p "$primary_home"
  make_fake_codex "$fake_codex"

  cat > "$primary_home/config.toml" <<'TOML'
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
openai_base_url = "http://127.0.0.1:8787/v1"
service_tier = "fast"
personality = "pragmatic"

[mcp_servers.MCP_DOCKER]
command = "docker"
args = ["mcp", "gateway", "run"]

[plugins."sites@openai-bundled"]
enabled = true

[marketplaces.personal]
source = "sentinel"

[hooks]
TOML
  printf '%s\n' 'credential-sentinel' > "$primary_home/auth.json"
  primary_hash="$(hash_file "$primary_home/config.toml")"

  prepared="$(MODEL_TEAM_PRIMARY_CODEX_HOME="$primary_home" \
    MODEL_TEAM_CODEX_HOME="$worker_home" \
    "$wrapper" --codex-bin "$fake_codex" --state-dir "$state_dir" --prepare-only 2>&1)"
  assert_eq "$worker_home" "$prepared" 'worker wrapper prepares the configured isolated Codex home'
  if python3 - "$primary_home" "$worker_home" "$primary_hash" <<'PY'
import hashlib
from pathlib import Path
import sys
import tomllib

primary = Path(sys.argv[1])
worker = Path(sys.argv[2])
expected_hash = sys.argv[3]
config = tomllib.loads((worker / "config.toml").read_text())
assert config == {
    "model": "gpt-5.6-sol",
    "model_reasoning_effort": "high",
    "openai_base_url": "http://127.0.0.1:8787/v1",
    "service_tier": "fast",
    "personality": "pragmatic",
    "sandbox_mode": "danger-full-access",
    "approval_policy": "never",
}
assert (worker / "auth.json").is_symlink()
assert (worker / "auth.json").resolve() == (primary / "auth.json").resolve()
assert hashlib.sha256((primary / "config.toml").read_bytes()).hexdigest() == expected_hash
assert not any((worker / name).exists() for name in ("plugins", "skills", "hooks.json"))
instructions = (worker / "AGENTS.md").read_text()
assert "Never invoke another model-team" in instructions
assert "Never commit or push" in instructions
assert "Do not access Jira" in instructions
PY
  then
    pass 'worker home preserves routing and login without inheriting MCPs or plugins'
  else
    fail 'worker home preserves routing and login without inheriting MCPs or plugins'
  fi

  if FAKE_CODEX_DELAY=0.25 MODEL_TEAM_PRIMARY_CODEX_HOME="$primary_home" \
    MODEL_TEAM_CODEX_HOME="$worker_home" FAKE_CODEX_CAPTURE="$tmp/codex-capture.json" \
    python3 - "$wrapper" "$fake_codex" "$state_dir" "$worker_home" "$tmp/codex-capture.json" <<'PY'
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time

wrapper, codex_bin, state_dir, worker_home, capture = sys.argv[1:]
process = subprocess.Popen(
    [sys.executable, wrapper, "--codex-bin", codex_bin, "--state-dir", state_dir],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    env=os.environ.copy(),
)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)

def send(message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

def receive(request_id, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        events = selector.select(deadline - time.monotonic())
        if not events:
            break
        message = json.loads(process.stdout.readline())
        if message.get("id") == request_id:
            return message
    raise AssertionError(f"response {request_id} not received")

def state_file():
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        files = list(Path(state_dir).glob("*.json"))
        if files:
            return files[0]
        time.sleep(0.01)
    raise AssertionError("worker state file not created")

def wait_state(predicate):
    path = state_file()
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            data = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.01)
            continue
        if predicate(data):
            return data
        time.sleep(0.01)
    raise AssertionError(f"worker state did not converge: {data}")

try:
    ready = wait_state(lambda data: data.get("status") == "ready")
    assert ready["server_pid"] == process.pid
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and not Path(capture).exists():
        time.sleep(0.01)
    child = json.loads(Path(capture).read_text())
    assert child["codex_home"] == worker_home
    assert child["argv"] == ["mcp-server"]

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    receive(1)
    send({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "codex",
            "arguments": {
                "prompt": "private task text",
                "model": "gpt-5.6-sol",
                "cwd": "/tmp/repository",
                "sandbox": "danger-full-access",
            },
        },
    })
    active = wait_state(lambda data: data.get("status") == "active")
    assert len(active["active_calls"]) == 1
    call = active["active_calls"][0]
    assert call["tool"] == "codex"
    assert call["model"] == "gpt-5.6-sol"
    assert call["cwd"] == "/tmp/repository"
    assert "private task text" not in json.dumps(active)

    receive(2)
    idle = wait_state(lambda data: data.get("status") == "idle")
    assert idle["active_calls"] == []
    assert idle["latest"]["status"] == "passed"
    assert idle["latest"]["tool"] == "codex"
    assert idle["latest"]["latency_ms"] >= 0
finally:
    selector.close()
    process.terminate()
    process.wait(timeout=2)

deadline = time.monotonic() + 2
while time.monotonic() < deadline and list(Path(state_dir).glob("*.json")):
    time.sleep(0.01)
assert not list(Path(state_dir).glob("*.json")), "worker state survived a clean shutdown"

failed_state_dir = Path(state_dir).parent / "failed-state"
failed = subprocess.run(
    [sys.executable, wrapper, "--codex-bin", str(Path(state_dir).parent / "missing-codex"),
     "--state-dir", str(failed_state_dir)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    timeout=2,
    check=False,
)
assert failed.returncode != 0
assert not list(failed_state_dir.glob("*.json")), "failed startup left stale worker state"
PY
  then
    pass 'Codex MCP wrapper tracks only real calls and removes cleanly terminated state'
  else
    fail 'Codex MCP wrapper tracks only real calls and removes cleanly terminated state'
  fi

  if MODEL_TEAM_PRIMARY_CODEX_HOME="$primary_home" XDG_STATE_HOME="$tmp/per-process-state" \
      python3 - "$wrapper" "$fake_codex" <<'PY'
import subprocess
import sys

wrapper, codex_bin = sys.argv[1:]
first = subprocess.check_output(
    [sys.executable, wrapper, "--codex-bin", codex_bin, "--prepare-only"], text=True
).strip()
second = subprocess.check_output(
    [sys.executable, wrapper, "--codex-bin", codex_bin, "--prepare-only"], text=True
).strip()
assert first != second, (first, second)
PY
  then
    pass 'default Codex worker homes are isolated per process'
  else
    fail 'default Codex worker homes are shared across processes'
  fi
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
  mkdir -p "$home/.codex" "$fake_bin"
  printf '%s\n' 'model = "gpt-5.6-sol"' > "$home/.codex/config.toml"
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
  output="$(HOME="$home" CLAUDE_DIR="$home/.claude" CODEX_HOME="$home/.codex" CLAUDE_CONFIG_FILE="$config" \
    CLAUDE_SETTINGS_LOCAL_FILE="$settings" CODEX_BIN="$fake_codex" \
    CODEX_PYTHON_BIN="$python_bin" \
    PATH="$fake_bin:/usr/bin:/bin" "$doctor" 2>&1)"
  assert_text_contains "$output" 'PASS model-team skill installed' 'doctor checks model-team skill'
  assert_text_contains "$output" 'PASS Fable architect agent installed' 'doctor checks the Fable architect agent'
  assert_text_contains "$output" 'PASS Codex worker default model is gpt-5.6-sol' 'doctor reports the configured worker model'
  assert_text_contains "$output" 'PASS jira-live skill installed' 'doctor checks Jira skill'
  assert_text_contains "$output" 'PASS codex-worker MCP registration uses the isolated wrapper' 'doctor checks worker isolation'
  assert_text_contains "$output" 'PASS Codex worker has zero inner MCP servers' 'doctor verifies the effective worker MCP surface'
  assert_text_contains "$output" 'PASS Codex worker permissions are installed' 'doctor checks worker permissions'
  assert_text_contains "$output" 'PASS Headroom proxy is healthy' 'doctor checks Headroom health'
  assert_text_contains "$output" 'PASS Mempalace CLI and MCP are available' 'doctor checks Mempalace availability'
  assert_text_contains "$output" 'PASS Codex MCP exposes codex and codex-reply' 'doctor runs token-free MCP handshake'
  assert_text_contains "$output" 'PASS model-team-watch is installed' 'doctor checks watcher installation'
  assert_text_contains "$output" 'PASS instrumented Codex MCP wrapper is installed' 'doctor checks worker instrumentation'
  rm -rf "$tmp"
}

test_watchers() {
  local watcher="$REPO_DIR/tools/model-team/model-team-watch"
  local headroom_watcher="$REPO_DIR/tools/headroom/headroom-watch"
  local tmp stats health processes repo state worker_state_dir output json_output

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/model-team-watch.XXXXXX")"
  stats="$tmp/stats.json"
  health="$tmp/health.json"
  processes="$tmp/processes.txt"
  state="$tmp/model-team-state.json"
  worker_state_dir="$tmp/workers"
  repo="$tmp/repo"
  mkdir -p "$repo" "$worker_state_dir"
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
    {"request_id":"codex-2","timestamp":"2026-07-15T12:00:51.000000","model":"gpt-5.6-sol","total_latency_ms":10307,"tags":{"client":"codex"}},
    {"request_id":"desktop-noise","timestamp":"2026-07-15T12:01:10.000000","model":"gpt-5.6-noise","total_latency_ms":2500,"tags":{"client":"codex"}}
  ]
}
JSON
  printf '{"status":"healthy","ready":true,"uptime_seconds":600}\n' > "$health"
  printf '38295 08:24 /usr/bin/python3 /home/user/.local/bin/codex-worker-mcp --codex-bin /opt/codex\n' > "$processes"
  cat > "$worker_state_dir/38295.json" <<'JSON'
{
  "server_pid": 38295,
  "server_started_at": "2026-07-15T11:50:00Z",
  "status": "idle",
  "active_calls": [],
  "latest": {
    "request_id": "2",
    "tool": "codex",
    "model": "gpt-5.6-sol",
    "cwd": "/tmp/repository",
    "sandbox": "danger-full-access",
    "started_at": "2026-07-15T12:00:40Z",
    "completed_at": "2026-07-15T12:00:51Z",
    "latency_ms": 10307,
    "status": "passed"
  },
  "updated_at": "2026-07-15T12:00:51Z"
}
JSON

  MODEL_TEAM_STATE_FILE="$state" "$watcher" --mark implementation \
    --actor codex-worker --task task-1 >/dev/null

  if MODEL_TEAM_STATE_DIR="$tmp/runs" MODEL_TEAM_RUN_ID=run-a "$watcher" --mark planning \
      && MODEL_TEAM_STATE_DIR="$tmp/runs" MODEL_TEAM_RUN_ID=run-b "$watcher" --mark review \
      && [ -f "$tmp/runs/run-a.json" ] && [ -f "$tmp/runs/run-b.json" ]; then
    pass 'watcher keeps concurrent orchestration runs separate'
  else
    fail 'watcher overwrites concurrent orchestration runs'
  fi

  if [ -x "$watcher" ]; then
    output="$(MODEL_TEAM_STATS_FILE="$stats" MODEL_TEAM_HEALTH_FILE="$health" \
      MODEL_TEAM_PS_FILE="$processes" MODEL_TEAM_STATE_FILE="$state" \
      MODEL_TEAM_WORKER_STATE_DIR="$worker_state_dir" \
      "$watcher" --once --repo "$repo" 2>&1)"
    assert_text_contains "$output" 'codex-worker  IDLE' 'watcher distinguishes an idle worker from availability'
    assert_text_contains "$output" 'last worker call' 'watcher labels completed worker activity precisely'
    assert_text_contains "$output" 'gpt-5.6-sol' 'watcher reports the actual worker model'
    assert_text_contains "$output" '12:00:51' 'watcher reports the completed worker request time'
    assert_text_not_contains "$output" 'gpt-5.6-noise' 'watcher ignores ordinary Codex Desktop traffic'
    assert_text_not_contains "$output" 'requests/5m' 'watcher does not present stale machine traffic as worker activity'
    assert_text_contains "$output" 'changed files  1' 'watcher reports repository changes'
    assert_text_contains "$output" 'implementation · codex-worker · task-1' 'watcher reports the active orchestration phase'

    json_output="$(MODEL_TEAM_STATS_FILE="$stats" MODEL_TEAM_HEALTH_FILE="$health" \
      MODEL_TEAM_PS_FILE="$processes" MODEL_TEAM_STATE_FILE="$state" \
      MODEL_TEAM_WORKER_STATE_DIR="$worker_state_dir" \
      "$watcher" --json --repo "$repo" 2>&1)"
    if printf '%s' "$json_output" | jq -e '
      .worker.available == true and .worker.status == "idle" and
      .worker.server_count == 1 and .worker.servers[0].pid == 38295 and
      .worker.latest.model == "gpt-5.6-sol" and
      .worker.latest.status == "passed" and .activity == null and
      .repository.changed_files == 1 and
      .orchestration.phase == "implementation" and
      .orchestration.actor == "codex-worker" and .orchestration.task == "task-1" and
      .headroom.healthy == true' >/dev/null 2>&1; then
      pass 'watcher JSON exposes verified worker-only activity, repo, and health state'
    else
      fail 'watcher JSON exposes verified worker-only activity, repo, and health state'
    fi

    jq '.status = "active" | .active_calls = [{
      "request_id":"3", "tool":"codex-reply", "model":"gpt-5.6-sol",
      "cwd":"/tmp/repository", "sandbox":"danger-full-access",
      "started_at":"2026-07-15T12:02:00Z"
    }]' "$worker_state_dir/38295.json" > "$worker_state_dir/active.json"
    mv "$worker_state_dir/active.json" "$worker_state_dir/38295.json"
    output="$(MODEL_TEAM_HEALTH_FILE="$health" MODEL_TEAM_PS_FILE="$processes" \
      MODEL_TEAM_STATE_FILE="$state" MODEL_TEAM_WORKER_STATE_DIR="$worker_state_dir" \
      "$watcher" --once --repo "$repo" 2>&1)"
    assert_text_contains "$output" 'codex-worker  ACTIVE' 'watcher reports a real in-flight worker call as active'
    assert_text_contains "$output" 'active call' 'watcher shows the active worker call separately'
    assert_text_contains "$output" 'codex-reply' 'watcher identifies the active worker tool'

    : > "$processes"
    output="$(MODEL_TEAM_HEALTH_FILE="$health" MODEL_TEAM_PS_FILE="$processes" \
      MODEL_TEAM_STATE_FILE="$state" MODEL_TEAM_WORKER_STATE_DIR="$worker_state_dir" \
      "$watcher" --once --repo "$repo" 2>&1)"
    assert_text_contains "$output" 'codex-worker  DOWN' 'watcher rejects stale active state when its server process is gone'
    assert_text_not_contains "$output" 'active call' 'watcher hides calls from stale worker state'

    printf '38295 08:24 /usr/bin/python3 /home/user/.local/bin/codex-worker-mcp --codex-bin /opt/codex\n' > "$processes"
    if MODEL_TEAM_STATS_FILE="$stats" MODEL_TEAM_HEALTH_FILE="$health" \
      MODEL_TEAM_PS_FILE="$processes" MODEL_TEAM_STATE_FILE="$state" \
      MODEL_TEAM_WORKER_STATE_DIR="$worker_state_dir" MODEL_TEAM_MAX_REFRESHES=2 \
      python3 - "$watcher" "$repo" <<'PY'
import os
import subprocess
import sys

watcher, repo = sys.argv[1:]
process = subprocess.run(
    [watcher, "--repo", repo, "--interval", "0"],
    env=os.environ.copy(),
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    timeout=3,
    check=False,
)
output = process.stdout
assert process.returncode == 0, output.decode(errors="replace")
assert output.count(b"\x1b[2J") == 1, output
assert output.count(b"\x1b[H") >= 2, output
PY
    then
      pass 'live watcher buffers each frame and clears the screen only once'
    else
      fail 'live watcher buffers each frame and clears the screen only once'
    fi
  else
    fail 'watcher distinguishes an idle worker from availability'
    fail 'watcher reports the actual worker model'
    fail 'watcher ignores ordinary Codex Desktop traffic'
    fail 'watcher reports repository changes'
    fail 'watcher JSON exposes verified worker-only activity, repo, and health state'
    fail 'live watcher buffers each frame and clears the screen only once'
  fi

  output="$(HEADROOM_STATS_FILE="$stats" HEADROOM_HEALTH_FILE="$health" \
    "$headroom_watcher" --once 2>&1)"
  assert_text_contains "$output" 'latest gpt-5.6-noise' 'headroom watcher remains the machine-wide model view'
  assert_text_contains "$output" 'client codex' 'headroom watcher shows latest observed client'
  assert_text_contains "$output" '12:01:10' 'headroom watcher shows latest observed request time'
  rm -rf "$tmp"
}

usage() {
  printf 'Usage: %s {sources|installer|protocol|worker|doctor|watchers|all}\n' "$0" >&2
}

group="${1:-all}"
case "$group" in
  sources) test_sources ;;
  installer) test_installer ;;
  protocol) test_protocol ;;
  worker) test_worker_wrapper ;;
  doctor) test_doctor ;;
  watchers) test_watchers ;;
  all)
    test_sources
    test_installer
    test_protocol
    test_worker_wrapper
    test_doctor
    test_watchers
    ;;
  *) usage; exit 2 ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi
