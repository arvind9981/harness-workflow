#!/usr/bin/env bash

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/codex/lib.sh
. "$REPO_DIR/tools/codex/lib.sh"
TEST_PYTHON="$(codex_python_resolve || true)"
FAILURES=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then pass "$label"; else fail "$label"; fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then fail "$label"; else pass "$label"; fi
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
  if printf '%s\n' "$text" | grep -Fq "$needle"; then pass "$label"; else fail "$label"; fi
}

assert_repo_not_contains() {
  local needle="$1" label="$2"
  if rg -l -F --hidden --glob '!.git/**' -- "$needle" "$REPO_DIR" >/dev/null; then
    fail "$label"
  else
    pass "$label"
  fi
}

detect_platform() {
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@" bash -c '
    source "$1"
    codex_detect_platform || exit $?
    printf "%s|%s|%s\n" "$PLATFORM_OS" "$IS_WSL" "$WSL_DISTRO"
  ' _ "$REPO_DIR/tools/codex/platform.sh"
}

test_platform() {
  local kernel output rc

  assert_eq 'Linux|0|' \
    "$(detect_platform INIT_UNAME_S=Linux INIT_PROC_VERSION=Linux INIT_WSL_INTEROP=0)" \
    'platform detects native Linux'
  assert_eq 'Darwin|0|' \
    "$(detect_platform INIT_UNAME_S=Darwin INIT_PROC_VERSION=Darwin INIT_WSL_INTEROP=0)" \
    'platform detects macOS'
  assert_eq 'Linux|1|Ubuntu' \
    "$(detect_platform INIT_UNAME_S=Linux INIT_PROC_VERSION=Linux INIT_WSL_INTEROP=0 WSL_DISTRO_NAME=Ubuntu)" \
    'platform detects WSL from its distro name'
  assert_eq 'Linux|1|' \
    "$(detect_platform INIT_UNAME_S=Linux INIT_PROC_VERSION='Linux Microsoft WSL2' INIT_WSL_INTEROP=0)" \
    'platform detects WSL from the kernel version'
  assert_eq 'Linux|1|archlinux' \
    "$(detect_platform INIT_UNAME_S=Linux INIT_PROC_VERSION='Linux Microsoft WSL2' INIT_WSL_INTEROP=0 CODEX_WSL_DISTRO=archlinux)" \
    'platform honors an explicit WSL distro'

  for kernel in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0 FreeBSD; do
    if detect_platform INIT_UNAME_S="$kernel" INIT_PROC_VERSION="$kernel" \
        INIT_WSL_INTEROP=0 >/dev/null 2>&1; then
      fail "platform rejects $kernel"
    else
      pass "platform rejects $kernel"
    fi
  done

  output="$(INIT_UNAME_S=MINGW64_NT-10.0 INIT_PROC_VERSION=MINGW \
    INIT_WSL_INTEROP=0 "$REPO_DIR/init.sh" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass 'init rejects native Windows shells'
  else
    fail 'init rejects native Windows shells'
  fi
  assert_text_contains "$output" \
    'native Windows shells are unsupported; run init.sh inside WSL' \
    'init explains that Windows users must use WSL'
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    cksum "$1" | awk '{print $1 ":" $2}'
  fi
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

test_instructions() {
  local agents="$REPO_DIR/codex/AGENTS.md"
  local legacy_cli="gpt""-toggle"
  local legacy_label="ChatGPT"" toggle"
  local bridge_binary="claude-code""-proxy"
  local legacy_dir="$REPO_DIR/tools/chatgpt""-toggle"
  assert_file_contains "$agents" 'Make reasonable, reversible assumptions and proceed without asking.' 'AGENTS defaults to autonomous progress'
  assert_file_contains "$agents" 'Ask only when the missing decision would materially change the outcome' 'AGENTS limits clarification to material decisions'
  assert_file_not_contains "$agents" 'Ask one focused question when scope is ambiguous' 'AGENTS removes routine clarification prompts'
  assert_file_not_contains "$agents" 'Get explicit approval before additive changes' 'AGENTS removes redundant implementation approval'
  assert_file_not_contains "$agents" '## Jira' 'AGENTS leaves Jira policy to the on-demand skill'
  assert_file_not_contains "$agents" 'Transport closed' 'AGENTS does not carry Jira recovery details'
  assert_file_contains "$REPO_DIR/workflow/skills/jira-live/SKILL.md" 'MCP_DOCKER' 'Jira skill requires live MCP_DOCKER'
  assert_file_contains "$REPO_DIR/workflow/skills/jira-live/SKILL.md" 'Transport closed' 'Jira skill owns transport recovery'
  assert_file_contains "$REPO_DIR/workflow/skills/jira-live/SKILL.md" 'Never automatically replay a Jira write' 'Jira skill protects ambiguous writes'
  assert_file_contains "$agents" 'Use mempalace when the request depends on prior work, decisions, or repo conventions.' 'AGENTS scopes memory recall to relevant tasks'
  assert_file_not_contains "$agents" 'Use mempalace before re-deriving past work' 'AGENTS removes unconditional memory recall'
  assert_file_contains "$agents" 'references/memory-tooling.md' 'AGENTS routes deep memory mechanics to the reference'
  assert_file_contains "$agents" '<!-- BEGIN @agent-native/skills -->' 'AGENTS retains the managed skill marker'
  assert_file_contains "$agents" 'use /efficient-frontier only when' 'AGENTS scopes efficient-frontier to worthwhile delegation'
  assert_file_contains "$agents" 'Keep single-file and latency-sensitive work inline.' 'AGENTS keeps small work on the fast path'
  assert_file_not_contains "$agents" 'use the /efficient-frontier skill always.' 'AGENTS removes unconditional frontier delegation'
  if [ -f "$REPO_DIR/codex/references/memory-tooling.md" ]; then
    pass 'memory-tooling reference is repository-owned'
  else
    fail 'memory-tooling reference is repository-owned'
  fi
  assert_repo_not_contains "$legacy_cli" 'legacy model bridge CLI is absent from the repository'
  assert_repo_not_contains "$legacy_label" 'legacy model bridge documentation is absent from the repository'
  assert_repo_not_contains "$bridge_binary" 'legacy third-party bridge dependency is absent from the repository'
  if [ -e "$legacy_dir" ]; then
    fail 'legacy model bridge tools are removed'
  else
    pass 'legacy model bridge tools are removed'
  fi
}

make_executable() {
  local path="$1"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$path"
  chmod +x "$path"
}

test_discovery() {
  local lib="$REPO_DIR/tools/codex/lib.sh"
  if [ ! -f "$lib" ]; then
    fail 'Codex discovery helper exists'
    return
  fi

  # shellcheck source=tools/codex/lib.sh
  . "$lib"

  local tmp path_bin explicit_bin app_bin actual
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-discovery.XXXXXX")"
  path_bin="$tmp/path/codex"
  explicit_bin="$tmp/explicit-codex"
  app_bin="$tmp/app-codex"
  mkdir -p "$tmp/path"
  make_executable "$path_bin"
  make_executable "$explicit_bin"
  make_executable "$app_bin"

  actual="$(PATH="$tmp/path:/usr/bin:/bin" CODEX_BIN="$explicit_bin" CODEX_APP_BUNDLE_PATHS="$app_bin" codex_resolve_bin)"
  assert_eq "$path_bin" "$actual" 'PATH Codex takes precedence'

  actual="$(PATH="/usr/bin:/bin" CODEX_BIN="$explicit_bin" CODEX_APP_BUNDLE_PATHS="$app_bin" codex_resolve_bin)"
  assert_eq "$explicit_bin" "$actual" 'explicit CODEX_BIN is the second choice'

  actual="$(PATH="/usr/bin:/bin" CODEX_BIN="" CODEX_APP_BUNDLE_PATHS="$app_bin" codex_resolve_bin)"
  assert_eq "$app_bin" "$actual" 'macOS app bundle is the final choice'

  rm -rf "$tmp"
}

test_installer() {
  local tmp home codex_dir config first_config_hash first_hooks_hash first_backups
  local second_config_hash second_hooks_hash second_backups config_backup fresh_dir
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-installer.XXXXXX")"
  home="$tmp/home"
  codex_dir="$tmp/codex"
  config="$codex_dir/config.toml"
  mkdir -p "$home" "$codex_dir" "$tmp/bin"

  cat > "$config" <<'EOF'
# preserve-this-comment
sandbox_mode = "danger-full-access"

[mcp_servers.MCP_DOCKER] # gateway
command = "docker"
args = ["mcp", "gateway", "run", "--profile", "xebia"]
startup_timeout_sec	=	10

[plugins.sentinel] # preserve
enabled = true

[shell_environment_policy] # preserve
inherit = "all"

[shell_environment_policy.set] # preserve
KEEP = "yes"
EOF
  chmod 600 "$config"

  if HOME="$home" CODEX_DIR="$codex_dir" BIN_DIR="$tmp/bin" \
      "$REPO_DIR/tools/codex/install-codex.sh" >/dev/null; then
    pass 'installer completes in an isolated Codex directory'
  else
    fail 'installer completes in an isolated Codex directory'
    rm -rf "$tmp"
    return
  fi

  if "$TEST_PYTHON" - "$config" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    config = tomllib.load(fh)

assert config["sandbox_mode"] == "danger-full-access"
docker = config["mcp_servers"]["MCP_DOCKER"]
assert docker["command"] == "docker"
assert docker["args"] == ["mcp", "gateway", "run", "--profile", "xebia"]
assert docker["startup_timeout_sec"] == 60
assert config["plugins"]["sentinel"]["enabled"] is True
assert config["shell_environment_policy"]["inherit"] == "all"
assert config["shell_environment_policy"]["set"]["KEEP"] == "yes"
PY
  then
    pass 'installer preserves access and unrelated TOML while setting MCP timeout'
  else
    fail 'installer preserves access and unrelated TOML while setting MCP timeout'
  fi

  if grep -Fq '# preserve-this-comment' "$config"; then
    pass 'installer preserves unrelated TOML comments'
  else
    fail 'installer preserves unrelated TOML comments'
  fi
  assert_eq 600 "$(file_mode "$config")" 'installer keeps config.toml private'

  config_backup="$(find "$codex_dir" -maxdepth 1 -type f -name 'config.toml.bak-codex-*' | head -n 1)"
  if [ -n "$config_backup" ]; then
    assert_eq 600 "$(file_mode "$config_backup")" 'config backup preserves private permissions'
  else
    fail 'config backup preserves private permissions'
  fi
  if [ -f "$codex_dir/references/memory-tooling.md" ]; then
    pass 'installer deploys the referenced memory tooling guide'
  else
    fail 'installer deploys the referenced memory tooling guide'
  fi

  first_config_hash="$(hash_file "$config")"
  first_hooks_hash="$(hash_file "$codex_dir/hooks.json")"
  first_backups="$(find "$codex_dir" -type f -name '*.bak-codex-*' | wc -l | tr -d ' ')"
  HOME="$home" CODEX_DIR="$codex_dir" BIN_DIR="$tmp/bin" \
    "$REPO_DIR/tools/codex/install-codex.sh" >/dev/null
  second_config_hash="$(hash_file "$config")"
  second_hooks_hash="$(hash_file "$codex_dir/hooks.json")"
  second_backups="$(find "$codex_dir" -type f -name '*.bak-codex-*' | wc -l | tr -d ' ')"

  assert_eq "$first_config_hash" "$second_config_hash" 'second installer run preserves config hash'
  assert_eq "$first_hooks_hash" "$second_hooks_hash" 'second installer run preserves managed-file hash'
  assert_eq "$first_backups" "$second_backups" 'second installer run creates no backups'

  fresh_dir="$tmp/fresh-codex"
  HOME="$home" CODEX_DIR="$fresh_dir" BIN_DIR="$tmp/bin" \
    "$REPO_DIR/tools/codex/install-codex.sh" >/dev/null 2>&1
  assert_eq 600 "$(file_mode "$fresh_dir/config.toml")" 'fresh config.toml is created private'

  rm -rf "$tmp"
}

test_hooks() {
  local tmp fake_bin log repo_one repo_two hook_output count_one count_two attempt
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-hooks.XXXXXX")"
  fake_bin="$tmp/bin"
  log="$tmp/calls.log"
  repo_one="$tmp/repo-one"
  repo_two="$tmp/repo-two"
  mkdir -p "$fake_bin" "$tmp/home/.local/bin" "$tmp/home/.mempalace/palace" \
    "$repo_one/graphify-out" "$repo_two/graphify-out"
  : > "$tmp/home/.mempalace/palace/chroma.sqlite3"
  : > "$repo_one/graphify-out/graph.json"
  : > "$repo_two/graphify-out/graph.json"
  : > "$log"
  repo_one="$(cd "$repo_one" && pwd -P)"
  repo_two="$(cd "$repo_two" && pwd -P)"

cat > "$fake_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "${PGREP_LIVE:-1}" = 1 ]
EOF
  cat > "$fake_bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
"$@"
EOF
  cat > "$fake_bin/sqlite3" <<'EOF'
#!/usr/bin/env bash
printf 'sqlite3 %s\n' "$*" >> "$TEST_LOG"
case "$*" in
  *'PRAGMA quick_check'*) printf 'fts corruption\n' ;;
esac
EOF
  cat > "$tmp/home/.local/bin/mempalace" <<'EOF'
#!/usr/bin/env bash
printf 'mempalace %s\n' "$*" >> "$TEST_LOG"
case "${1:-}" in
  search) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$fake_bin/pgrep" "$fake_bin/timeout" "$fake_bin/sqlite3" \
    "$tmp/home/.local/bin/mempalace"

  HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" \
    MEMPALACE_HEALTH_THROTTLE=0 MEMPALACE_SNAPSHOT_THROTTLE=999999999 \
    "$REPO_DIR/workflow/hooks/mempalace-health-deep.sh"
  if grep -Eq 'repair --mode from-sqlite|INSERT INTO embedding_fulltext_search' "$log"; then
    fail 'live mempalace MCP prevents FTS rebuild and from-sqlite repair'
  else
    pass 'live mempalace MCP prevents FTS rebuild and from-sqlite repair'
  fi

  : > "$log"
  HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" PGREP_LIVE=0 \
    MEMPALACE_HEALTH_THROTTLE=0 MEMPALACE_SNAPSHOT_THROTTLE=999999999 \
    "$REPO_DIR/workflow/hooks/mempalace-health-deep.sh"
  if grep -Fq 'repair --mode from-sqlite' "$log"; then
    fail 'session hook never starts an automatic from-sqlite repair'
  else
    pass 'session hook never starts an automatic from-sqlite repair'
  fi

  : > "$log"
  cat > "$fake_bin/graphify" <<'EOF'
