# claude-workflow

My portable Claude Code setup. Clone it on a new machine, run the init script,
log in — done.

```bash
git clone <this-repo> claude-workflow
cd claude-workflow
./init.sh
claude          # auto-installs plugins from settings.json; log in when prompted
```

`init.sh` is idempotent (every file it overwrites is backed up first, timestamped
`.bak-init-*`) and cross-platform (`systemd --user` on Linux, `launchd` on macOS).
No secrets travel with the repo — you log in interactively after install.

## Request flow

Everything Claude Code sends is optimized by **headroom** (context compression)
before it reaches a provider. The **ChatGPT toggle** (Linux) inserts a small
router in front, so you can flip Claude Code's *main* model between Claude and
ChatGPT without touching anything else:

```
                             .- off -> headroom :8787 -> Claude
    claude  ->  router :8788 -|
     (ANTHROPIC_BASE_URL)     '- on  -> bridge  :18765 -> ChatGPT (your subscription)

    graphify / codex ----------------> headroom :8787 -> Claude
      (always Claude — they never see the toggle)
```

The router only fronts **Claude Code**. graphify's graph extraction and codex keep
talking to headroom directly on `:8787`, so toggling to ChatGPT never redirects
them. On macOS (no toggle) Claude Code points straight at headroom `:8787`.

## What it sets up

- **Claude settings** (`claude/settings.json`) — enabled plugins, marketplaces,
  proxy routing, and lifecycle hooks. The template routes `ANTHROPIC_BASE_URL` at
  headroom (`:8787`); on Linux, the ChatGPT-toggle step repoints it at the router
  (`:8788`, which fronts headroom). Paths are stored as `__HOME__` and resolved to
  your real `$HOME` on install.
- **Permissions allowlist** (`claude/settings.local.json`) — a snapshot of my
  personal allow rules. It carries host-specific entries (audio, ASUS/KDE, sysfs
  paths) that are harmless elsewhere but are *not* curated to be universal; treat
  it as a starting point, not a sanitized generic list.
- **Global instructions** (`claude/CLAUDE.md`) — standing cross-project
  preferences, installed to `~/.claude/CLAUDE.md` (backed up first).
- **Plugins** — *not* vendored. Claude Code installs them itself on first launch
  from the marketplaces declared in `settings.json`: superpowers, frontend-design,
  github, headroom, mempalace, karpathy-skills.
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
  with no graph). Graph **queries are local and LLM-free** — only building uses tokens.
- **ChatGPT toggle** (Linux) — `claude-code-proxy` bridge (`:18765`) + a front-router
  (`:8788`) + `gpt-toggle` CLI, all as systemd user services. Lets you run Claude
  Code's main model on your **ChatGPT subscription**, flipped live. See below.
- **Codex** — auto-detected: if the `codex` CLI is installed, its workflow config
  is migrated into `~/.codex`; otherwise skipped. No flag.

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
entity-refinement is optional (`--llm-model gemma4:e4b` via Ollama, or `--no-llm`
for heuristics only); recall itself never needs it.

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
(`:8787`) — no extra config or local model needed. The `PreToolUse` hook only
nudges Claude toward the graph once `graphify-out/graph.json` exists, so it's inert
until you build one. `graphify-out/` is globally git-ignored.

## ChatGPT toggle

Run Claude Code's **main model** on your **ChatGPT subscription** (GPT-5.x) instead
of Claude, flipped from the shell without restarting Claude Code. Housekeeping (chat
titles, resume summaries) always stays on Claude — **Sonnet 5, never Haiku** — so it
never spends your ChatGPT quota. **Linux/systemd only.**

```bash
gpt-toggle on | off | status              # flip the main model, live (default: off)
gpt-toggle model [<name> | auto]          # pick a ChatGPT model, or return to the dynamic default
gpt-toggle effort [<low|medium|xhigh|max>]  # reasoning effort for all GPT requests (restarts bridge)
gpt-toggle refresh                        # re-resolve the newest model your plan offers
```

