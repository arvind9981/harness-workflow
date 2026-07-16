#!/usr/bin/env bash
# Check the repo-owned Codex workflow wiring and local runtime state.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/tools/codex/lib.sh"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
CONF="${GRAPHIFY_REPOS_CONF:-$HOME/.mempalace/graphify-repos.conf}"
PENDING="$HOME/.mempalace/hook_state/graphify-pending-mines"
EMBEDDER="$HOME/.mempalace/palace/mempalace_embedder.json"
RUNTIME="${CODEX_DOCTOR_RUNTIME:-1}"
DOCTOR_OS="${CODEX_DOCTOR_OS:-$(uname -s)}"
DOCTOR_ZSH="${CODEX_DOCTOR_ZSH:-/bin/zsh}"
PYTHON_BIN="$(codex_python_resolve || true)"

PASS=0
WARN=0
FAIL=0
NEXT_ACTION=""
NEED_INSTALL=0
NEED_DOCKER=0
NEED_GRAPHIFY=0

pass() {
  PASS=$((PASS + 1))
  printf 'PASS %s\n' "$1"
}

warn() {
  WARN=$((WARN + 1))
  [ -n "$NEXT_ACTION" ] || NEXT_ACTION="Review the WARN lines above; they identify the next maintenance action."
  printf 'WARN %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  NEED_INSTALL=1
  printf 'FAIL %s\n' "$1"
}

docker_warn() {
  WARN=$((WARN + 1))
  NEED_DOCKER=1
  NEXT_ACTION="Configure or repair optional Docker MCP support before using external-service workflows."
  printf 'WARN %s\n' "$1"
}

graphify_fail() {
  FAIL=$((FAIL + 1))
  NEED_GRAPHIFY=1
  printf 'FAIL %s\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run_bounded() {
  local seconds="$1"
  shift
  "$PYTHON_BIN" - "$seconds" "$@" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        sys.argv[2:],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=float(sys.argv[1]),
        check=False,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)

sys.stdout.write(result.stdout)
raise SystemExit(result.returncode)
PY
}

repo_root_of() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

