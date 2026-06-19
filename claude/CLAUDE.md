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
- Memory captures automatically (mempalace `Stop`/`PreCompact` hooks). Still file
  durable, non-obvious findings deliberately when they matter — don't wait to be
  told.
- **Graphify auto-syncs into mempalace (nightly, wipe-and-replace).** A PostToolUse
  hook (`graphify-autoupdate.sh`) runs `graphify update .` on every code change to
  keep the graph fresh; a nightly timer (`graphify-reseed.sh`, 04:13) then wipes the
  `graphify_<repo>` wing and re-mines `GRAPH_REPORT.md` into it — so structural recall
  always mirrors the current graph with no staleness and no manual curation. The
  reseed runs **out of session**: a live Claude session holds the mempalace
  write-lock, so an in-session `mempalace mine` deadlocks. The job self-skips when the
  MCP server is up and retries next night — so **don't add an in-session mining
  hook**. To force a refresh now, close Claude and run
  `~/.local/bin/graphify-reseed.sh <repo>`.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
