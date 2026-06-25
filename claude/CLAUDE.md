# Global instructions

Standing preferences across all projects. Project-level CLAUDE.md and explicit
requests in the moment take precedence over anything here.

## Scope & approval
- Do what's asked — no more. For anything **additive** (new tools, dependencies,
  features) or **hard to reverse** (deletes, overwrites, outward-facing actions),
  propose it and get explicit approval before implementing.
- When a request is ambiguous or could reasonably go several ways, ask one
  focused question before acting — don't guess at scope.
- **Never commit or push** unless I explicitly tell you to.
- Commit messages: write only the substantive message. **Never** add co-author,
  "Generated with", or any AI/tool attribution lines.

## Working style
- Be concise and decisive: give a recommendation, not an exhaustive survey.
- Once I've made a decision, don't re-litigate it or pile on caveats — move on.
- Lead with the answer; keep exploration to what the task needs.

## Verification
- Verify before claiming something works, passes, or is done — run the command
  and show the evidence. No success claims from assumption.
- Verify claims before relying on them — including your own earlier findings;
  don't treat a probe result or assumption as fact.

## Safety
- Never write secrets, tokens, API keys, or credentials into files, repos, or
  commits.
- Don't upload or transmit my code, files, or data to external/third-party
  services without asking. (Web research is fine.)

## Memory & tooling defaults
The local stack (mempalace for memory, headroom for the proxy) is installed to be
used — reach for the right tool without being asked:
- **Recall before re-deriving.** Before non-trivial work, or whenever I reference
  past work ("did we…", "how did we…", "the X fix", "last time"), search memory
  (`mempalace search`, `mempalace wake-up`, or the mempalace MCP tools —
  search / traverse / kg_query) instead of reconstructing from scratch. A
  `PreToolUse` hook (`mempalace-recall-enforce.sh`) injects a once-per-session
  MANDATORY reminder on the first search/explore action as a backstop.
- A `UserPromptSubmit` hook surfaces relevant verbatim drawers each turn. When
  those hits are relevant, use them — but verify they still hold before relying on
  them; they reflect what was true when captured.
- Memory captures automatically (mempalace `SessionEnd` catchup-rebuild hook) — so
  a finding already lands in mempalace by default. **Don't reflexively write a
  `.md` for every finding.**
- **Two memory tiers — choose deliberately:**
  - **File-based `memory/*.md` + `MEMORY.md`** loads into context *every* session,
    so it costs context-window space always. Reserve it for the small curated
    always-load set: recovery procedures (must survive mempalace being down),
    hard preferences, and "north-star" facts.
  - **mempalace** is the default home for everything else — auto-captured, semantic
    recall on demand, no per-session context cost. For a durable finding worth
    guaranteed searchability, file it into mempalace deliberately (`add_drawer`),
    not into a `.md`.
- **Session recap ("where you left off").** A `Stop` hook
  (`mempalace-recap-write.sh`) summarizes each session into a per-project recap
  via a local model (`gemma4:e4b`, on-device, `think:false`), and a SessionStart
  hook (`mempalace-recap-show.sh`) shows it next time. Falls back to a cleaned
  list of recent prompts if Ollama/the model is unavailable.
- **Graphify auto-syncs into mempalace (session-triggered, wipe-and-replace).** A
  PostToolUse hook (`graphify-autoupdate.sh`) runs `graphify update .` on every code
  change to keep `GRAPH_REPORT.md` fresh; a throttled SessionStart hook
  (`graphify-reseed-session.sh`, at most once per ~12h) then NUDGES the agent to run
  `~/.local/bin/graphify-sync.sh` (reads `graphify-repos.conf`) — which refreshes each
  repo's AST and re-labels+stages ONLY repos whose code structure changed (node:edge
  signature vs `hook_state/graph-sig-<leaf>`), printing `MINE wing=… source=…` lines
  the agent mines and `SKIP` for unchanged repos (so big stable repos like xebia are
  not re-labeled every window). Mining ALWAYS goes through the
  **in-process MCP `mine` tool** (the only safe in-session writer): a separate CLI
  `mempalace mine` alongside a live MCP server is two concurrent chroma writers and
  corrupts its FTS5 index — so **never run `mempalace mine` (or `graphify-reseed.sh`)
  from a hook or by hand while a session is live**. The standalone
  `~/.local/bin/graphify-reseed.sh <repo>` is for out-of-session AST refreshes and
  self-skips if an MCP server is up.
- **AST map vs COMPLETE (named) map — the distinction that decides recall quality.**
  `graphify update` is AST-only: it leaves communities as unnamed `Community N`
  placeholders AND resets existing names on re-cluster. So the auto-sync above mines an
  *unnamed* map unless it is labeled first. A complete map needs `graphify label`,
  which names communities — with a trap: `graphify` is a shell FUNCTION that injects
  `--backend claude-cli`, but **scripts, hooks, and `nohup` get the bare binary with NO
  backend and silently keep placeholders** (exit 0, `Token cost: 0`). Any script/hook
  that labels MUST pass it explicitly:
  `GRAPHIFY_CLAUDE_CLI_MODEL=sonnet graphify label . --backend claude-cli`. Labeling
  spawns the Claude CLI and needs a live session; it does NOT use headroom.
- **Load a complete map (IN-session, opposite of the AST reseed):**
  `~/.local/bin/graphify-complete-map.sh <repo>…` labels (verify-retries; refuses to
  stage a placeholder report) + stages each report; the agent then mines each staged
  report via the MCP `mine` tool. `~/.local/bin/reseed-verify.sh <repo>…` drives this
  for several repos and emits `MINE wing=… source=…` handoff lines + a
  `STATUS: PASS_PENDING_MCP_MINE`. Cheap refresh between full rebuilds: `graphify
  update` only re-extract is free; re-label only when code structure actually changed.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost). NOTE: `update` leaves communities UNNAMED (`Community N`) and drops existing names; a complete named map needs `graphify label . --backend claude-cli` in-session (see "AST map vs COMPLETE map" under Memory & tooling defaults).
