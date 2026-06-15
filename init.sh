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
LITELLM_DIR="$HOME/.config/litellm"
MEM_DIR="$HOME/.claude-mem"

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

upsert_env() {  # upsert_env <file> <KEY> <VALUE> — set KEY=VALUE, replacing or appending; other lines untouched
  local f="$1" k="$2" v="$3"
  touch "$f"
  # ensure file ends with a newline before we append
  [ -s "$f" ] && [ "$(tail -c1 "$f" | wc -l)" -eq 0 ] && printf '\n' >> "$f"
  if grep -qE "^${k}=" "$f"; then
    sed -i "s#^${k}=.*#${k}=${v}#" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
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
# CLAUDE.md: global standing instructions, copy verbatim
if [ -f "$REPO_DIR/claude/CLAUDE.md" ]; then
  backup "$CLAUDE_DIR/CLAUDE.md"
  cp "$REPO_DIR/claude/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  ok "CLAUDE.md (global standing instructions)"
fi

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
step "Install litellm (local-model gateway)"
uv tool install --upgrade 'litellm[proxy]' >/dev/null 2>&1 && ok "litellm[proxy] installed/upgraded" \
  || die "uv tool install 'litellm[proxy]' failed"
# proxy config (loopback-only, no secrets — no __HOME__ rendering needed)
mkdir -p "$LITELLM_DIR"
backup "$LITELLM_DIR/qwen-proxy.yaml"
cp "$REPO_DIR/tools/litellm/qwen-proxy.yaml" "$LITELLM_DIR/qwen-proxy.yaml"
ok "qwen-proxy.yaml -> $LITELLM_DIR/qwen-proxy.yaml"

# prerequisite: Ollama + the qwen3.6 model (heavyweight, not auto-installed)
if command -v ollama >/dev/null 2>&1; then
  if ollama list 2>/dev/null | grep -q 'qwen3.6'; then
    ok "ollama + qwen3.6 model present"
  else
    warn "ollama present but qwen3.6 missing — run: ollama pull qwen3.6:latest  (~23 GB)"
  fi
else
  warn "ollama not installed — install it, then 'ollama pull qwen3.6:latest' (~23 GB) to enable local-model routing"
fi

# ---------------------------------------------------------------------------
step "litellm proxy service"
if command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  backup "$UNIT_DIR/litellm-qwen.service"
  cp "$REPO_DIR/tools/litellm/litellm-qwen.service" "$UNIT_DIR/litellm-qwen.service"
  systemctl --user daemon-reload
  systemctl --user enable --now litellm-qwen.service
  ok "litellm-qwen.service enabled and started"
else
  warn "skipped (no systemctl). Run manually: litellm --config $LITELLM_DIR/qwen-proxy.yaml --port 4000 --host 127.0.0.1"
fi

# ---------------------------------------------------------------------------
step "Wire claude-mem to local gateway"
if [ -d "$MEM_DIR" ]; then
  backup "$MEM_DIR/.env"
  upsert_env "$MEM_DIR/.env" ANTHROPIC_BASE_URL "http://127.0.0.1:4000"
  upsert_env "$MEM_DIR/.env" CLAUDE_MEM_PROVIDER "claude"
  upsert_env "$MEM_DIR/.env" CLAUDE_MEM_CLAUDE_AUTH_METHOD "gateway"
  ok "claude-mem .env wired to local gateway (existing keys/secrets untouched)"
else
  info "claude-mem not installed yet — skipping .env wiring (re-run init.sh after first 'claude' launch)"
fi

# ---------------------------------------------------------------------------
step "Verify"
sleep 1
if curl -fsS --max-time 5 http://127.0.0.1:8787/health >/dev/null 2>&1; then
  ok "headroom proxy healthy at http://127.0.0.1:8787"
  command -v headroom-watch >/dev/null 2>&1 && info "run 'headroom-watch' to watch compression live"
else
  warn "headroom proxy not answering yet — check: systemctl --user status headroom-proxy"
fi
if curl -fsS --max-time 4 http://127.0.0.1:4000/health/readiness >/dev/null 2>&1; then
  ok "litellm gateway healthy at http://127.0.0.1:4000"
else
  warn "litellm gateway not ready yet — needs ollama + qwen3.6; check: systemctl --user status litellm-qwen"
fi

cat <<EOF

${c_grn}Done.${c_rst} Next:
  1) Start Claude Code:  ${c_dim}claude${c_rst}   (it auto-installs the plugins in settings.json)
  2) Log in when prompted (no tokens were copied by this repo).
  3) Optional: ${c_dim}headroom-watch${c_rst} to monitor token compression.
  4) For local-model claude-mem: install Ollama + ${c_dim}ollama pull qwen3.6:latest${c_rst} (~23 GB),
     then ${c_dim}systemctl --user restart litellm-qwen${c_rst}.
EOF
