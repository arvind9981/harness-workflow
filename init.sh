#!/usr/bin/env bash
# init.sh — reproduce my Claude Code workflow on a fresh machine.
#
#   git clone <this repo> && cd claude-workflow && ./init.sh
#
#   ./init.sh --help
#   ./init.sh --graphify-repo "$HOME/project-a"
#
# No secrets travel with this repo. After running, start `claude` and log in
# interactively — Claude Code auto-installs the plugins declared in settings.json.
#
# Idempotent: every file it overwrites is backed up first (timestamped .bak-init).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./init.sh [options]

Reproduce this Claude/Codex workflow on the current machine.

Options:
  --desktop               Wire the mempalace MCP server into Claude Desktop (macOS; default).
  --no-desktop            Skip Claude Desktop MCP wiring.
  --graphify-repo PATH    Add a repo to the graphify->mempalace reseed list.
                          Repeat this option for multiple repos. Missing paths
                          are skipped with a warning.
  -h, --help              Show this help.

Environment:
  GRAPHIFY_EXTRA_REPOS    Colon-separated repo paths added to the reseed list.
                          Example:
GRAPHIFY_EXTRA_REPOS="$HOME/app:$HOME/api" ./init.sh
  CODEX_WINDOWS_DIR       Windows Codex home as a WSL path when auto-detection
                          is ambiguous (for example /mnt/c/Users/me/.codex).
  CODEX_WSL_DISTRO        WSL distro name used by Windows Codex hook/MCP commands
                          when WSL_DISTRO_NAME is unavailable.

Default:
  With no graphify repos configured, init tracks this claude-workflow repo only.
EOF
}

INSTALL_DESKTOP=1
GRAPHIFY_REPOS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
--desktop) INSTALL_DESKTOP=1 ;;
--no-desktop) INSTALL_DESKTOP=0 ;;
    --graphify-repo)
      [ "$#" -ge 2 ] || { printf 'missing path after --graphify-repo\n' >&2; exit 1; }
      GRAPHIFY_REPOS+=("$2")
      shift
      ;;
    --graphify-repo=*)
      GRAPHIFY_REPOS+=("${1#*=}")
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
source "$REPO_DIR/tools/codex/platform.sh"
if ! codex_detect_platform; then
  printf 'init.sh: %s\n' "$PLATFORM_ERROR" >&2
  exit 1
fi
OS="$PLATFORM_OS"                          # Linux | Darwin
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"      # systemd user units (Linux)
LAUNCH_DIR="$HOME/Library/LaunchAgents"    # launchd LaunchAgents (macOS)

# Repos whose code graph is reseeded into mempalace (one graphify_<repo> wing
# each, wipe-and-replace from graphify-out/GRAPH_REPORT.md), refreshed by the
# throttled SessionStart hook. Keep the portable default empty so a fresh machine
# tracks this workflow repo only. To add machine-specific repos without editing
# this file, pass --graphify-repo repeatedly or set GRAPHIFY_EXTRA_REPOS.
if [ -n "${GRAPHIFY_EXTRA_REPOS:-}" ]; then
  OLD_IFS="$IFS"; IFS=:
  # shellcheck disable=SC2206
  extra_repos=($GRAPHIFY_EXTRA_REPOS)
  IFS="$OLD_IFS"
  GRAPHIFY_REPOS+=("${extra_repos[@]}")
fi

# OS-derived hint string shown to the user (the service manager differs per OS).
case "$OS" in
  Darwin) STATUS_HR="launchctl list | grep headroom-proxy" ;;
  *)      STATUS_HR="systemctl --user status headroom-proxy" ;;
esac

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$1"; }
info() { printf '  %s•%s %s\n' "$c_dim" "$c_rst" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_rst" "$1"; }
die()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$1" >&2; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$c_grn" "$1" "$c_rst"; }

backup() {  # backup <path> — copy aside once per run if it exists (first backup wins),
            # then keep only the newest $KEEP_BACKUPS snapshots of that path (prune old runs)
  [ -e "$1.bak-init-$STAMP" ] && return 0   # already backed up this run; keep the true pre-run snapshot
  [ -e "$1" ] || return 0
  cp -p "$1" "$1.bak-init-$STAMP" && info "backed up $(basename "$1") -> $(basename "$1").bak-init-$STAMP"
  # Prune: the bak-init-YYYYMMDD-HHMMSS suffix sorts chronologically, so keep the newest
  # $KEEP_BACKUPS and delete the rest for this path. Never let a prune failure abort init.
  local keep="${KEEP_BACKUPS:-5}" dir base old
  dir="$(dirname "$1")"; base="$(basename "$1")"
  find "$dir" -maxdepth 1 -name "$base.bak-init-*" 2>/dev/null | sort -r | tail -n +"$((keep + 1))" \
    | while IFS= read -r old; do rm -f "$old"; done || true
  return 0
}

svc_enable() {  # svc_enable <linux_unit_file> <mac_plist_file> — install + start a background service
  local linux_unit="$1" mac_plist="$2"
  if [ "$OS" = "Darwin" ]; then
    mkdir -p "$LAUNCH_DIR" "$HOME/Library/Logs"
    local dest; dest="$LAUNCH_DIR/$(basename "$mac_plist")"
    backup "$dest"
    sed "s#__HOME__#$HOME#g" "$mac_plist" > "$dest"   # launchd has no %h specifier
    launchctl unload "$dest" 2>/dev/null || true
    launchctl load -w "$dest" \
      && ok "$(basename "$dest") loaded (launchd)" \
      || die "launchctl load failed for $(basename "$dest")"
  else
    mkdir -p "$UNIT_DIR"
    local unit; unit="$(basename "$linux_unit")"
    backup "$UNIT_DIR/$unit"
    cp "$linux_unit" "$UNIT_DIR/$unit"
    systemctl --user daemon-reload
    systemctl --user enable --now "$unit" \
      && ok "$unit enabled and started (systemd)" \
      || die "systemctl enable failed for $unit"
  fi
}

