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
The local stack — mempalace (memory) and headroom (proxy) — is installed to be used;
reach for it without being asked.
- **Recall before re-deriving.** Before non-trivial work, or whenever I reference past
  work ("did we…", "the X fix", "last time"), search mempalace (`mempalace search` or the
  MCP search / traverse / kg_query tools) instead of reconstructing. A per-turn
  `UserPromptSubmit` hook also surfaces relevant drawers — use them when relevant, but
  verify they still hold before relying on them (they reflect capture-time truth).
- **Memory auto-captures** (SessionEnd hook) — a finding lands in mempalace by default.
  Don't reflexively write a `.md` for every finding.
- **Two memory tiers — choose deliberately:**
  - `memory/*.md` + `MEMORY.md` load *every* session (permanent context cost). Reserve for
    the small curated always-load set: recovery procedures (must survive mempalace being
    down), hard preferences, north-star facts.
  - **mempalace** is the default for everything else — auto-captured, recalled on demand,
    no per-session cost. File durable findings deliberately (`add_drawer`).
- **Never run `mempalace mine` (or `graphify-reseed.sh`) from a hook or by hand while a
  session is live** — a second chroma writer alongside the live MCP server corrupts the
  FTS5 index. In-session mining ALWAYS goes through the in-process MCP `mine` tool.
- **graphify↔mempalace pipeline.** Hooks keep the graph fresh and nudge a periodic
  structural reseed. When the SessionStart banner asks for one, run
  `~/.local/bin/graphify-sync.sh` and mine each `MINE wing=… source=…` line via the MCP
  `mine` tool. Deeper mechanics (the `graphify label --backend claude-cli` shell-function
  trap, node:edge signatures, complete-map scripts) are filed in mempalace — recall them
  when working on the pipeline itself.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost). NOTE: `update` leaves communities UNNAMED (`Community N`) and drops existing names; a complete named map needs `graphify label . --backend claude-cli` in-session (see "AST map vs COMPLETE map" under Memory & tooling defaults).
