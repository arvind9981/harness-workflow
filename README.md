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
- **Permissions allowlist** (`claude/settings.local.json`) — 234 generic
  command allows, sanitized of any machine/project-specific paths.
- **Plugins** — *not* vendored. Claude Code installs them itself on first launch
  from the marketplaces declared in `settings.json`:
  superpowers, claude-mem, headroom, frontend-design, github, karpathy-skills.
- **headroom** — installed as a `uv` tool (`headroom-ai`), plus:
  - `tools/headroom/headroom-watch` → `~/.local/bin/` (live compression stats)
  - `tools/headroom/headroom-proxy.service` → systemd user service (auto-start)

## What it deliberately does NOT do

- **No secrets.** No OAuth tokens, API keys, or `.credentials.json`. You log in
  interactively after install.
- **No memory/history.** Your claude-mem observations and `memory/*.md` rebuild
  on the new machine as you work.

## Requirements

`git`, `curl`, `jq`, and `systemctl --user` (Linux). `uv` is installed for you if
missing. Claude Code itself must be installed separately.

## Safety

`init.sh` is idempotent and timestamps a `.bak-init-*` copy of any file it
overwrites. Re-running it is safe.

## Codex

`codex/` is a placeholder — Codex bootstrap is not implemented yet.