discover_repos() {
  {
    repo_root_of "$REPO_DIR"
    for root in "$HOME/xebia" "$HOME/complion"; do
      [ -d "$root" ] || continue

      for child in "$root"/*; do
        [ -d "$child" ] || continue
        repo_root_of "$child"
      done
    done
  } | awk 'NF && !seen[$0]++' | sort
}

repo_list_contains() {
  local needle="$1"
  local line

  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$repos
EOF

  return 1
}

check_command() {
  if have "$1"; then
    pass "$1 available"
  else
    fail "$1 missing"
  fi
}

check_global_agents() {
  if [ ! -f "$CODEX_DIR/AGENTS.md" ]; then
    fail "$CODEX_DIR/AGENTS.md missing"
    return
  fi

  if diff -q "$REPO_DIR/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md" >/dev/null 2>&1; then
    pass "global Codex AGENTS.md matches repo source"
  else
    fail "global Codex AGENTS.md differs from repo source"
  fi
}

check_hook_installation() {
  local rendered hook src dest bad=0
  local hooks_json="$CODEX_DIR/hooks.json"

  if [ ! -f "$hooks_json" ]; then
    fail "$hooks_json missing"
    return
  fi

  rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooksjson.XXXXXX")" || {
    fail "could not create temporary hooks.json check"
    return
  }
  sed "s#__HOME__#$HOME#g" "$REPO_DIR/codex/hooks.json" > "$rendered"
  if cmp -s "$rendered" "$hooks_json"; then
    pass "installed Codex hooks.json matches repo source"
  else
    fail "installed Codex hooks.json differs from repo source"
    bad=1
  fi
  rm -f "$rendered"

  for src in "$REPO_DIR"/workflow/hooks/*.sh; do
    hook="$(basename "$src")"
    dest="$CODEX_DIR/hooks/$hook"
    if [ ! -x "$dest" ]; then
      fail "Codex hook missing or not executable: $dest"
      bad=1
    elif cmp -s "$src" "$dest"; then
      :
    else
      fail "Codex hook differs from repo source: $dest"
      bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then
    pass "all repo-owned Codex hooks are installed and executable"
  fi
}

check_fast_profile() {
  local src="$REPO_DIR/codex/fast.config.toml"
  local dest="$CODEX_DIR/fast.config.toml"

  if [ ! -f "$dest" ]; then
    fail "Codex fast profile missing: $dest"
  elif cmp -s "$src" "$dest"; then
    pass "Codex fast profile matches repo source"
  else
    fail "Codex fast profile differs from repo source"
  fi
}

check_skill_installation() {
  local src rel dest bad=0

  [ -d "$REPO_DIR/workflow/skills" ] || return
  while IFS= read -r -d '' src; do
    rel="${src#"$REPO_DIR/workflow/skills/"}"
    dest="$CODEX_DIR/skills/$rel"
    if [ ! -f "$dest" ]; then
      fail "Codex skill file missing: $dest"
      bad=1
    elif ! cmp -s "$src" "$dest"; then
      fail "Codex skill file differs from repo source: $dest"
      bad=1
    fi
  done < <(find "$REPO_DIR/workflow/skills" -type f -print0)
  if [ "$bad" -eq 0 ]; then
    pass "all shared workflow skills are installed in Codex"
  fi
}

check_codex_config() {
  local config="$CODEX_DIR/config.toml"
  local parsed key value
  local native_openai="" env_openai="" env_anthropic="" inherit=""
  MCP_COMMAND=""
  MCP_PROFILE=""
  MCP_TIMEOUT=""
  MCP_DYNAMIC=""
  MCP_PRESENT=""

  if [ ! -f "$config" ]; then
    fail "$config missing"
    return
  fi
  if [ -z "$PYTHON_BIN" ]; then
    fail "Python 3.11+ with tomllib is required for safe Codex config parsing"
    return
  fi

  parsed="$("$PYTHON_BIN" - "$config" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    config = tomllib.load(fh)

policy = config.get("shell_environment_policy", {})
env = policy.get("set", {})
docker = config.get("mcp_servers", {}).get("MCP_DOCKER", {})
args = docker.get("args", [])
profile = ""
for index, arg in enumerate(args):
    if arg == "--profile" and index + 1 < len(args):
        profile = str(args[index + 1])
        break
    if isinstance(arg, str) and arg.startswith("--profile="):
        profile = arg.split("=", 1)[1]
        break
dynamic = any(
    arg == "--tools=mcp-exec"
    or (arg == "--tools" and index + 1 < len(args) and args[index + 1] == "mcp-exec")
    for index, arg in enumerate(args)
)

safe = {
    "native_openai": config.get("openai_base_url", ""),
    "env_openai": env.get("OPENAI_BASE_URL", ""),
    "env_anthropic": env.get("ANTHROPIC_BASE_URL", ""),
    "inherit": policy.get("inherit", ""),
    "mcp_command": docker.get("command", ""),
    "mcp_profile": profile,
    "mcp_timeout": docker.get("startup_timeout_sec", ""),
    "mcp_dynamic": str(dynamic).lower(),
    "mcp_present": str(bool(docker)).lower(),
}
for key, value in safe.items():
    print(f"{key}\t{value}")
PY
)" || {
    fail "$config is not valid TOML"
    return
  }

  while IFS=$'\t' read -r key value; do
    case "$key" in
      native_openai) native_openai="$value" ;;
      env_openai) env_openai="$value" ;;
      env_anthropic) env_anthropic="$value" ;;
      inherit) inherit="$value" ;;
      mcp_command) MCP_COMMAND="$value" ;;
      mcp_profile) MCP_PROFILE="$value" ;;
      mcp_timeout) MCP_TIMEOUT="$value" ;;
      mcp_dynamic) MCP_DYNAMIC="$value" ;;
      mcp_present) MCP_PRESENT="$value" ;;
    esac
  done <<EOF
$parsed
EOF

  if [ "$native_openai" = "http://127.0.0.1:8787/v1" ]; then
    pass "Codex native openai_base_url routes through headroom"
  else
    fail "Codex native openai_base_url is not routed through headroom"
  fi

  if [ "$env_openai" = "http://127.0.0.1:8787/v1" ]; then
    pass "Codex OPENAI_BASE_URL routes through headroom"
  else
    warn "Codex OPENAI_BASE_URL not found in config env"
  fi

  if [ "$env_anthropic" = "http://127.0.0.1:8787" ]; then
    pass "Codex ANTHROPIC_BASE_URL routes through headroom"
  else
    warn "Codex ANTHROPIC_BASE_URL not found in config env"
  fi

  if [ "$inherit" = "all" ]; then
    pass "Codex shell environment inherits all variables for troubleshooting"
  else
    fail "Codex shell environment inheritance is not all"
  fi

  if [ "$MCP_PRESENT" != true ]; then
    pass "MCP_DOCKER configuration omitted (optional)"
    return
  fi

  case "$MCP_TIMEOUT" in
    ''|*[!0-9]*) fail "MCP_DOCKER startup timeout is missing or invalid" ;;
    *)
      if [ "$MCP_TIMEOUT" -ge 60 ]; then
        pass "MCP_DOCKER startup timeout is $MCP_TIMEOUT seconds"
      else
        fail "MCP_DOCKER startup timeout is below 60 seconds"
      fi
      ;;
  esac

  if [ "$MCP_DYNAMIC" = true ]; then
    pass "MCP_DOCKER uses dynamic gateway mode"
  else
    warn "MCP_DOCKER eagerly exposes its profile tool catalog"
  fi
}

check_mcp_docker() {
  local codex_bin codex_mcp profiles servers tool_count_output tool_count tools command_rc

  codex_bin="$(codex_resolve_bin || true)"
  if [ -z "$codex_bin" ]; then
    fail "Codex executable not found"
    return
  fi
  pass "Codex executable resolved: $codex_bin"

  if [ "$MCP_PRESENT" != true ]; then
    docker_warn "MCP_DOCKER is not configured (optional)"
    return
  fi

  if [ -z "$PYTHON_BIN" ]; then
    docker_warn "Python 3.11+ with tomllib is required for bounded MCP checks"
    return
  fi

  codex_mcp="$(run_bounded 20 "$codex_bin" mcp list 2>&1)"
  command_rc=$?
  if [ "$command_rc" -ne 0 ]; then
    docker_warn "Codex MCP list failed"
    return
  fi
  if printf '%s\n' "$codex_mcp" | grep -F 'MCP_DOCKER' | grep -Eqi 'enabled|true'; then
    pass "MCP_DOCKER enabled in Codex"
  else
    docker_warn "MCP_DOCKER is not enabled in Codex"
    return
  fi

  if [ "$MCP_COMMAND" != "docker" ]; then
    docker_warn "MCP_DOCKER command is not docker"
    return
  fi
  if [ -z "$MCP_PROFILE" ]; then
    docker_warn "MCP_DOCKER has no configured profile"
    return
  fi
  if ! have docker; then
    docker_warn "docker missing"
    return
  fi

  profiles="$(run_bounded 20 docker mcp profile list 2>&1)"
  command_rc=$?
  if [ "$command_rc" -ne 0 ]; then
    docker_warn "Docker MCP profile lookup failed"
    return
  fi
  if printf '%s\n' "$profiles" | grep -Fq "$MCP_PROFILE"; then
    pass "Docker MCP profile available: $MCP_PROFILE"
  else
    docker_warn "Docker MCP profile unavailable: $MCP_PROFILE"
    return
  fi

  servers="$(run_bounded 20 docker mcp profile server ls --filter "profile=$MCP_PROFILE" 2>&1)"
  command_rc=$?
  if [ "$command_rc" -ne 0 ]; then
    docker_warn "Docker MCP server lookup failed"
    return
  fi
  if printf '%s\n' "$servers" | grep -Eq '[^[:space:]]'; then
    pass "Docker MCP profile has enabled servers: $MCP_PROFILE"
  else
    docker_warn "Docker MCP profile has no enabled servers: $MCP_PROFILE"
    return
  fi

  tool_count_output="$(run_bounded 30 docker mcp tools count \
    "--gateway-arg=--profile=$MCP_PROFILE" "--gateway-arg=--tools=mcp-exec" 2>&1)"
  command_rc=$?
  if [ "$command_rc" -ne 0 ]; then
    docker_warn "Docker MCP tool count failed"
    return
  fi
  tool_count="$(printf '%s\n' "$tool_count_output" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"
  case "$tool_count" in
    ''|0|*[!0-9]*) docker_warn "Docker MCP dynamic gateway returned no management tools" ;;
    *) pass "Docker MCP dynamic gateway exposes $tool_count management tools" ;;
  esac

  tools="$(run_bounded 30 docker mcp tools ls --format=list \
    "--gateway-arg=--profile=$MCP_PROFILE" "--gateway-arg=--tools=mcp-exec" 2>&1)"
  command_rc=$?
  if [ "$command_rc" -ne 0 ]; then
    docker_warn "Docker MCP tool listing failed"
    return
  fi
  if printf '%s\n' "$tools" | grep -Fq 'mcp-exec'; then
    pass "Docker MCP dynamic gateway includes mcp-exec"
  else
    docker_warn "Docker MCP dynamic gateway does not include mcp-exec"
  fi
}

check_headroom() {
  check_command headroom

  if ! have curl; then
    warn "headroom proxy not reachable on 127.0.0.1:8787"
    return
  fi

  local attempt
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if curl -fsS --max-time 5 http://127.0.0.1:8787/livez >/dev/null 2>&1 \
      && curl -fsS --max-time 5 http://127.0.0.1:8787/readyz >/dev/null 2>&1; then
      pass "headroom proxy live and ready on 127.0.0.1:8787"
      return
    fi
    sleep 1
  done

  warn "headroom proxy not live and ready on 127.0.0.1:8787"
}

check_macos_shell_probe() {
  local output rc

  [ "$DOCTOR_OS" = Darwin ] || return 0
  if [ -z "$PYTHON_BIN" ] || [ ! -x "$DOCTOR_ZSH" ]; then
    warn "macOS login-shell probe could not run"
    return 0
  fi

  output="$(run_bounded 4 "$DOCTOR_ZSH" -ilc 'command -v gh' 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -Eq '(^|/)gh$'; then
    pass "macOS login-shell probe resolves GitHub CLI within four seconds"
  elif [ "$rc" -eq 124 ]; then
    warn "macOS login-shell probe exceeds four seconds; Codex Desktop may time out"
  else
    warn "macOS login-shell probe does not resolve GitHub CLI"
  fi
}

check_embedder_sidecar() {
  if [ ! -f "$EMBEDDER" ]; then
    warn "$EMBEDDER missing"
    return
  fi

  # Current MemPalace records the active drawers embedder here; closet vectors
  # are validated by `repair-status` and need not have a duplicate sidecar key.
  if grep -q '"mempalace_drawers"' "$EMBEDDER"; then
    pass "mempalace embedder sidecar has a drawers identity"
  else
    warn "mempalace embedder sidecar missing drawers identity"
  fi
}

check_graphify_config() {
  local line
  local bad=0

  if [ ! -f "$CONF" ]; then
    warn "$CONF missing"
    return
  fi

  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac

    if [ "$(repo_root_of "$line")" != "$line" ]; then
      printf '  invalid graphify repo: %s\n' "$line"
      bad=1
    fi
  done < "$CONF"

  if [ "$bad" -eq 0 ]; then
    pass "graphify repo config contains only repo roots"
  else
    graphify_fail "graphify repo config contains non-repo paths"
  fi
}

check_repo_discovery() {
  local workflow_root
  workflow_root="$(repo_root_of "$REPO_DIR")"
  if [ -n "$workflow_root" ] && repo_list_contains "$workflow_root"; then
    pass "workflow repository included in discovery"
  else
    graphify_fail "workflow repository missing from discovery"
  fi
}

check_stale_graphify_dirs() {
  local dir
  local owner
  local git_root
  local stale=0

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    owner="${dir%/graphify-out}"

    if repo_list_contains "$owner"; then
      continue
    fi

    git_root="$(repo_root_of "$owner")"
    if [ -n "$git_root" ] && [ "$git_root" = "$owner" ]; then
      warn "extra graphify-out in undiscovered git worktree: $dir"
      continue
    fi

    printf '  stale graphify-out: %s\n' "$dir"
    stale=1
  done <<EOF
$(for root in "$REPO_DIR" "$HOME/xebia" "$HOME/complion"; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth 4 -type d -name graphify-out 2>/dev/null
done | sort)
EOF

  if [ "$stale" -eq 0 ]; then
    pass "no stale parent graphify-out dirs found"
  else
    warn "stale graphify-out dirs found; run refresh helper with --prune-stale"
  fi
}

check_pending_mines() {
  if [ -s "$PENDING" ]; then
    warn "pending graphify mines exist: $PENDING"
  else
    pass "no pending graphify mines"
  fi
}

check_git_state() {
  local branch
  local status

  if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "workflow repo is not a git checkout"
    return
  fi

  status="$(git -C "$REPO_DIR" status --short)"
  branch="$(git -C "$REPO_DIR" status --short --branch | sed -n '1p')"

  if [ -z "$status" ]; then
    pass "workflow repo clean ($branch)"
  else
    warn "workflow repo has uncommitted changes ($branch)"
  fi
}

echo "Codex workflow doctor"
echo

repos="$(discover_repos)"

check_global_agents
check_hook_installation
check_skill_installation
check_fast_profile
check_codex_config
check_macos_shell_probe
check_mcp_docker
if [ "$RUNTIME" != 0 ]; then
  check_headroom
  check_command mempalace
  check_command mempalace-mcp
  check_command graphify
  check_embedder_sidecar
fi
check_graphify_config
check_repo_discovery
check_stale_graphify_dirs
if [ "$RUNTIME" != 0 ]; then
  check_pending_mines
fi
check_git_state

echo
printf 'Summary: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  NEXT_ACTION=""
  if [ "$NEED_INSTALL" -eq 1 ]; then
    NEXT_ACTION="Run ./tools/codex/install-codex.sh and rerun this doctor."
  fi
  if [ "$NEED_DOCKER" -eq 1 ]; then
    [ -z "$NEXT_ACTION" ] || NEXT_ACTION="$NEXT_ACTION "
    NEXT_ACTION="${NEXT_ACTION}Repair Docker MCP_DOCKER/profile readiness, then rerun this doctor."
  fi
  if [ "$NEED_GRAPHIFY" -eq 1 ]; then
    [ -z "$NEXT_ACTION" ] || NEXT_ACTION="$NEXT_ACTION "
    NEXT_ACTION="${NEXT_ACTION}Replace invalid Graphify roots with current git repository roots."
  fi
  printf 'Next action: %s\n' "$NEXT_ACTION"
elif [ "$WARN" -gt 0 ]; then
  printf 'Next action: %s\n' "$NEXT_ACTION"
else
  printf 'Next action: workflow healthy; no action needed.\n'
fi

[ "$FAIL" -eq 0 ]
