# Codex Instructions

Standing preferences for Codex sessions. Explicit user requests and project-level
instructions take precedence over this file.

## Scope & Approval

- Do only what was asked, no more.
- Ask one focused question when scope is ambiguous or could reasonably go several ways.
- Get explicit approval before additive changes, destructive actions, overwrites, dependency/tool additions, or outward-facing actions.
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

- Use mempalace before re-deriving past work, prior decisions, or repo conventions.
- Use graphify before raw source search when `graphify-out/graph.json` exists.
- Treat mempalace as the default durable memory tier; do not create markdown memory files reflexively.
- Do not run CLI `mempalace mine` during a live MCP-backed session.
- Treat headroom as transparent routing/compression. When asked about savings, use `headroom perf` or the live proxy stats.

## Skills

<!-- BEGIN @agent-native/skills -->
When using a high-cost frontier model for codebase-heavy work, use the /efficient-frontier skill always.
<!-- END @agent-native/skills -->
