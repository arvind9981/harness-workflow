#!/usr/bin/env bash
# init.sh — reproduce my Claude Code workflow on a fresh machine.
#
#   git clone <this repo> && cd claude-workflow && ./init.sh
#
# No secrets travel with this repo. After running, start `claude` and log in
# interactively — Claude Code auto-installs the plugins declared in settings.json.
#
# Idempotent: every file it overwrites is backed up first (timestamped .bak-init).

set -euo pipefail

# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OS="$(uname -s)"                           # Linux | Darwin
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"      # systemd user units (Linux)
LAUNCH_DIR="$HOME/Library/LaunchAgents"    # launchd LaunchAgents (macOS)

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

backup() {  # backup <path> — copy aside if it exists and differs from what we'll write
  [ -e "$1" ] && cp -p "$1" "$1.bak-init-$STAMP" && info "backed up $(basename "$1") -> $(basename "$1").bak-init-$STAMP"
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

# ---------------------------------------------------------------------------
step "Install scripts"
mkdir -p "$BIN_DIR"
backup "$BIN_DIR/headroom-watch"
install -m 0755 "$REPO_DIR/tools/headroom/headroom-watch" "$BIN_DIR/headroom-watch"
ok "headroom-watch -> $BIN_DIR/headroom-watch"
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
# hooks: deploy any repo hook scripts (e.g. mempalace recall) referenced by settings.json
if [ -d "$REPO_DIR/claude/hooks" ]; then
  mkdir -p "$CLAUDE_DIR/hooks"
  for h in "$REPO_DIR"/claude/hooks/*.sh; do
    [ -e "$h" ] || continue
    backup "$CLAUDE_DIR/hooks/$(basename "$h")"
    install -m 0755 "$h" "$CLAUDE_DIR/hooks/$(basename "$h")"
    ok "hook $(basename "$h") -> $CLAUDE_DIR/hooks/"
  done
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
step "Seed mempalace (memory) — one-time setup"
# Retrieval is fully local/zero-API. The embedding model downloads lazily on the
# first embedding op (init/mine/search). The palace + per-project wings are a
# one-time, network/disk-heavy step, so we guide rather than auto-run on every init.
if [ -d "$HOME/.mempalace/palace" ]; then
  ok "mempalace palace already present at ~/.mempalace/palace"
else
  info "first-time setup (one-time, ~300MB model + indexing):"
  info "  mempalace init \"\$HOME\"                                  # create the global palace"
  info "  mempalace mine ~/.claude/projects/ --mode convos       # seed memory from transcripts"
  info "  recall is zero-API (local embeddings). LLM entity-refinement is optional:"
  info "  default --llm-model gemma4:e4b via Ollama, or --no-llm for heuristics only."
fi

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

${c_grn}Done.${c_rst} Next:
  1) Start Claude Code:  ${c_dim}claude${c_rst}   (it auto-installs the plugins in settings.json)
  2) Log in when prompted (no tokens were copied by this repo).
  3) Optional: ${c_dim}headroom-watch${c_rst} to monitor token compression.
  4) Seed memory (one-time): ${c_dim}mempalace init "\$HOME"${c_rst} then
     ${c_dim}mempalace mine ~/.claude/projects/ --mode convos${c_rst}.
EOF
