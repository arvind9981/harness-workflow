# claude-workflow

My portable Claude Code setup. Clone it on a new machine, run the init script,
log in — done.

```bash
git clone <this-repo> claude-workflow
cd claude-workflow
./init.sh
claude          # auto-installs plugins from settings.json; log in when prompted
```

## What it sets up

- **Claude settings** (`claude/settings.json`) — enabled plugins, marketplaces,
  headroom proxy routing (`ANTHROPIC_BASE_URL=127.0.0.1:8787`), and hooks. Paths
  are stored as `__HOME__` and resolved to your real `$HOME` on install.
- **Permissions allowlist** (`claude/settings.local.json`) — 253 generic
  command allows, sanitized of any machine/project-specific paths.
- **Global instructions** (`claude/CLAUDE.md`) — standing cross-project
  preferences, installed to `~/.claude/CLAUDE.md` (backed up first).
- **Plugins** — *not* vendored. Claude Code installs them itself on first launch
  from the marketplaces declared in `settings.json`:
  superpowers, claude-mem, headroom, frontend-design, github, karpathy-skills.
- **headroom** — installed as a `uv` tool (`headroom-ai`), plus:
  - `tools/headroom/headroom-watch` → `~/.local/bin/` (live compression stats)
  - `tools/headroom/headroom-proxy.service` → systemd user service (Linux) /
    `com.user.headroom-proxy.plist` → launchd LaunchAgent (macOS), both auto-start
- **Local-model claude-mem routing** — claude-mem generates its observations on a
  local model instead of the cloud (zero rate limits, zero cost). See below.

## Local-model claude-mem routing

```
claude-mem  →  ANTHROPIC_BASE_URL=127.0.0.1:4000  →  LiteLLM gateway  →  Ollama (qwen3.6) on :11434
```

`init.sh` wires up the portable pieces automatically:

- installs `litellm` as a `uv` tool,
- `tools/litellm/qwen-proxy.yaml` → `~/.config/litellm/` (loopback-only, no secrets),
- `tools/litellm/litellm-qwen.service` → systemd user service (Linux) /
  `com.user.litellm-qwen.plist` → launchd LaunchAgent (macOS), auto-start on :4000,
- and surgically sets three keys in `~/.claude-mem/.env`
  (`ANTHROPIC_BASE_URL`, `CLAUDE_MEM_PROVIDER=claude`,
  `CLAUDE_MEM_CLAUDE_AUTH_METHOD=gateway`) — backing the file up first and leaving
  every other line, including your API keys, untouched. Skipped if claude-mem
  isn't installed yet; just re-run `init.sh` after your first `claude` launch.

**Prerequisites (not auto-installed — heavyweight & hardware-specific):**

- [Ollama](https://ollama.com) installed and running, and
- `ollama pull qwen3.6:latest` (~23 GB).

`init.sh` detects these and prints instructions if missing; the gateway starts
serving as soon as the model is present (`systemctl --user restart litellm-qwen`
on Linux, `launchctl kickstart -k gui/$(id -u)/com.user.litellm-qwen` on macOS).

## What it deliberately does NOT do

- **No secrets.** No OAuth tokens, API keys, or `.credentials.json`. You log in
  interactively after install.
- **No memory/history.** Your claude-mem observations and `memory/*.md` rebuild
  on the new machine as you work.

## Requirements

`git`, `curl`, `jq`. The two proxies run as background services: `systemd --user`
on **Linux**, `launchd` LaunchAgents (`launchctl`) on **macOS** — `init.sh` picks
the right one automatically. `uv` is installed for you if missing; on macOS install
`jq` via Homebrew (`brew install jq`). Claude Code itself must be installed
separately.

## Safety

`init.sh` is idempotent and timestamps a `.bak-init-*` copy of any file it
overwrites. Re-running it is safe.

## Codex

`codex/` is a placeholder — Codex bootstrap is not implemented yet.
