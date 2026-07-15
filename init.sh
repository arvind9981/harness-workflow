#!/usr/bin/env bash
# init.sh — reproduce my Claude Code workflow on a fresh machine.
#
#   git clone <this repo> && cd harness-workflow && ./init.sh
#
#   ./init.sh --help
#   ./init.sh --codex
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
  --codex                Require Codex setup; fail if no Codex executable is found.
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
  With no graphify repos configured, init tracks this harness-workflow repo only.
EOF
}

INSTALL_DESKTOP=1
INSTALL_CODEX=auto
GRAPHIFY_REPOS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex) INSTALL_CODEX=1 ;;
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
. "$REPO_DIR/tools/codex/lib.sh"
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
HEADROOM_VERSION="${HEADROOM_VERSION:-0.31.0}"
MEMPALACE_VERSION="${MEMPALACE_VERSION:-3.5.0}"
GRAPHIFY_VERSION="${GRAPHIFY_VERSION:-0.9.16}"

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

replace_if_changed() { # replace_if_changed <rendered> <destination>
  local rendered="$1" destination="$2"
  if [ -f "$destination" ] && cmp -s "$rendered" "$destination"; then
    rm -f "$rendered"
    return 1
  fi
  mkdir -p "$(dirname "$destination")"
  backup "$destination"
  mv "$rendered" "$destination"
  return 0
}

install_if_changed() { # install_if_changed <source> <destination> <mode>
  local source_file="$1" destination="$2" mode="$3"
  if [ -f "$destination" ] && cmp -s "$source_file" "$destination"; then
    chmod "$mode" "$destination"
    return 1
  fi
  mkdir -p "$(dirname "$destination")"
  backup "$destination"
  install -m "$mode" "$source_file" "$destination"
  return 0
}

ensure_uv_tool() { # ensure_uv_tool <label> <command> <version> <uv-spec>
  local label="$1" command="$2" version="$3" spec="$4" current=""
  if command -v "$command" >/dev/null 2>&1; then
    current="$("$command" --version 2>/dev/null || true)"
  fi
  if printf '%s' "$current" | grep -Eq "(^|[^0-9])${version//./\\.}([^0-9]|$)"; then
    ok "$label $version already installed"
    return 0
  fi
  uv tool install --force "$spec" >/dev/null 2>&1
}

reconcile_claude_md() { # preserve user text; own only the marked workflow block
  local destination="$CLAUDE_DIR/CLAUDE.md" rendered
  rendered="$(mktemp)"
  python3 - "$destination" "$REPO_DIR/claude/CLAUDE.md" "$rendered" <<'PY'
from pathlib import Path
import re
import sys

destination, managed_path, output = map(Path, sys.argv[1:])
current = destination.read_text(encoding="utf-8") if destination.exists() else ""
managed = managed_path.read_text(encoding="utf-8").strip()
block = re.compile(
    r"<!-- BEGIN HARNESS-WORKFLOW MANAGED -->.*?"
    r"<!-- END HARNESS-WORKFLOW MANAGED -->",
    re.DOTALL,
)
current = re.sub(r"\n## graphify\n.*\Z", "", current, flags=re.DOTALL).strip()
legacy = (
    current.startswith("# Global instructions")
    and "## Memory & tooling defaults" in current
    and "Recall before re-deriving" in current
)
if block.search(current):
    result = block.sub(managed, current).strip()
elif legacy or not current:
    result = managed
else:
    result = f"{current}\n\n{managed}"
output.write_text(result + "\n", encoding="utf-8")
PY
  if replace_if_changed "$rendered" "$destination"; then
    ok "CLAUDE.md managed workflow block reconciled"
  else
    ok "CLAUDE.md managed workflow block already current"
  fi
}

