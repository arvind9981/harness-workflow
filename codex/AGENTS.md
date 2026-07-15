# Codex Instructions

Standing preferences for Codex sessions. Explicit user requests and project-level
instructions take precedence over this file.

## Scope & Approval

- Do only what was asked, no more.
- Make reasonable, reversible assumptions and proceed without asking. Ask only when the missing decision would materially change the outcome, the next step needs unavailable authority or credentials, or the action is destructive or irreversible.
- Routine implementation steps within an explicitly requested build, fix, or change do not need separate approval. Get explicit approval for scope expansion, destructive actions, overwrites outside the requested change, dependency/tool additions, or outward-facing actions the user did not request.
- Never commit or push unless explicitly told.
- Commit messages must contain only the substantive message. Do not add co-author, "Generated with", or AI/tool attribution lines.

## Working Style

- Be concise and decisive. Lead with the answer and the recommendation.
- Keep exploration proportional to the task.
- Once a decision is made, do not re-litigate it or pile on caveats.

## Verification

- Verify before claiming something works, passes, is fixed, or is done.
- Report the command or direct evidence used for verification.
- Re-check earlier assumptions before relying on them.

## Safety

- Never write secrets, tokens, API keys, or credentials into files, repos, or commits.
- Do not upload or transmit private code, files, or data to third-party services without approval. Web research is fine.

## Memory, Graphify, And Headroom

- Use mempalace when the request depends on prior work, decisions, or repo conventions. Skip it for self-contained tasks with sufficient current context.
- Use graphify before raw source search when `graphify-out/graph.json` exists.
- Treat mempalace as the default durable memory tier; do not create markdown memory files reflexively.
- Do not run CLI `mempalace mine` during a live MCP-backed session.
- Treat headroom as transparent routing/compression. When asked about savings, use `headroom perf` or the live proxy stats.
- Deep mechanics (graphify AST-vs-named-map, hook names, FTS5 corruption footgun, reseed procedures) live in `references/memory-tooling.md` — read on demand.

## Skills

<!-- BEGIN @agent-native/skills -->
When using a high-cost frontier model, use /efficient-frontier only when codebase work has token-heavy scans or at least two independent bounded subtasks worth delegating. Keep single-file and latency-sensitive work inline.
<!-- END @agent-native/skills -->
