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
  headroom proxy routing (`ANTHROPIC_BASE_URL=127.0.0.1:8787`), and lifecycle
  hooks. Paths are stored as `__HOME__` and resolved to your real `$HOME` on
  install.
- **Permissions allowlist** (`claude/settings.local.json`) — a snapshot of my
  personal allow rules. It carries host-specific entries (audio, ASUS/KDE,
  sysfs paths) that are harmless on another machine but are *not* curated to be
  universal; treat it as a starting point, not a sanitized generic list.
- **Global instructions** (`claude/CLAUDE.md`) — standing cross-project
  preferences, installed to `~/.claude/CLAUDE.md` (backed up first).
- **Plugins** — *not* vendored. Claude Code installs them itself on first launch
  from the marketplaces declared in `settings.json`: superpowers,
  frontend-design, github, headroom, mempalace, karpathy-skills.
- **headroom** (transport) — a local context-compression proxy in front of the
  Anthropic API. Installed as a `uv` tool (`headroom-ai[proxy]`), plus:
  - `tools/headroom/headroom-watch` → `~/.local/bin/` (live compression stats)
  - `tools/headroom/headroom-proxy.service` → systemd user service (Linux) /
    `com.user.headroom-proxy.plist` → launchd LaunchAgent (macOS), both auto-start
    and serve `127.0.0.1:8787`.
- **mempalace** (memory) — the local-first, verbatim, zero-API memory layer.
  Installed as a `uv` tool (`mempalace`, with the native `mempalace-mcp` server),
  loaded as a Claude Code plugin, plus a daily junk-drawer prune
  (`tools/mempalace/mempalace-prune.py` via systemd timer / launchd plist).

## Memory layer — mempalace

Retrieval is fully local (local embeddings, no API calls). The wiring:

- **Capture** is automatic via the mempalace *plugin's* `Stop` / `PreCompact`
  hooks, which mine the session into the palace.
- **Recall** is wired two ways through repo hooks in `settings.json`:
  - `SessionStart` → `claude/hooks/mempalace-context.sh` injects a project-scoped
    "wake-up" summary (identity + the essential story for the current wing).
  - `UserPromptSubmit` → `claude/hooks/mempalace-recall.sh` injects the verbatim
    drawers most relevant to each prompt (semantic + bm25, over-fetched then
    filtered by a similarity floor and a per-source cap).
  - Plus the mempalace MCP tools (search / traverse / kg_query) on demand.

**One-time seed** (network/disk-heavy, so `init.sh` guides rather than auto-runs):

```bash
mempalace init "$HOME"                              # create the global palace
mempalace mine ~/.claude/projects/ --mode convos   # seed memory from transcripts
```

The embedding model (~300 MB) downloads lazily on the first embedding op. LLM
entity-refinement is optional (`--llm-model gemma4:e4b` via Ollama, or
`--no-llm` for heuristics only); recall itself never needs it.

**Why the daily prune?** The plugin's `Stop` hook re-mines the whole session dir
in `convos` mode — which ignores `.gitignore` and has no exclude flag — so it
re-ingests tool-result / subagent noise that can only be removed *after* ingest.
The daily prune (03:47 local) strips it so it doesn't pollute recall.

## What it deliberately does NOT do

- **No secrets.** No OAuth tokens, API keys, or `.credentials.json`. You log in
  interactively after install.
- **No memory/history.** Your mempalace palace and `memory/*.md` rebuild on the
  new machine as you work (and via the one-time seed above).

## Requirements

`git`, `curl`, `jq`, and `uv` (installed for you if missing). The headroom proxy
runs as a background service: `systemd --user` on **Linux**, a `launchd`
LaunchAgent on **macOS** — `init.sh` picks the right one automatically. On macOS,
install `jq` via Homebrew (`brew install jq`). Claude Code itself must be
installed separately.

## Safety

`init.sh` is idempotent and timestamps a `.bak-init-*` copy of any file it
overwrites. Re-running it is safe.

## Codex

`codex/` is a placeholder — Codex bootstrap is not implemented yet.