detect_windows_codex_dir() {  # Print the Windows Codex home as a WSL path, if unambiguous.
  [ "$IS_WSL" = 1 ] || return 1

  if [ -n "${CODEX_WINDOWS_DIR:-}" ]; then
    printf '%s\n' "$CODEX_WINDOWS_DIR"
    return 0
  fi

  case "${CODEX_HOME:-}" in
    [A-Za-z]:\\*)
      command -v wslpath >/dev/null 2>&1 || return 1
      wslpath -u "$CODEX_HOME"
      return 0
      ;;
  esac

  local windows_home=""
  if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    windows_home="$(cd /mnt/c 2>/dev/null && cmd.exe /d /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
    if [ -n "$windows_home" ]; then
      printf '%s/.codex\n' "$(wslpath -u "$windows_home")"
      return 0
    fi
  fi

  local candidates=() candidate
  if [ -d /mnt/c/Users ]; then
    while IFS= read -r candidate; do candidates+=("$(dirname "$candidate")"); done \
      < <(find /mnt/c/Users -mindepth 3 -maxdepth 3 -type f -path '*/.codex/config.toml' 2>/dev/null)
  fi
  [ "${#candidates[@]}" -eq 1 ] || return 1
  printf '%s\n' "${candidates[0]}"
}

install_windows_codex_bridge() {  # Bridge portable Codex workflow pieces into the Windows app.
  local windows_codex_dir="$1" source_json="$REPO_DIR/codex/hooks.json"
  local linux_rendered windows_rendered dest agents_dest src rel skill_dest
  local config rendered_config
  linux_rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooks-linux.XXXXXX")"
  windows_rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooks-windows.XXXXXX")"
  dest="$windows_codex_dir/hooks.json"

  sed "s#__HOME__#$HOME#g" "$source_json" > "$linux_rendered"
  if ! jq --arg distro "$WSL_DISTRO" '
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(
            .command = ("wsl.exe -d " + ($distro | @json)
              + " --exec bash -lc " + (.command | @json))
          )
        )
      )
    ' "$linux_rendered" > "$windows_rendered"; then
    rm -f "$linux_rendered" "$windows_rendered"
    warn "could not render Windows Codex App hooks"
    return 1
  fi
  rm -f "$linux_rendered"

  mkdir -p "$windows_codex_dir"
  if [ -f "$dest" ] && cmp -s "$windows_rendered" "$dest"; then
    rm -f "$windows_rendered"
    ok "Windows Codex App hooks already bridged ($dest)"
  else
    backup "$dest"
    install -m 0644 "$windows_rendered" "$dest"
    rm -f "$windows_rendered"
    ok "Windows Codex App hooks -> $dest (WSL distro: $WSL_DISTRO)"
  fi

  agents_dest="$windows_codex_dir/AGENTS.md"
  if [ ! -f "$agents_dest" ] || ! cmp -s "$REPO_DIR/codex/AGENTS.md" "$agents_dest"; then
    backup "$agents_dest"
    install -m 0644 "$REPO_DIR/codex/AGENTS.md" "$agents_dest"
    ok "Windows Codex App AGENTS.md -> $agents_dest"
  else
    ok "Windows Codex App AGENTS.md already current"
  fi

  if [ -d "$REPO_DIR/workflow/skills" ]; then
    while IFS= read -r -d '' src; do
      rel="${src#"$REPO_DIR/workflow/skills/"}"
      skill_dest="$windows_codex_dir/skills/$rel"
      mkdir -p "$(dirname "$skill_dest")"
      if [ ! -f "$skill_dest" ] || ! cmp -s "$src" "$skill_dest"; then
        backup "$skill_dest"
        if [ -x "$src" ]; then install -m 0755 "$src" "$skill_dest"
        else install -m 0644 "$src" "$skill_dest"
        fi
      fi
    done < <(find "$REPO_DIR/workflow/skills" -type f -print0)
    ok "Windows Codex App workflow skills -> $windows_codex_dir/skills"
  fi

  config="$windows_codex_dir/config.toml"
  rendered_config="$(mktemp "${TMPDIR:-/tmp}/codex-windows-config.XXXXXX")"
  touch "$config"
  if ! python3 - "$config" "$rendered_config" "$WSL_DISTRO" \
      "$HOME/.local/bin/mempalace-mcp" "$HOME/.mempalace/palace" <<'PY'
import json
import sys
from pathlib import Path

source, output, distro, command, palace = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
lines = text.splitlines()
result = []
in_mempalace = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1]
        if section == "mcp_servers.mempalace":
            in_mempalace = True
            continue
        in_mempalace = False
    if not in_mempalace:
        result.append(line)

while result and not result[-1].strip():
    result.pop()
if result:
    result.append("")
