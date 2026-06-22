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
- Memory captures automatically (mempalace `Stop`/`PreCompact` hooks) — so a
  finding already lands in mempalace by default. **Don't reflexively write a
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
  (`graphify-reseed-session.sh`, at most once per ~12h) then NUDGES the agent to
  re-mine that report into the `graphify_<repo>` wing — so structural recall mirrors
  the current graph with no manual curation. The refresh goes through the **in-process
  MCP `mine` tool** (the only safe in-session writer): a separate CLI `mempalace mine`
  running alongside a live MCP server writes the shared chroma DB concurrently and
  corrupts its FTS5 index — so **never run `mempalace mine` (or `graphify-reseed.sh`)
  from a hook or by hand while a session is live**. The standalone
  `~/.local/bin/graphify-reseed.sh <repo>` still exists for out-of-session refreshes
  and self-skips if an MCP server is up. (Replaces the old nightly 04:13 timer, which
  never fired on a laptop that's off overnight.)

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