svc_enable() {  # svc_enable <linux_unit_file> <mac_plist_file> — install + start a background service
  local linux_unit="$1" mac_plist="$2"
  if [ "$OS" = "Darwin" ]; then
    mkdir -p "$LAUNCH_DIR" "$HOME/Library/Logs"
    local dest; dest="$LAUNCH_DIR/$(basename "$mac_plist")"
    local rendered; rendered="$(mktemp)"
    sed "s#__HOME__#$HOME#g" "$mac_plist" > "$rendered" # launchd has no %h specifier
    if replace_if_changed "$rendered" "$dest"; then
      launchctl unload "$dest" 2>/dev/null || true
      if launchctl load -w "$dest"; then
        ok "$(basename "$dest") loaded (launchd)"
      else
        die "launchctl load failed for $(basename "$dest")"
      fi
    elif launchctl list "$(basename "$dest" .plist)" >/dev/null 2>&1 \
        || launchctl load -w "$dest"; then
      ok "$(basename "$dest") already current and loaded (launchd)"
    else
      die "launchctl load failed for $(basename "$dest")"
    fi
  else
    mkdir -p "$UNIT_DIR"
    local unit; unit="$(basename "$linux_unit")"
    if install_if_changed "$linux_unit" "$UNIT_DIR/$unit" 0644; then
      systemctl --user daemon-reload
      if systemctl --user enable --now "$unit"; then
        ok "$unit enabled and started (systemd)"
      else
        die "systemctl enable failed for $unit"
      fi
    elif systemctl --user is-active --quiet "$unit"; then
      ok "$unit already current and active (systemd)"
    else
      if systemctl --user enable --now "$unit"; then
        ok "$unit started (systemd)"
      else
        die "systemctl enable failed for $unit"
      fi
    fi
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
    if ! windows_home="$(cd /mnt/c 2>/dev/null && cmd.exe /d /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | tail -n 1)"; then
      windows_home=""
    fi
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
if ensure_uv_tool headroom headroom "$HEADROOM_VERSION" "headroom-ai[proxy]==$HEADROOM_VERSION"; then
  ok "headroom-ai[proxy] pinned at $HEADROOM_VERSION"
else
  die "uv tool install headroom-ai[proxy]==$HEADROOM_VERSION failed"
fi

# ---------------------------------------------------------------------------
step "Install mempalace (memory layer)"
# mempalace is the memory layer (local-first, verbatim recall, zero-API retrieval).
# The plugin auto-loads via settings.json; the CLI + native MCP server must be on
# PATH for the plugin's MCP (.mcp.json calls `mempalace-mcp`) and its Stop/PreCompact
# hooks (which call `mempalace`).
if ensure_uv_tool mempalace mempalace "$MEMPALACE_VERSION" "mempalace==$MEMPALACE_VERSION"; then
  ok "mempalace pinned at $MEMPALACE_VERSION"
else
  die "uv tool install mempalace==$MEMPALACE_VERSION failed"
fi
if command -v mempalace-mcp >/dev/null 2>&1; then
  ok "mempalace-mcp (native MCP) present"
else
  warn "mempalace-mcp missing — MCP wiring will fail"
fi
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
if ensure_uv_tool graphify graphify "$GRAPHIFY_VERSION" "graphifyy==$GRAPHIFY_VERSION"; then
  ok "graphifyy pinned at $GRAPHIFY_VERSION"
else
  warn "uv tool install graphifyy==$GRAPHIFY_VERSION failed — graphify features will be skipped"
fi
if command -v graphify >/dev/null 2>&1; then
  ok "graphify CLI present"
else
  warn "graphify missing — skill registration will be skipped"
fi

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
install_if_changed "$REPO_DIR/tools/headroom/headroom-watch" "$BIN_DIR/headroom-watch" 0755 || true
ok "headroom-watch -> $BIN_DIR/headroom-watch"
install_if_changed "$REPO_DIR/tools/headroom/headroom-canary" "$BIN_DIR/headroom-canary" 0755 || true
ok "headroom-canary -> $BIN_DIR/headroom-canary (opt-in :8788)"
install_if_changed "$REPO_DIR/tools/mempalace/mempalace-prune.py" "$BIN_DIR/mempalace-prune.py" 0755 || true
ok "mempalace-prune.py -> $BIN_DIR/mempalace-prune.py"
install_if_changed "$REPO_DIR/tools/graphify/graphify-reseed.sh" "$BIN_DIR/graphify-reseed.sh" 0755 || true
ok "graphify-reseed.sh -> $BIN_DIR/graphify-reseed.sh"
install_if_changed "$REPO_DIR/tools/graphify/graphify-complete-map.sh" "$BIN_DIR/graphify-complete-map.sh" 0755 || true
ok "graphify-complete-map.sh -> $BIN_DIR/graphify-complete-map.sh"
install_if_changed "$REPO_DIR/tools/graphify/graphify-sync.sh" "$BIN_DIR/graphify-sync.sh" 0755 || true
ok "graphify-sync.sh -> $BIN_DIR/graphify-sync.sh"
install_if_changed "$REPO_DIR/tools/graphify/reseed-verify.sh" "$BIN_DIR/reseed-verify.sh" 0755 || true
ok "reseed-verify.sh -> $BIN_DIR/reseed-verify.sh"
install_if_changed "$REPO_DIR/tools/mempalace/mempalace-snapshot.sh" "$BIN_DIR/mempalace-snapshot.sh" 0755 || true
ok "mempalace-snapshot.sh -> $BIN_DIR/mempalace-snapshot.sh"
install_if_changed "$REPO_DIR/tools/mempalace/mempalace-stop-timeout.sh" "$BIN_DIR/mempalace-stop-timeout.sh" 0755 || true
ok "mempalace-stop-timeout.sh -> $BIN_DIR/mempalace-stop-timeout.sh"
install_if_changed "$REPO_DIR/tools/mempalace/mempalace-stop-detach.sh" "$BIN_DIR/mempalace-stop-detach.sh" 0755 || true
ok "mempalace-stop-detach.sh -> $BIN_DIR/mempalace-stop-detach.sh"
case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) warn "$BIN_DIR is not on your PATH — add it to use the headroom CLI" ;; esac