result.extend([
    "[mcp_servers.mempalace]",
    'command = "wsl.exe"',
    "args = " + json.dumps([
        "-d", distro, "--exec", command, "--palace", palace,
    ]),
    "startup_timeout_sec = 120",
])
Path(output).write_text("\n".join(result) + "\n", encoding="utf-8")
PY
  then
    rm -f "$rendered_config"
    warn "could not configure the Windows Codex App Mempalace MCP"
    return 1
  fi
  if cmp -s "$rendered_config" "$config"; then
    rm -f "$rendered_config"
    ok "Windows Codex App Mempalace MCP already configured"
  else
    backup "$config"
    install -m 0644 "$rendered_config" "$config"
    rm -f "$rendered_config"
    ok "Windows Codex App Mempalace MCP registered through WSL"
  fi

  info "fully restart the Codex App so it reloads AGENTS.md, skills, hooks, and MCPs"
}

# ---------------------------------------------------------------------------
step "Prerequisites"
missing=()
for c in git curl jq; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if [ "$OS" = "Darwin" ]; then
  command -v launchctl >/dev/null 2>&1 || warn "launchctl not found — the proxy service steps will be skipped"
else
  command -v systemctl >/dev/null 2>&1 || warn "systemctl not found — the proxy service steps will be skipped"
fi
if [ "${#missing[@]}" -ne 0 ]; then
  if [ "$OS" = "Darwin" ]; then die "install these first: brew install ${missing[*]}"
  else die "install these first via your package manager: ${missing[*]}"; fi
fi
ok "git, curl, jq present"

# uv (only nonstandard dep — needed to install headroom)
if ! command -v uv >/dev/null 2>&1; then
  if [ -t 0 ]; then
    read -r -p "  uv is not installed. Install it now via the official installer? [Y/n] " ans
    case "${ans:-Y}" in
      [nN]*) die "uv required for headroom. Install: https://docs.astral.sh/uv/ then re-run." ;;
      *) curl -LsSf https://astral.sh/uv/install.sh | sh
         export PATH="$HOME/.local/bin:$PATH" ;;
    esac
  else
    die "uv not installed and shell is non-interactive. Install uv then re-run."
  fi
fi
command -v uv >/dev/null 2>&1 && ok "uv present ($(uv --version 2>/dev/null))"

# ---------------------------------------------------------------------------
step "Install headroom"
# The [proxy] extra (fastapi/uvicorn) is REQUIRED — the systemd/launchd service runs
# `headroom proxy`, which exits 1 without it. Plain `headroom-ai` leaves :8787 unbound
# and Claude Code (ANTHROPIC_BASE_URL -> 127.0.0.1:8787) fails with ConnectionRefused.
uv tool install --upgrade 'headroom-ai[proxy]' >/dev/null 2>&1 && ok "headroom-ai[proxy] installed/upgraded" \
  || die "uv tool install 'headroom-ai[proxy]' failed"

# ---------------------------------------------------------------------------
step "Install mempalace (memory layer)"
# mempalace is the memory layer (local-first, verbatim recall, zero-API retrieval).
# The plugin auto-loads via settings.json; the CLI + native MCP server must be on
# PATH for the plugin's MCP (.mcp.json calls `mempalace-mcp`) and its Stop/PreCompact
# hooks (which call `mempalace`).
uv tool install --upgrade mempalace >/dev/null 2>&1 && ok "mempalace installed/upgraded" \
  || die "uv tool install mempalace failed"
command -v mempalace-mcp >/dev/null 2>&1 && ok "mempalace-mcp (native MCP) present" \
  || warn "mempalace-mcp missing — MCP wiring will fail"
# Re-apply the HNSW divergence-threshold patch (chroma #6852). A `uv tool upgrade`
# overwrites mempalace's site-packages, so this must run after every (re)install.
# Idempotent + defensive: no-op if already patched, warns (does not fail) if the
# stock constants have changed. Without it, a lagging HNSW deadlocks the MCP on its
# first vector query instead of falling back to BM25. See the script header.
bash "$REPO_DIR/tools/mempalace/patch-divergence-threshold.sh" || warn "divergence-threshold patch did not apply cleanly (review manually)"

# ---------------------------------------------------------------------------
step "Install graphify (code knowledge graph)"
# graphify turns a repo into a queryable graph; a self-guarding PreToolUse hook
# (shipped in claude/settings.json) redirects search to the graph when one exists.
# PyPI package is 'graphifyy' (double-y); the CLI is 'graphify'. Builds extract via
# Claude subagents through the headroom proxy (no ollama, nothing to pin).
uv tool install --upgrade graphifyy >/dev/null 2>&1 && ok "graphifyy installed/upgraded" \
  || warn "uv tool install graphifyy failed — graphify features will be skipped"
command -v graphify >/dev/null 2>&1 && ok "graphify CLI present" \
  || warn "graphify missing — skill registration will be skipped"

# ---------------------------------------------------------------------------
step "Ignore graphify artifacts globally"
# graphify writes a per-repo graphify-out/ (graph.json, report, html, cache). Ignore
# it globally so it never gets committed in any repo.
GI="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
mkdir -p "$(dirname "$GI")"
if ! { [ -f "$GI" ] && grep -qxF 'graphify-out/' "$GI"; }; then
  backup "$GI"
  printf 'graphify-out/\n' >> "$GI"
  ok "graphify-out/ added to $GI"
else
  ok "graphify-out/ already ignored in $GI"
fi
if [ -z "$(git config --global core.excludesFile 2>/dev/null)" ]; then
  git config --global core.excludesFile "$GI" && info "set core.excludesFile=$GI"
fi