#!/usr/bin/env bash
last=''
for arg in "$@"; do last="$arg"; done
printf '%s\n' "$last" >> "$TEST_LOG"
sleep 0.25
EOF
  chmod +x "$fake_bin/graphify"

  printf '{"cwd":"%s"}\n' "$repo_one" | \
    HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" GRAPHIFY_BIN="$fake_bin/graphify" \
    "$REPO_DIR/workflow/hooks/graphify-autoupdate.sh"
  printf '{"cwd":"%s"}\n' "$repo_one" | \
    HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" GRAPHIFY_BIN="$fake_bin/graphify" \
    "$REPO_DIR/workflow/hooks/graphify-autoupdate.sh"
  printf '{"cwd":"%s"}\n' "$repo_two" | \
    HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" GRAPHIFY_BIN="$fake_bin/graphify" \
    "$REPO_DIR/workflow/hooks/graphify-autoupdate.sh"

  count_one=0
  count_two=0
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    count_one="$(grep -Fxc "$repo_one" "$log" 2>/dev/null || true)"
    count_two="$(grep -Fxc "$repo_two" "$log" 2>/dev/null || true)"
    if [ "$count_one" -ge 2 ] && [ "$count_two" -ge 1 ]; then break; fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$count_one" -ge 2 ]; then
    pass 'rapid same-repo edits trigger a follow-up Graphify update'
  else
    fail 'rapid same-repo edits trigger a follow-up Graphify update'
  fi
  if [ "$count_two" -ge 1 ]; then
    pass 'Graphify coordination is repository-scoped'
  else
    fail 'Graphify coordination is repository-scoped'
  fi

  previous_two="$count_two"
  (cd "$repo_two" && printf '{}\n' | \
    HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" GRAPHIFY_BIN="$fake_bin/graphify" \
    "$REPO_DIR/workflow/hooks/graphify-autoupdate.sh")
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    count_two="$(grep -Fxc "$repo_two" "$log" 2>/dev/null || true)"
    [ "$count_two" -gt "$previous_two" ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$count_two" -gt "$previous_two" ]; then
    pass 'Graphify falls back to process CWD when payload cwd is absent'
  else
    fail 'Graphify falls back to process CWD when payload cwd is absent'
  fi

  previous_one="$count_one"
  mkdir -p "$repo_one/graphify-out/.codex-update.lock"
  printf '999999\n' > "$repo_one/graphify-out/.codex-update.lock/pid"
  printf '{"cwd":"%s"}\n' "$repo_one" | \
    HOME="$tmp/home" PATH="$fake_bin:/usr/bin:/bin" TEST_LOG="$log" GRAPHIFY_BIN="$fake_bin/graphify" \
    "$REPO_DIR/workflow/hooks/graphify-autoupdate.sh"
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    count_one="$(grep -Fxc "$repo_one" "$log" 2>/dev/null || true)"
    [ "$count_one" -gt "$previous_one" ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [ "$count_one" -gt "$previous_one" ]; then
    pass 'Graphify recovers a stale repository lock'
  else
    fail 'Graphify recovers a stale repository lock'
  fi

  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$fake_bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
  chmod +x "$fake_bin/curl" "$fake_bin/jq"
  hook_output="$(HOME="$tmp/home" USER=tester PATH="$fake_bin:/usr/bin:/bin" \
    "$REPO_DIR/workflow/hooks/headroom-health.sh")"
  if printf '%s' "$hook_output" | grep -Fq 'Claude Code'; then
    fail 'headroom health message is agent-neutral'
  else
    pass 'headroom health message is agent-neutral'
  fi
  if printf '%s' "$hook_output" | grep -Fq 'proxied API calls'; then
    pass 'headroom health message explains proxied API impact'
  else
    fail 'headroom health message explains proxied API impact'
  fi

  rm -rf "$tmp"
}

test_doctor() {
  local tmp home codex_dir fake_bin config output log
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-doctor.XXXXXX")"
  home="$tmp/home"
  codex_dir="$tmp/codex"
  fake_bin="$tmp/bin"
  config="$codex_dir/config.toml"
  log="$tmp/calls.log"
  mkdir -p "$home/.mempalace" "$codex_dir" "$fake_bin" "$tmp/local-bin"
  printf '%s\n' "$REPO_DIR" > "$home/.mempalace/graphify-repos.conf"
  : > "$log"

  cat > "$config" <<'EOF'
sandbox_mode = "danger-full-access"

[mcp_servers.MCP_DOCKER]
command = "docker"
args = ["mcp", "gateway", "run", "--profile", "xebia"]
startup_timeout_sec = 60

[plugins.sentinel]
enabled = true

[shell_environment_policy]
inherit = "all"
EOF
  HOME="$home" CODEX_DIR="$codex_dir" BIN_DIR="$tmp/local-bin" \
    "$REPO_DIR/tools/codex/install-codex.sh" >/dev/null

  cat > "$fake_bin/codex-explicit" <<'EOF'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$TEST_LOG"
if [ "${1:-}" = mcp ] && [ "${2:-}" = list ]; then
  printf 'MCP_DOCKER  docker  mcp gateway run --profile xebia  enabled\n'
fi
EOF
  cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$TEST_LOG"
if [ "${DOCKER_FAIL_MODE:-0}" = 1 ]; then
  printf 'xebia atlassian jira_search command failed with exit status 1\n'
  exit 1
fi
case "$*" in
  'mcp profile list') printf 'xebia\n' ;;
  'mcp profile server ls --filter profile=xebia') printf 'atlassian\n' ;;
  'mcp tools count --gateway-arg=--profile=xebia') printf '57\n' ;;
  'mcp tools ls --format=list --gateway-arg=--profile=xebia') printf 'jira_search\njira_get_issue\nconfluence_search\n' ;;
