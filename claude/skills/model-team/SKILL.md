---
name: model-team
description: Use when explicitly invoked with /model-team, or automatically for complex or high-risk implementation involving architecture, migrations, security, authentication, concurrency, deployment, ambiguous production debugging, token-heavy repository investigation, multiple components, or at least two independent bounded subtasks.
---

# Model Team

Claude is the controller; Codex is the implementation worker.

## Activation

Apply precedence in this order:

1. An explicit single-agent instruction disables this skill for that task.
2. `/model-team <task>` forces it on.
3. Otherwise use Automatic activation only for the triggers in the description.

Keep questions, read-only advice, mechanical or documentation edits, small
single-file changes, and latency-sensitive requests single-agent. When
automatic activation applies, announce the concrete reason before dispatch.

## Workflow

1. Claude owns planning, Mempalace recall, Jira, review, and outward actions.
   Recall prior context only when relevant and distill it to at most five bullets.
2. Use the strongest available Claude judgment model (Fable) for a compact plan:
   objective, constraints, acceptance criteria, relevant context, suggested
   files, and verification commands.
   Immediately before each worker call, announce one concise receipt:
   `MODEL-TEAM DISPATCH | phase=<recon|implementation|repair> | worker=codex-worker | model=<name|machine-default> | access=<read-only|danger-full-access> | repo=<path>`.
3. For optional independent reconnaissance, call `mcp__codex-worker__codex`
   with model `gpt-5.6-terra` and sandbox `read-only`. Skip this phase when the
   model is unavailable.
4. Call `mcp__codex-worker__codex` once for implementation. Omit `model` so the
   machine's Codex default applies. Set `sandbox` to `danger-full-access` and
   `approval-policy` to `never`. Codex is the only writer.
5. Have Fable review the actual diff and verification evidence without editing.
   Announce `MODEL-TEAM REVIEW | thread=<id> | reviewer=Fable | changed=<count> | tests=<summary>` before reviewing.
6. If correction is required, call `mcp__codex-worker__codex-reply` with the
   original `threadId`. Allow one repair normally and a second only for a
   confirmed high-severity finding. Thread IDs live only for the current Codex
   MCP server process, so finish repair rounds in the same controller run; a
   later Claude process or resumed CLI invocation cannot continue that worker.
7. Independently verify before reporting completion.
   End with `MODEL-TEAM COMPLETE | thread=<id> | result=<pass|fail> | changed=<files|none> | tests=<summary> | risks=<summary|none>`.

Never forward full transcripts, raw Mempalace drawers, reasoning, or worker
event streams. Pass only the compact plan; return only changed files, test
evidence, remaining risks, and a concise result. Never allow concurrent writers,
nested model-team dispatch, or Codex Jira access. For Jira-backed work, Claude
uses `jira-live` and gives Codex an immutable ticket snapshot.