# ---------------------------------------------------------------------------
step "Install scripts"
mkdir -p "$BIN_DIR"
backup "$BIN_DIR/headroom-watch"
install -m 0755 "$REPO_DIR/tools/headroom/headroom-watch" "$BIN_DIR/headroom-watch"
ok "headroom-watch -> $BIN_DIR/headroom-watch"
backup "$BIN_DIR/mempalace-prune.py"
install -m 0755 "$REPO_DIR/tools/mempalace/mempalace-prune.py" "$BIN_DIR/mempalace-prune.py"
ok "mempalace-prune.py -> $BIN_DIR/mempalace-prune.py"
backup "$BIN_DIR/graphify-reseed.sh"
install -m 0755 "$REPO_DIR/tools/graphify/graphify-reseed.sh" "$BIN_DIR/graphify-reseed.sh"
ok "graphify-reseed.sh -> $BIN_DIR/graphify-reseed.sh"
backup "$BIN_DIR/graphify-complete-map.sh"
install -m 0755 "$REPO_DIR/tools/graphify/graphify-complete-map.sh" "$BIN_DIR/graphify-complete-map.sh"
ok "graphify-complete-map.sh -> $BIN_DIR/graphify-complete-map.sh"
backup "$BIN_DIR/graphify-sync.sh"
install -m 0755 "$REPO_DIR/tools/graphify/graphify-sync.sh" "$BIN_DIR/graphify-sync.sh"
ok "graphify-sync.sh -> $BIN_DIR/graphify-sync.sh"
backup "$BIN_DIR/reseed-verify.sh"
install -m 0755 "$REPO_DIR/tools/graphify/reseed-verify.sh" "$BIN_DIR/reseed-verify.sh"
ok "reseed-verify.sh -> $BIN_DIR/reseed-verify.sh"
backup "$BIN_DIR/mempalace-snapshot.sh"
install -m 0755 "$REPO_DIR/tools/mempalace/mempalace-snapshot.sh" "$BIN_DIR/mempalace-snapshot.sh"
ok "mempalace-snapshot.sh -> $BIN_DIR/mempalace-snapshot.sh"
backup "$BIN_DIR/mempalace-stop-timeout.sh"
install -m 0755 "$REPO_DIR/tools/mempalace/mempalace-stop-timeout.sh" "$BIN_DIR/mempalace-stop-timeout.sh"
ok "mempalace-stop-timeout.sh -> $BIN_DIR/mempalace-stop-timeout.sh"
backup "$BIN_DIR/mempalace-stop-detach.sh"
install -m 0755 "$REPO_DIR/tools/mempalace/mempalace-stop-detach.sh" "$BIN_DIR/mempalace-stop-detach.sh"
ok "mempalace-stop-detach.sh -> $BIN_DIR/mempalace-stop-detach.sh"
case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) warn "$BIN_DIR is not on your PATH — add it to use the headroom CLI" ;; esac

# ---------------------------------------------------------------------------
step "Install Claude settings"
mkdir -p "$CLAUDE_DIR"
# settings.json: render __HOME__ placeholder -> real $HOME
backup "$CLAUDE_DIR/settings.json"
sed "s#__HOME__#$HOME#g" "$REPO_DIR/claude/settings.json" > "$CLAUDE_DIR/settings.json"
ok "settings.json (paths resolved to $HOME)"
# settings.local.json: sanitized allowlist, copy verbatim
backup "$CLAUDE_DIR/settings.local.json"
cp "$REPO_DIR/claude/settings.local.json" "$CLAUDE_DIR/settings.local.json"
ok "settings.local.json ($(jq '.permissions.allow|length' "$CLAUDE_DIR/settings.local.json") allow rules)"
# CLAUDE.md: global standing instructions, copy verbatim
if [ -f "$REPO_DIR/claude/CLAUDE.md" ]; then
  backup "$CLAUDE_DIR/CLAUDE.md"
  cp "$REPO_DIR/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  ok "CLAUDE.md (global standing instructions)"
fi
# statusline script: deploy to ~/.claude (referenced by settings.json statusLine.command)
if [ -f "$REPO_DIR/claude/statusline-command.sh" ]; then
  backup "$CLAUDE_DIR/statusline-command.sh"
  install -m 0755 "$REPO_DIR/claude/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
  ok "statusline-command.sh -> $CLAUDE_DIR/"
