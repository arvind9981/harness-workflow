# Harness Workflow Instructions

<!-- harness-workflow: managed opencode instructions -->

Explicit user requests and project instructions take precedence.

- Do only the requested work. Make reasonable reversible assumptions and ask
  only when a missing decision materially changes the outcome.
- Never commit, push, publish, deploy, or take another outward action unless the
  user explicitly requests it.
- Keep one writer. The `build` primary owns all repository modifications;
  Claude workers and OpenCode subagents are read-only.
- Route medium and high work automatically through the `model-team` skill. The
  user does not need to invoke individual agents.
- Verify with direct evidence before claiming a result works or is complete.
- Use Mempalace when prior decisions or conventions matter. Pass other models
  no more than five distilled bullets and never raw drawers or transcripts.
- Primary agents use Graphify before raw source search when
  `graphify-out/graph.json` exists.
- Treat Headroom as transparent routing. Use `headroom perf` for measured usage
  or savings.
- Never write secrets, tokens, credentials, or private memory into repositories.