# ---------------------------------------------------------------------------
step "Install Claude settings"
mkdir -p "$CLAUDE_DIR"
# Reconcile repo-owned keys while preserving personal permissions, plugins,
# hooks, preferences, and instruction text.
current_settings="$(mktemp)"
managed_settings="$(mktemp)"
merged_settings="$(mktemp)"
[ -s "$CLAUDE_DIR/settings.json" ] && cp "$CLAUDE_DIR/settings.json" "$current_settings" \
  || printf '{}\n' > "$current_settings"
sed "s#__HOME__#$HOME#g" "$REPO_DIR/claude/settings.json" > "$managed_settings"
if ! jq -s '
  .[0] as $current | .[1] as $managed |
  def owned_command:
    test("headroom-init-claude|/\\.claude/hooks/(headroom-health|mempalace-|graphify-)");
  $current
  | .env = (($current.env // {}) + ($managed.env // {}))
  | .enabledPlugins = (($current.enabledPlugins // {}) + ($managed.enabledPlugins // {}))
  | .extraKnownMarketplaces = (($current.extraKnownMarketplaces // {}) + ($managed.extraKnownMarketplaces // {}))
  | .statusLine = $managed.statusLine
  | .theme = ($current.theme // $managed.theme)
  | .hooks = reduce (($managed.hooks // {}) | to_entries[]) as $event
      (($current.hooks // {});
       .[$event.key] = (
         [(.[$event.key] // [])[]
          | .hooks = [(.hooks // [])[]
              | select(((.command // "") | owned_command) | not)]
          | select((.hooks | length) > 0)] + $event.value
       ))
' "$current_settings" "$managed_settings" > "$merged_settings"; then
  rm -f "$current_settings" "$managed_settings" "$merged_settings"
  die "Claude settings.json is not valid JSON"
fi
rm -f "$current_settings" "$managed_settings"
if replace_if_changed "$merged_settings" "$CLAUDE_DIR/settings.json"; then
  ok "settings.json workflow keys reconciled; unrelated settings preserved"
else
  ok "settings.json workflow keys already current"
fi

current_local="$(mktemp)"
merged_local="$(mktemp)"
[ -s "$CLAUDE_DIR/settings.local.json" ] && cp "$CLAUDE_DIR/settings.local.json" "$current_local" \
  || printf '{}\n' > "$current_local"
if ! jq -s '
  .[0] as $current | .[1] as $managed |
  $current
  | .permissions = (($current.permissions // {}) + {
      allow: (((($current.permissions // {}).allow // []) +
        (($managed.permissions // {}).allow // [])) | unique)
    })
' "$current_local" "$REPO_DIR/claude/settings.local.json" > "$merged_local"; then
  rm -f "$current_local" "$merged_local"
  die "Claude settings.local.json is not valid JSON"
fi
rm -f "$current_local"
if replace_if_changed "$merged_local" "$CLAUDE_DIR/settings.local.json"; then
  ok "settings.local.json managed permissions merged; personal rules preserved"
else
  ok "settings.local.json managed permissions already current"
fi

reconcile_claude_md
# statusline script: deploy to ~/.claude (referenced by settings.json statusLine.command)
if [ -f "$REPO_DIR/claude/statusline-command.sh" ]; then
  install_if_changed "$REPO_DIR/claude/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh" 0755 || true
  ok "statusline-command.sh -> $CLAUDE_DIR/"
fi
# shared hooks: deploy repo-owned lifecycle scripts referenced by settings.json
if [ -d "$REPO_DIR/workflow/hooks" ]; then
  mkdir -p "$CLAUDE_DIR/hooks"
  for h in "$REPO_DIR"/workflow/hooks/*.sh; do
    [ -e "$h" ] || continue
    install_if_changed "$h" "$CLAUDE_DIR/hooks/$(basename "$h")" 0755 || true
    ok "hook $(basename "$h") -> $CLAUDE_DIR/hooks/"
  done
fi

# workflows: deploy saved Workflow scripts (e.g. fable-review) for name-based invocation
if [ -d "$REPO_DIR/claude/workflows" ]; then
  mkdir -p "$CLAUDE_DIR/workflows"
  for w in "$REPO_DIR"/claude/workflows/*.js; do
    [ -e "$w" ] || continue
    install_if_changed "$w" "$CLAUDE_DIR/workflows/$(basename "$w")" 0644 || true
    ok "workflow $(basename "$w") -> $CLAUDE_DIR/workflows/"
  done
fi

step "Codex workflow (auto-detected)"
# The WSL CLI and Windows Codex App use different Codex homes. Install the shared
# workflow into ~/.codex when either surface is found, while portable discovery
# also covers CODEX_BIN, PATH, and supported macOS app bundles. The Windows app
# receives a bridge whose commands explicitly re-enter this distro. Never copy
# config.toml across: the app owns Windows-specific plugin and runtime paths there.
WINDOWS_CODEX_DIR="$(detect_windows_codex_dir || true)"
codex_bin="$(codex_resolve_bin || true)"
if [ -n "$codex_bin" ] || [ -n "$WINDOWS_CODEX_DIR" ]; then
  if [ -n "$codex_bin" ]; then
    CODEX_BIN="$codex_bin" bash "$REPO_DIR/tools/codex/install-codex.sh"
    doctor_command=(env CODEX_BIN="$codex_bin" bash "$REPO_DIR/tools/codex/doctor-workflow.sh")
  else
    bash "$REPO_DIR/tools/codex/install-codex.sh"
    doctor_command=(bash "$REPO_DIR/tools/codex/doctor-workflow.sh")
  fi
  if "${doctor_command[@]}"; then
    ok "Codex workflow verified"
  else
    warn "Codex workflow installed; doctor reported local follow-up"
  fi

  if [ -n "$codex_bin" ]; then
    ok "Codex detected at $codex_bin — hooks/instructions migrated into ~/.codex"
    CODEX_BIN="$codex_bin" bash "$REPO_DIR/tools/model-team/install-model-team.sh"
    if CODEX_BIN="$codex_bin" bash "$REPO_DIR/tools/model-team/doctor-model-team.sh"; then
      ok "Claude–Codex model-team verified"
    else
      warn "Model-team installed; doctor reported local follow-up"
    fi
  else
    ok "Windows Codex App detected — shared workflow migrated into ~/.codex"
  fi

  if [ -n "$WINDOWS_CODEX_DIR" ] && [ -n "$WSL_DISTRO" ]; then
    install_windows_codex_bridge "$WINDOWS_CODEX_DIR" || warn "Windows Codex App bridge needs local follow-up"
  elif [ "$IS_WSL" = 1 ] && [ -z "$WSL_DISTRO" ]; then
    warn "WSL detected without a distro name; set CODEX_WSL_DISTRO and re-run init.sh for the Windows Codex bridge"
  elif [ "$IS_WSL" = 1 ]; then
    warn "WSL detected but the Windows Codex home was ambiguous; set CODEX_WINDOWS_DIR and re-run init.sh"
  fi
elif [ "$INSTALL_CODEX" = 1 ]; then
  die "--codex requested, but no Codex CLI/App was found through portable discovery"
else
  info "Codex CLI/App not installed — skipping (nothing to migrate)"
fi

step "OpenCode workflow (auto-detected)"
# OpenCode keeps its own native Sol/Terra agents. The installer adds the bounded
# Claude worker MCP used for automatic Sonnet/Fable planning and review, pins
# both provider paths through Headroom, and preserves unrelated user settings.
if command -v opencode >/dev/null 2>&1; then
  bash "$REPO_DIR/tools/opencode/install-opencode.sh"
  if bash "$REPO_DIR/tools/opencode/doctor-workflow.sh"; then
    ok "OpenCode workflow verified"
  else
    warn "OpenCode workflow installed; doctor reported local follow-up"
  fi
  ok "OpenCode detected — native agents, automatic routing, and Claude worker MCP installed"
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
  graphify_skill_version="$CLAUDE_DIR/skills/graphify/.graphify_version"
  if [ -f "$graphify_skill_version" ] \
      && [ "$(cat "$graphify_skill_version")" = "$GRAPHIFY_VERSION" ]; then
    ok "graphify skill $GRAPHIFY_VERSION already registered"
  else
    if graphify install --platform claude >/dev/null 2>&1; then
      ok "graphify skill registered"
    else
      warn "graphify install failed"
    fi
    reconcile_claude_md
  fi
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
  warn "skipped (no service manager). Run manually: headroom proxy --port 8787 --host 127.0.0.1 --mode cache --no-cache"
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
  if mempalace palace set-embedder --model minilm >/dev/null 2>&1; then
    ok "mempalace embedder identity recorded (minilm)"
  else
    warn "could not record mempalace embedder identity"
  fi
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
  rendered="$(mktemp)"
  sed "s#__HOME__#$HOME#g" "$REPO_DIR/tools/mempalace/com.user.mempalace-prune.plist" > "$rendered"
  if replace_if_changed "$rendered" "$dest"; then launchctl unload "$dest" >/dev/null 2>&1 || true; fi
  if launchctl list com.user.mempalace-prune >/dev/null 2>&1 \
      || launchctl load -w "$dest"; then
    ok "daily prune scheduled (launchd, 03:47)"
  else
    warn "could not load prune plist"
  fi
elif command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  units_changed=0
  for u in mempalace-prune.service mempalace-prune.timer; do
    if install_if_changed "$REPO_DIR/tools/mempalace/$u" "$UNIT_DIR/$u" 0644; then units_changed=1; fi
  done
  [ "$units_changed" = 0 ] || systemctl --user daemon-reload
  if systemctl --user enable --now mempalace-prune.timer; then
    ok "daily prune scheduled (systemd timer, 03:47)"
  else
    warn "could not enable mempalace-prune.timer"
  fi
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
  rendered="$(mktemp)"
  sed "s#__HOME__#$HOME#g" "$REPO_DIR/tools/mempalace/com.user.mempalace-snapshot.plist" > "$rendered"
  if replace_if_changed "$rendered" "$dest"; then launchctl unload "$dest" >/dev/null 2>&1 || true; fi
  if launchctl list com.user.mempalace-snapshot >/dev/null 2>&1 \
      || launchctl load -w "$dest"; then
    ok "6h snapshot scheduled (launchd)"
  else
    warn "could not load snapshot plist"
  fi
elif command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  units_changed=0
  for u in mempalace-snapshot.service mempalace-snapshot.timer; do
    if install_if_changed "$REPO_DIR/tools/mempalace/$u" "$UNIT_DIR/$u" 0644; then units_changed=1; fi
  done
  [ "$units_changed" = 0 ] || systemctl --user daemon-reload
  if systemctl --user enable --now mempalace-snapshot.timer; then
    ok "6h snapshot scheduled (systemd timer)"
  else
    warn "could not enable mempalace-snapshot.timer"
  fi
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
     claude / graphify ---------------> headroom :8787 -> Claude
     codex ---------------------------> headroom :8787 -> native backend

     memory: mempalace (local, zero-API)   code graph: graphify

  ${c_grn}Next${c_rst}
  ----------------------------------------------------------------------
     1) ${c_dim}claude${c_rst}                  start Claude Code (auto-installs plugins); log in
     2) ${c_dim}headroom-watch${c_rst}          optional -- watch token compression live
     3) ${c_dim}model-team-watch${c_rst}         optional -- watch Codex worker activity
     4) seed memory (one-time):
        ${c_dim}mempalace init "\$HOME" && mempalace mine ~/.claude/projects/ --mode convos${c_rst}

  ${c_dim}No secrets were copied by this repo -- you log in interactively.${c_rst}
EOF
