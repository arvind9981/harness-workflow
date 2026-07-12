#!/usr/bin/env bash
# Check the repo-owned Codex workflow wiring and local runtime state.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
CONF="${GRAPHIFY_REPOS_CONF:-$HOME/.mempalace/graphify-repos.conf}"
PENDING="$HOME/.mempalace/hook_state/graphify-pending-mines"
EMBEDDER="$HOME/.mempalace/palace/mempalace_embedder.json"

PASS=0
WARN=0
FAIL=0
NEXT_ACTION=""

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
  NEXT_ACTION="Run ./tools/codex/install-codex.sh, then rerun this doctor."
  printf 'FAIL %s\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

repo_root_of() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

discover_repos() {
  repo_root_of "$HOME/claude-workflow"

  for root in "$HOME/xebia" "$HOME/complion"; do
    [ -d "$root" ] || continue

    for child in "$root"/*; do
      [ -d "$child" ] || continue
      repo_root_of "$child"
    done
  done | awk 'NF && !seen[$0]++' | sort
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

  if [ ! -f "$config" ]; then
    fail "$config missing"
    return
  fi

  # Accept single- or double-quoted (or unquoted) TOML values — Codex writes single quotes.
  if grep -Eq "openai_base_url[[:space:]]*=[[:space:]]*['\"]?http://127\.0\.0\.1:8787/v1['\"]?" "$config"; then
    pass "Codex native openai_base_url routes through headroom"
  else
    fail "Codex native openai_base_url is not routed through headroom"
  fi

  if grep -q 'OPENAI_BASE_URL.*http://127\.0\.0\.1:8787/v1' "$config"; then
    pass "Codex OPENAI_BASE_URL routes through headroom"
  else
    warn "Codex OPENAI_BASE_URL not found in config env"
  fi

  if grep -q 'ANTHROPIC_BASE_URL.*http://127\.0\.0\.1:8787' "$config"; then
    pass "Codex ANTHROPIC_BASE_URL routes through headroom"
  else
    warn "Codex ANTHROPIC_BASE_URL not found in config env"
  fi
}

check_headroom() {
  check_command headroom

  if ! have curl; then
    warn "headroom proxy not reachable on 127.0.0.1:8787"
    return
  fi

  local attempt
  for attempt in 1 2 3; do
    if curl -fsS --max-time 5 http://127.0.0.1:8787/livez >/dev/null 2>&1 \
      && curl -fsS --max-time 5 http://127.0.0.1:8787/readyz >/dev/null 2>&1; then
      pass "headroom proxy live and ready on 127.0.0.1:8787"
      return
    fi
    sleep 1
  done

  warn "headroom proxy not live and ready on 127.0.0.1:8787"
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
    [ -n "$line" ] || continue

    if [ "$(repo_root_of "$line")" != "$line" ]; then
      printf '  invalid graphify repo: %s\n' "$line"
      bad=1
    fi
  done < "$CONF"

  if [ "$bad" -eq 0 ]; then
    pass "graphify repo config contains only repo roots"
  else
    fail "graphify repo config contains non-repo paths"
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
$(for root in "$HOME/claude-workflow" "$HOME/xebia" "$HOME/complion"; do
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
check_headroom
check_command mempalace
check_command mempalace-mcp
check_command graphify
check_embedder_sidecar
check_graphify_config
check_stale_graphify_dirs
check_pending_mines
check_git_state
warn "MCP-native mempalace mining is not exposed to this shell doctor; CLI drain remains fallback"

echo
printf 'Summary: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Next action: %s\n' "$NEXT_ACTION"
elif [ "$WARN" -gt 0 ]; then
  printf 'Next action: %s\n' "$NEXT_ACTION"
else
  printf 'Next action: workflow healthy; no action needed.\n'
fi

[ "$FAIL" -eq 0 ]
