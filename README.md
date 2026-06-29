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
- **graphify** (code knowledge graph) — turns a repo into a queryable graph and
  redirects Claude's search (Glob/Grep) to the graph when one exists. Installed as
  a `uv` tool (`graphifyy`, CLI `graphify`); the skill is registered globally and a
  self-guarding `PreToolUse` hook ships in `claude/settings.json` (a no-op in repos
  with no graph). Build a repo's graph on demand with `/graphify`; extraction routes
  through the headroom proxy. Artifacts land in `graphify-out/` (globally git-ignored).
  Graph **queries are local and LLM-free** — only building a graph uses tokens.

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

## Code knowledge graph — graphify

Global install is handled by `init.sh`; graphs are **per-repo and on demand**:

```bash
/graphify .            # build/refresh this repo's graph (in Claude Code)
graphify update .      # incremental AST-only refresh after edits (no LLM)
graphify query "..."   # local, LLM-free traversal of the graph
```

Building extracts semantic edges via Claude subagents through the headroom proxy
(`ANTHROPIC_BASE_URL=127.0.0.1:8787`) — no extra config or local model needed.
The `PreToolUse` hook only nudges Claude toward the graph once `graphify-out/graph.json`
exists, so it's inert until you build one. `graphify-out/` is globally git-ignored.

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

## Extra graphify repos

By default, `init.sh` tracks this workflow repo for graphify→mempalace reseed.
Add machine-specific repos without editing the script:

```bash
./init.sh --graphify-repo "$HOME/project-a" --graphify-repo "$HOME/project-b"
```

For batch/shell-profile use, `GRAPHIFY_EXTRA_REPOS` accepts a colon-separated
list:

```bash
GRAPHIFY_EXTRA_REPOS="$HOME/project-a:$HOME/project-b" ./init.sh --codex
```

Missing paths are skipped with a warning.

## Codex

Codex bootstrap is available through `codex/` and
`tools/codex/install-codex.sh`. It installs the repo-maintained Codex
instructions/hooks into `~/.codex`, preserves existing `config.toml` content, and
upserts the shell environment Codex needs for `~/.local/bin` tools, a real
terminal type (`TERM=xterm-256color`), and the headroom proxy URLs
(`ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL`). It also sets Codex's native
`openai_base_url` to route model traffic through headroom.
Regenerating `hooks.json` also preserves Supacode-managed hook entries. Run it
with `./init.sh --codex` or directly with `./tools/codex/install-codex.sh`.