**How it works.** `init.sh` installs three systemd user services:

- **`claude-code-proxy` bridge** (`:18765`) — a third-party proxy that reaches your
  ChatGPT subscription via OpenAI's **Codex OAuth** (no API key). It keeps its own
  token; nothing lands in this repo.
- **front-router** (`:8788`, `~/.local/share/chatgpt-toggle/router.py`) — reads a
  state file per request and forwards to headroom (Claude) or the bridge (ChatGPT),
  rewriting the model id on the ChatGPT path.
- **model-refresh timer** (daily + on boot) — resolves the newest ChatGPT model your
  plan actually serves and pins it as the default (`gpt-5.6-terra` at time of
  writing). A specific `gpt-toggle model <name>` override survives refreshes;
  `gpt-toggle model auto` returns to the dynamic default.

**One-time login** (the GPT path only — toggle-off needs nothing):

```bash
claude-code-proxy codex auth device   # browser login with your ChatGPT account
gpt-toggle on
```

**Note:** the bridge is a pinned community binary (`curl | bash` install, unlike the
`uv`/PyPI tools) that talks to an **undocumented** ChatGPT endpoint. It's a
tolerated-but-gray-zone path for personal use on your own subscription — see Safety.

## Codex

Codex support is **auto-detected**: if the `codex` CLI is present, `init.sh` runs
`tools/codex/install-codex.sh`, which installs the repo-maintained Codex
instructions/hooks into `~/.codex`, preserves existing `config.toml` content, and
upserts the shell environment Codex needs — `~/.local/bin` on PATH, a real terminal
type (`TERM=xterm-256color`), and the headroom proxy URLs (`ANTHROPIC_BASE_URL` /
`OPENAI_BASE_URL`, routing model traffic through headroom `:8787`). If `codex` isn't
installed, the step is skipped and nothing is touched.

## What it deliberately does NOT do

- **No secrets.** No OAuth tokens, API keys, or `.credentials.json`. You log in
  interactively after install (Claude, and — for the ChatGPT path — the bridge).
- **No memory/history.** Your mempalace palace and `memory/*.md` rebuild on the new
  machine as you work (and via the one-time seed above).

## Requirements

`git`, `curl`, `jq`, and `uv` (installed for you if missing). Background services run
as `systemd --user` on **Linux** or `launchd` LaunchAgents on **macOS** — `init.sh`
picks the right one. On macOS install `jq` via Homebrew (`brew install jq`). Claude
Code itself must be installed separately. The **ChatGPT toggle** is Linux-only and
additionally pulls the `claude-code-proxy` binary.

## Safety

`init.sh` is idempotent and timestamps a `.bak-init-*` copy of any file it
overwrites. Re-running it is safe.

The ChatGPT toggle installs a **pinned third-party binary** (`claude-code-proxy`,
`curl | bash` from GitHub, checksum-verified by its own installer) that speaks an
**undocumented** ChatGPT-subscription endpoint via Codex OAuth. This is unlike every
other dependency here (all `uv`/PyPI or the official uv installer). Use it only for
personal, local use on your own subscription; it can break if OpenAI changes the
endpoint. If you don't want it, it's the only step that pulls a non-PyPI binary — on
non-Linux it's skipped automatically, and on Linux you can stop/disable the
`chatgpt-*` user services and leave `ANTHROPIC_BASE_URL` on headroom `:8787`.

## Extra graphify repos

By default, `init.sh` tracks this workflow repo for graphify→mempalace reseed. Add
machine-specific repos without editing the script:

```bash
./init.sh --graphify-repo "$HOME/project-a" --graphify-repo "$HOME/project-b"
```

For batch/shell-profile use, `GRAPHIFY_EXTRA_REPOS` accepts a colon-separated list:

```bash
GRAPHIFY_EXTRA_REPOS="$HOME/project-a:$HOME/project-b" ./init.sh
```

Missing paths are skipped with a warning.