fi
# shared hooks: deploy repo-owned lifecycle scripts referenced by settings.json
if [ -d "$REPO_DIR/workflow/hooks" ]; then
  mkdir -p "$CLAUDE_DIR/hooks"
  for h in "$REPO_DIR"/workflow/hooks/*.sh; do
    [ -e "$h" ] || continue
    backup "$CLAUDE_DIR/hooks/$(basename "$h")"
    install -m 0755 "$h" "$CLAUDE_DIR/hooks/$(basename "$h")"
    ok "hook $(basename "$h") -> $CLAUDE_DIR/hooks/"
  done
fi

# workflows: deploy saved Workflow scripts (e.g. fable-review) for name-based invocation
if [ -d "$REPO_DIR/claude/workflows" ]; then
  mkdir -p "$CLAUDE_DIR/workflows"
  for w in "$REPO_DIR"/claude/workflows/*.js; do
    [ -e "$w" ] || continue
    backup "$CLAUDE_DIR/workflows/$(basename "$w")"
    install -m 0644 "$w" "$CLAUDE_DIR/workflows/$(basename "$w")"
    ok "workflow $(basename "$w") -> $CLAUDE_DIR/workflows/"
  done
fi

step "Codex workflow (auto-detected)"
# The WSL CLI and Windows Codex App use different Codex homes. Install the shared
# workflow into ~/.codex when either surface is found, then give the Windows app a
# hooks.json whose commands explicitly re-enter this distro. Never copy config.toml
# across: the app owns Windows-specific plugin and runtime paths there.
WINDOWS_CODEX_DIR="$(detect_windows_codex_dir || true)"
if command -v codex >/dev/null 2>&1 || [ -n "$WINDOWS_CODEX_DIR" ]; then
  bash "$REPO_DIR/tools/codex/install-codex.sh"
  if bash "$REPO_DIR/tools/codex/doctor-workflow.sh"; then
    ok "Codex workflow verified"
  else
    warn "Codex workflow installed; doctor reported local follow-up"
  fi
  ok "Codex detected — hooks/instructions migrated into ~/.codex"
  if [ -n "$WINDOWS_CODEX_DIR" ] && [ -n "$WSL_DISTRO" ]; then
    install_windows_codex_bridge "$WINDOWS_CODEX_DIR" || warn "Windows Codex App bridge needs local follow-up"
  elif [ "$IS_WSL" = 1 ] && [ -z "$WSL_DISTRO" ]; then
    warn "WSL detected without a distro name; set CODEX_WSL_DISTRO and re-run init.sh for the Windows Codex bridge"
  elif [ "$IS_WSL" = 1 ]; then
    warn "WSL detected but the Windows Codex home was ambiguous; set CODEX_WINDOWS_DIR and re-run init.sh"
  fi
else
  info "Codex CLI/App not installed — skipping (nothing to migrate)"
fi

step "OpenCode workflow (auto-detected)"
# OpenCode has its own plugin and MCP contract. If it is installed, deploy the
# repo-owned adapter and let its installer register only the local Mempalace and
# Headroom servers; if it is absent, leave the machine untouched.
if command -v opencode >/dev/null 2>&1; then
  bash "$REPO_DIR/tools/opencode/install-opencode.sh"
  if bash "$REPO_DIR/tools/opencode/doctor-workflow.sh"; then
    ok "OpenCode workflow verified"
  else
    warn "OpenCode workflow installed; doctor reported local follow-up"
  fi
  ok "OpenCode detected — workflow plugin, helpers, and local MCPs installed"
else
  info "opencode not installed — skipping (nothing to migrate)"
fi

# ---------------------------------------------------------------------------
step "Wire Claude Desktop MCP (mempalace)"
# Claude Desktop is a SEPARATE app from Claude Code: it has no hooks / CLAUDE.md /
# skills engine — only MCP servers. So the sole piece of this workflow that ports to
# Desktop is the mempalace memory server. We MERGE it into Desktop's config (macOS
# path) with jq, leaving every other server (e.g. MCP_DOCKER) and preference key
# untouched. Hooks/CLAUDE.md cannot be wired here — the app has no engine for them.
if [ "$INSTALL_DESKTOP" = 1 ]; then
  if [ "$OS" = "Darwin" ]; then
    DESKTOP_APP_DIR="$HOME/Library/Application Support/Claude"
    DESKTOP_CFG="$DESKTOP_APP_DIR/claude_desktop_config.json"
    MP_BIN="$(command -v mempalace-mcp || true)"
    [ -n "$MP_BIN" ] || MP_BIN="$BIN_DIR/mempalace-mcp"
    PALACE_DIR="$HOME/.mempalace/palace"
    if [ ! -d "$DESKTOP_APP_DIR" ]; then
      info "Claude Desktop not installed (no $DESKTOP_APP_DIR) — skipping Desktop MCP wiring"
    elif [ ! -x "$MP_BIN" ]; then
      warn "mempalace-mcp not found at $MP_BIN — skipping Desktop MCP wiring"
    else
      # Absolute binary path is REQUIRED: Desktop is a GUI app with a minimal PATH and
      # cannot resolve a bare 'mempalace-mcp' (Claude Code can). --palace pins Desktop to
      # the SAME shared palace as Claude Code.
      [ -s "$DESKTOP_CFG" ] || printf '{}\n' > "$DESKTOP_CFG"
      merged="$(mktemp)"
      if jq --arg cmd "$MP_BIN" --arg palace "$PALACE_DIR" \
            '.mcpServers = ((.mcpServers // {}) + {mempalace: {command: $cmd, args: ["--palace", $palace]}})' \
            "$DESKTOP_CFG" > "$merged" 2>/dev/null && [ -s "$merged" ]; then
        if cmp -s "$merged" "$DESKTOP_CFG"; then
          ok "Claude Desktop MCP already wired (mempalace -> $MP_BIN)"
          rm -f "$merged"
        else
          backup "$DESKTOP_CFG"
          mv "$merged" "$DESKTOP_CFG"
          ok "Claude Desktop MCP wired (mempalace -> $MP_BIN); other servers preserved"
          info "fully quit + reopen Claude Desktop (Cmd-Q) so it reloads the MCP config"
        fi
      else
        rm -f "$merged"
        warn "$DESKTOP_CFG is not valid JSON — left unchanged"
      fi
    fi
  else
    info "skipped Claude Desktop MCP wiring (macOS-only; OS=$OS)"
  fi
else
  info "skipped Claude Desktop MCP wiring (--no-desktop)"
fi

# ---------------------------------------------------------------------------
step "Register graphify skill (Claude Code)"
# Deploys ~/.claude/skills/graphify/ (the skill files can't be vendored). Runs AFTER
# the settings/CLAUDE.md deploy above so graphify's own trigger note lands in the
# freshly written CLAUDE.md (and is reset to a single copy on every run). The always-on
# HOOK + usage guidance ship in the repo templates (claude/settings.json,
# claude/CLAUDE.md), so we do NOT run 'graphify claude install' — it is project-scoped
# and would double-fire against the global hook.
if command -v graphify >/dev/null 2>&1; then
  backup "$CLAUDE_DIR/CLAUDE.md"
  graphify install --platform claude >/dev/null 2>&1 && ok "graphify skill registered" \
    || warn "graphify install failed"
  info "build a repo's graph with '/graphify .' (extraction routes via headroom)"
else
  warn "graphify not installed — skipping skill registration"
fi

# ---------------------------------------------------------------------------
step "Headroom proxy service"
if { [ "$OS" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; } || command -v systemctl >/dev/null 2>&1; then
  svc_enable "$REPO_DIR/tools/headroom/headroom-proxy.service" "$REPO_DIR/tools/headroom/com.user.headroom-proxy.plist"
  [ "$OS" = "Darwin" ] || info "tip: 'loginctl enable-linger $USER' keeps the proxy alive without an active login"
else
  warn "skipped (no service manager). Run manually: headroom proxy --port 8787 --host 127.0.0.1"
fi

# ---------------------------------------------------------------------------
step "ChatGPT toggle (Claude CLI <-> ChatGPT)"
# A small front-router on :8788 that Claude Code points at; it forwards to headroom
# (:8787 -> Claude) or the claude-code-proxy bridge (:18765 -> your ChatGPT
# subscription). `gpt-toggle` flips it live. Linux/systemd only (no launchd plists
# shipped) — on macOS Claude Code stays on headroom :8787.
CT_SRC="$REPO_DIR/tools/chatgpt-toggle"
CT_LIB="$HOME/.local/share/chatgpt-toggle"
CCP_URL="https://raw.githubusercontent.com/raine/claude-code-proxy/main/scripts/install.sh"
if [ "$OS" != "Linux" ] || ! command -v systemctl >/dev/null 2>&1; then
  info "ChatGPT toggle is Linux/systemd-only — skipping (Claude Code stays on headroom :8787)"
else
  # 1) Bridge binary — a PINNED, community proxy that speaks your ChatGPT subscription
  #    via Codex OAuth. NOTE: unlike the uv/PyPI deps above this is a curl|bash of a
  #    third-party binary that talks to an undocumented ChatGPT endpoint. See README
  #    "ChatGPT toggle" + Safety.
  if command -v claude-code-proxy >/dev/null 2>&1; then
    ok "claude-code-proxy present ($(claude-code-proxy --version 2>/dev/null))"
  elif CLAUDE_CODE_PROXY_INSTALL_DIR="$BIN_DIR" \
       CLAUDE_CODE_PROXY_VERSION="${CLAUDE_CODE_PROXY_VERSION:-v0.1.11}" \
       bash -c "curl -fsSL '$CCP_URL' | bash" >/dev/null 2>&1 \
       && command -v claude-code-proxy >/dev/null 2>&1; then
    ok "claude-code-proxy installed -> $BIN_DIR"
  else
    warn "claude-code-proxy install failed — ChatGPT toggle skipped (Claude Code stays on :8787)"
  fi

  if command -v claude-code-proxy >/dev/null 2>&1; then
    # 2) router.py + toggle.py -> a fixed lib dir (independent of this clone's path)
    mkdir -p "$CT_LIB"
    for f in router.py toggle.py; do
      backup "$CT_LIB/$f"; install -m 0644 "$CT_SRC/$f" "$CT_LIB/$f"
    done
    ok "router.py + toggle.py -> $CT_LIB"
    # 3) gpt-toggle CLI (copy, like the other bin scripts — survives clone deletion)
    backup "$BIN_DIR/gpt-toggle"; install -m 0755 "$CT_SRC/gpt-toggle" "$BIN_DIR/gpt-toggle"
    ok "gpt-toggle -> $BIN_DIR/gpt-toggle"
    # 4) systemd units -> enable, then RESTART (enable --now won't restart an already
    #    running unit, so a changed unit file would otherwise keep the stale process)
    mkdir -p "$UNIT_DIR"
    for u in chatgpt-bridge.service chatgpt-router.service chatgpt-model-refresh.service chatgpt-model-refresh.timer; do
      backup "$UNIT_DIR/$u"; cp "$CT_SRC/systemd/$u" "$UNIT_DIR/$u"
    done
    systemctl --user daemon-reload
    systemctl --user enable --now chatgpt-bridge.service chatgpt-router.service chatgpt-model-refresh.timer >/dev/null 2>&1 || true
    systemctl --user restart chatgpt-bridge.service chatgpt-router.service >/dev/null 2>&1 || true
    ok "services enabled: bridge :18765, router :8788, daily model refresh"
    # 5) Resolve the newest working ChatGPT model for the default (needs bridge auth).
    if gpt-toggle refresh >/dev/null 2>&1; then
      ok "default ChatGPT model: $(cat "$HOME/.config/chatgpt-toggle/model-default" 2>/dev/null)"
    else
      info "run 'gpt-toggle refresh' after bridge login to pick the newest ChatGPT model"
    fi
    # 6) Point Claude Code at the router — ONLY once it actually answers. A fresh
    #    'uv run router.py' first downloads starlette/httpx/uvicorn, so poll with retry.
    #    If it never comes up, LEAVE :8787 (headroom-direct) — a safe degrade, not a brick.
    router_up=0
    for _ in $(seq 1 40); do
      curl -fsS --max-time 2 http://127.0.0.1:8788/healthz >/dev/null 2>&1 && { router_up=1; break; }
      sleep 1
    done
    SET="$CLAUDE_DIR/settings.json"
    if [ "$router_up" = 1 ] && command -v jq >/dev/null 2>&1; then
      tmp="$(mktemp)"
      if jq '.env.ANTHROPIC_BASE_URL="http://127.0.0.1:8788"
             | .env.ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-sonnet-5"' "$SET" > "$tmp" 2>/dev/null \
         && [ -s "$tmp" ]; then
        backup "$SET"; mv "$tmp" "$SET"
        ok "Claude Code -> router :8788 (main model toggleable; housekeeping on Sonnet 5)"
      else
        rm -f "$tmp"; warn "could not edit settings.json env — Claude Code left on :8787"
      fi
    else
      warn "router not answering on :8788 — Claude Code left on headroom :8787 (check: systemctl --user status chatgpt-router)"
    fi
    # 7) The GPT path needs a one-time browser login (cannot be automated here).
    if claude-code-proxy codex auth status >/dev/null 2>&1; then
      ok "claude-code-proxy already authed to your ChatGPT subscription"
    else
      info "GPT path (one-time): claude-code-proxy codex auth device   # browser login, ChatGPT account"
      info "  then flip on with: gpt-toggle on   (off again: gpt-toggle off)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
step "Seed mempalace (memory) — one-time setup"
# Retrieval is fully local/zero-API. The embedding model downloads lazily on the
# first embedding op (init/mine/search). The palace + per-project wings are a
# one-time, network/disk-heavy step, so we guide rather than auto-run on every init.
if [ -d "$HOME/.mempalace/palace" ]; then
  ok "mempalace palace already present at ~/.mempalace/palace"
  # Record the embedder identity (minilm) on legacy palaces that predate RFC 001.
  # Without it, every embedding op prints EmbedderIdentityUnknownWarning. Idempotent:
  # re-running just confirms the already-recorded identity. Does NOT re-embed.
  mempalace palace set-embedder --model minilm >/dev/null 2>&1 \
    && ok "mempalace embedder identity recorded (minilm)" \
    || warn "could not record mempalace embedder identity"
else
  info "first-time setup (one-time, ~300MB model + indexing):"
  info "  mempalace init \"\$HOME\"                                  # create the global palace"
  info "  mempalace mine ~/.claude/projects/ --mode convos       # seed memory from transcripts"
  info "  recall is zero-API (local embeddings). LLM entity-refinement is optional:"
  info "  default --llm-model gemma4:e4b via Ollama, or --no-llm for heuristics only."
fi

# ---------------------------------------------------------------------------
step "mempalace prune scheduler (daily)"
# The Stop hook mines the whole session dir in convos mode (which ignores .gitignore
# and has no exclude), so it re-ingests tool-result/subagent noise that can only be
# removed after ingest. A daily job prunes it (see tools/mempalace/mempalace-prune.py).
mkdir -p "$HOME/.mempalace/logs"
if [ "$OS" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  dest="$LAUNCH_DIR/com.user.mempalace-prune.plist"
  mkdir -p "$LAUNCH_DIR"
  backup "$dest"
  sed "s#__HOME__#$HOME#g" "$REPO_DIR/tools/mempalace/com.user.mempalace-prune.plist" > "$dest"
  launchctl unload "$dest" >/dev/null 2>&1 || true
  launchctl load -w "$dest" && ok "daily prune scheduled (launchd, 03:47)" \
    || warn "could not load prune plist"
elif command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  for u in mempalace-prune.service mempalace-prune.timer; do
    backup "$UNIT_DIR/$u"
    cp "$REPO_DIR/tools/mempalace/$u" "$UNIT_DIR/$u"
  done
  systemctl --user daemon-reload
  systemctl --user enable --now mempalace-prune.timer \
    && ok "daily prune scheduled (systemd timer, 03:47)" \
    || warn "could not enable mempalace-prune.timer"
else
  warn "skipped (no scheduler). Run daily: mempalace's python on $BIN_DIR/mempalace-prune.py"
fi

# ---------------------------------------------------------------------------
step "mempalace snapshot scheduler (every 6h)"
# A crashed/SIGKILL'd writer can corrupt the derived HNSW + FTS5 indexes (ChromaDB
# writes aren't crash-atomic). chroma.sqlite3 is the transactional source of truth,
# so a periodic online .backup of it makes any such corruption fully rebuildable
# (mempalace repair --mode from-sqlite). Pairs with the SessionStart self-heal hook.
mkdir -p "$HOME/.mempalace/logs"
if [ "$OS" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  dest="$LAUNCH_DIR/com.user.mempalace-snapshot.plist"
  mkdir -p "$LAUNCH_DIR"
  backup "$dest"
  sed "s#__HOME__#$HOME#g" "$REPO_DIR/tools/mempalace/com.user.mempalace-snapshot.plist" > "$dest"
  launchctl unload "$dest" >/dev/null 2>&1 || true
  launchctl load -w "$dest" && ok "6h snapshot scheduled (launchd)" \
    || warn "could not load snapshot plist"
elif command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  for u in mempalace-snapshot.service mempalace-snapshot.timer; do
    backup "$UNIT_DIR/$u"
    cp "$REPO_DIR/tools/mempalace/$u" "$UNIT_DIR/$u"
  done
  systemctl --user daemon-reload
  systemctl --user enable --now mempalace-snapshot.timer \
    && ok "6h snapshot scheduled (systemd timer)" \
    || warn "could not enable mempalace-snapshot.timer"
else
  warn "skipped (no scheduler). Run periodically: $BIN_DIR/mempalace-snapshot.sh"
fi

# ---------------------------------------------------------------------------
step "graphify→mempalace reseed (SessionStart hook)"
# Reseeding is triggered by a throttled SessionStart hook
# (workflow/hooks/graphify-reseed-session.sh), NOT a wall-clock cron: the laptop is
# off at night, so a nightly timer never fires. The hook runs when a session
# starts (machine on), at most once per ~12h. It is NUDGE-ONLY: it asks the agent
# (via additionalContext) to refresh through the in-process MCP mine tool — the
# only safe in-session writer — and mines nothing itself. A competing CLI mine
# alongside the live MCP server corrupts the palace's FTS5 index, so the hook never
# runs one. See workflow/hooks/graphify-reseed-session.sh.
reseed_repos=()
for repo in "${GRAPHIFY_REPOS[@]}"; do
  if [ -d "$repo" ]; then
    reseed_repos+=("$repo")
  else
    warn "skipping missing graphify reseed repo: $repo"
  fi
done
if [ "${#reseed_repos[@]}" -eq 0 ]; then
  reseed_repos=("$REPO_DIR")
fi
# Persist the repo list for the hook to read.
mkdir -p "$HOME/.mempalace"
printf '%s\n' "${reseed_repos[@]}" > "$HOME/.mempalace/graphify-repos.conf"
ok "reseed repo list -> ~/.mempalace/graphify-repos.conf (${#reseed_repos[@]} repo(s))"
# Migrate older installs: remove the now-retired nightly cron if present.
if [ "$OS" = "Darwin" ] && command -v launchctl >/dev/null 2>&1; then
  old="$LAUNCH_DIR/com.user.graphify-reseed.plist"
  if [ -f "$old" ]; then launchctl unload "$old" >/dev/null 2>&1 || true; rm -f "$old"; ok "removed retired nightly reseed cron (now session-triggered)"; fi
elif command -v systemctl >/dev/null 2>&1; then
  old="$UNIT_DIR/graphify-reseed.timer"
  if [ -f "$old" ]; then
    systemctl --user disable --now graphify-reseed.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/graphify-reseed.timer" "$UNIT_DIR/graphify-reseed.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ok "removed retired nightly reseed timer (now session-triggered)"
  fi
fi

# ---------------------------------------------------------------------------
step "mempalace Stop-hook timeout (anti-corruption)"
# The plugin ships a 30s Stop-hook timeout; a slow capture flush gets SIGKILL'd
# mid-write and corrupts the (non-atomic) HNSW+FTS5 index. Bump to 90s. The plugin
# rewrites hooks.json on (re)install, so this is best-effort here (the plugin may
# not be installed yet on first run) and MUST be re-run after 'claude' login and
# after every mempalace plugin update.
"$BIN_DIR/mempalace-stop-timeout.sh" 2>&1 | sed 's/^/  /' || true
# Detach the Stop-hook ingest so turn-end never blocks on it (and the writer is
# never SIGKILL'd mid-write). Same lifecycle: plugin (re)install reverts it.
"$BIN_DIR/mempalace-stop-detach.sh" 2>&1 | sed 's/^/  /' || true
info "re-run '$BIN_DIR/mempalace-stop-timeout.sh' and '$BIN_DIR/mempalace-stop-detach.sh' after 'claude' login and after mempalace plugin updates"

# ---------------------------------------------------------------------------
step "Verify"
sleep 1
if curl -fsS --max-time 5 http://127.0.0.1:8787/health >/dev/null 2>&1; then
  ok "headroom proxy healthy at http://127.0.0.1:8787"
  command -v headroom-watch >/dev/null 2>&1 && info "run 'headroom-watch' to watch compression live"
else
  warn "headroom proxy not answering yet — check: $STATUS_HR"
fi

cat <<EOF

${c_grn}Done.${c_rst}

  ${c_grn}Request flow${c_rst}
  ----------------------------------------------------------------------
                              .- off -> headroom :8787 -> Claude
     claude  ->  router :8788 -|
      (ANTHROPIC_BASE_URL)     '- on  -> bridge  :18765 -> ChatGPT (your sub)

     graphify / codex ----------------> headroom :8787 -> Claude
       (always Claude -- never see the toggle)

     memory: mempalace (local, zero-API)   code graph: graphify

  ${c_grn}ChatGPT toggle${c_rst}   ${c_dim}(Linux/systemd)${c_rst}
  ----------------------------------------------------------------------
     ${c_dim}gpt-toggle on | off | status${c_rst}         flip the main model, live
     ${c_dim}gpt-toggle model [<name> | auto]${c_rst}     pick a model / dynamic default
     ${c_dim}gpt-toggle effort [<low..max>]${c_rst}       reasoning effort, all GPT requests
     ${c_dim}gpt-toggle refresh${c_rst}                   re-resolve newest available

  ${c_grn}Next${c_rst}
  ----------------------------------------------------------------------
     1) ${c_dim}claude${c_rst}                  start Claude Code (auto-installs plugins); log in
     2) ${c_dim}headroom-watch${c_rst}          optional -- watch token compression live
     3) seed memory (one-time):
        ${c_dim}mempalace init "\$HOME" && mempalace mine ~/.claude/projects/ --mode convos${c_rst}
     4) ChatGPT path (one-time browser login):
        ${c_dim}claude-code-proxy codex auth device${c_rst}  then  ${c_dim}gpt-toggle on${c_rst}

  ${c_dim}No secrets were copied by this repo -- you log in interactively.${c_rst}
EOF
