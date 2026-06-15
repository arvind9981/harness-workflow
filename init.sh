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
CLAUDE_DIR="$HOME/.claude"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

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

# ---------------------------------------------------------------------------
step "Prerequisites"
missing=()
for c in git curl jq; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
command -v systemctl >/dev/null 2>&1 || warn "systemctl not found — the headroom proxy service step will be skipped"
[ "${#missing[@]}" -eq 0 ] || die "install these first via your package manager: ${missing[*]}"
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
uv tool install --upgrade headroom-ai >/dev/null 2>&1 && ok "headroom-ai installed/upgraded" \
  || die "uv tool install headroom-ai failed"

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

# ---------------------------------------------------------------------------
step "Headroom proxy service"
if command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  backup "$UNIT_DIR/headroom-proxy.service"
  cp "$REPO_DIR/tools/headroom/headroom-proxy.service" "$UNIT_DIR/headroom-proxy.service"
  systemctl --user daemon-reload
  systemctl --user enable --now headroom-proxy.service
  ok "headroom-proxy.service enabled and started"
  info "tip: 'loginctl enable-linger $USER' keeps the proxy alive without an active login"
else
  warn "skipped (no systemctl). Run manually: headroom proxy --port 8787 --host 127.0.0.1"
fi

# ---------------------------------------------------------------------------
step "Verify"
sleep 1
if curl -fsS --max-time 5 http://127.0.0.1:8787/health >/dev/null 2>&1; then
  ok "proxy healthy at http://127.0.0.1:8787"
  command -v headroom-watch >/dev/null 2>&1 && info "run 'headroom-watch' to watch compression live"
else
  warn "proxy not answering yet — check: systemctl --user status headroom-proxy"
fi

cat <<EOF

${c_grn}Done.${c_rst} Next:
  1) Start Claude Code:  ${c_dim}claude${c_rst}   (it auto-installs the plugins in settings.json)
  2) Log in when prompted (no tokens were copied by this repo).
  3) Optional: ${c_dim}headroom-watch${c_rst} to monitor token compression.
EOF