esac
EOF
  ln -s "$TEST_PYTHON" "$fake_bin/python3"
  chmod +x "$fake_bin/codex-explicit" "$fake_bin/docker"

  output="$(HOME="$home" CODEX_DIR="$codex_dir" CODEX_BIN="$fake_bin/codex-explicit" \
    CODEX_DOCTOR_RUNTIME=0 TEST_LOG="$log" PATH="$fake_bin:/usr/bin:/bin" \
    "$REPO_DIR/tools/codex/doctor-workflow.sh" 2>&1)"
  assert_text_contains "$output" 'PASS Codex executable resolved:' 'doctor resolves explicit or bundled Codex'
  assert_text_contains "$output" 'PASS MCP_DOCKER startup timeout is 60 seconds' 'doctor requires MCP_DOCKER startup headroom'
  assert_text_contains "$output" 'PASS MCP_DOCKER enabled in Codex' 'doctor checks Codex MCP enablement'
  assert_text_contains "$output" 'PASS Docker MCP profile available: xebia' 'doctor checks the configured Docker profile'
  assert_text_contains "$output" 'PASS Atlassian server enabled in profile: xebia' 'doctor checks Atlassian profile membership'
  assert_text_contains "$output" 'PASS Docker MCP gateway exposes 57 tools' 'doctor checks positive Docker tool inventory'
  assert_text_contains "$output" 'PASS Docker MCP gateway exposes Jira tools' 'doctor checks Jira tool inventory without calling Jira'
  assert_text_contains "$output" 'PASS workflow repository included in discovery' 'doctor seeds discovery with REPO_DIR'
  if printf '%s\n' "$output" | grep -Fq 'CLI drain remains fallback'; then
    fail 'doctor removes unconditional CLI-drain warning'
  else
    pass 'doctor removes unconditional CLI-drain warning'
  fi
  if grep -Eq 'jira_(search|get|create|update|delete)[[:space:]]' "$log"; then
    fail 'doctor does not invoke a Jira operation'
  else
    pass 'doctor does not invoke a Jira operation'
  fi
  failure_output="$(HOME="$home" CODEX_DIR="$codex_dir" CODEX_BIN="$fake_bin/codex-explicit" \
    CODEX_DOCTOR_RUNTIME=0 TEST_LOG="$log" DOCKER_FAIL_MODE=1 PATH="$fake_bin:/usr/bin:/bin" \
    "$REPO_DIR/tools/codex/doctor-workflow.sh" 2>&1)"
  failure_rc=$?
  if [ "$failure_rc" -ne 0 ] && printf '%s\n' "$failure_output" | grep -Fq 'FAIL Docker MCP profile lookup failed'; then
    pass 'doctor rejects failed Docker inventory commands despite misleading output'
  else
    fail 'doctor rejects failed Docker inventory commands despite misleading output'
  fi
  if [ "$FAILURES" -ne 0 ]; then
    printf '%s\n' '--- isolated doctor output ---' "$output" >&2
  fi

  rm -rf "$tmp"
}

usage() {
  printf 'Usage: %s {platform|instructions|discovery|installer|hooks|doctor|all}\n' "$0" >&2
}

group="${1:-all}"
case "$group" in
  platform) test_platform ;;
  instructions) test_instructions ;;
  discovery) test_discovery ;;
  installer) test_installer ;;
  hooks) test_hooks ;;
  doctor) test_doctor ;;
  all)
    test_platform
    test_instructions
    test_discovery
    test_installer
    test_hooks
    test_doctor
    ;;
  *) usage; exit 2 ;;
esac

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi
