---
name: model-team
description: Use when explicitly invoked with /model-team, or automatically for complex or high-risk implementation involving architecture, migrations, security, authentication, concurrency, deployment, ambiguous production debugging, token-heavy repository investigation, multiple components, or at least two independent bounded subtasks.
---

# Model Team

Claude is the control plane, a resumable Fable agent is the architect, and Codex
is the implementation worker.

## Activation

Automatic activation uses the same routing score as OpenCode.

Precedence:

1. An explicit single-agent instruction disables this skill for that task.
2. `/model-team <task>` forces it on.
3. Otherwise score scope, coupling, ambiguity, blast radius, reversibility, and
   verification from 0-2 each:
   - score 0-2: remain single-agent.
   - score 3-6: use the standard model-team path.
   - score 7-12: use the high-risk path, with optional reconnaissance and the
     stricter review/repair gate.

Security, authentication, data migration, concurrency, production deployment,
irreversible changes, cross-system architecture, and ambiguous high-impact
failures always take the high-risk path. Explicit `/model-team` forces at least
the standard path; it does not inflate the score.

Keep questions, advice, mechanical or documentation edits, small single-file
changes, and latency-sensitive requests inline. Announce the reason for every
automatic activation before dispatch, including the score and its material
dimensions.

## Workflow

1. Claude owns Mempalace recall, live service access, verification, and outward actions.
   Distill recall to at most five bullets. Run
   `model-team-watch --mark planning --actor fable --task plan`.
   Phase marks show orchestration intent; the instrumented MCP wrapper records
   actual worker calls independently.
2. Invoke `model-team-architect` and retain its agent ID for
   review and replanning. Give it the objective, constraints, acceptance criteria,
   distilled context, files, and verification commands. Require its
   `MODE: PLAN` contract; resume it before dispatch if a required field is absent.
   Before each worker call, announce:
   `MODEL-TEAM DISPATCH | phase=<recon|implementation|repair> | worker=codex-worker | model=<name|machine-default> | access=<read-only|danger-full-access> | repo=<path>`.
3. On the high-risk path only, optional reconnaissance may run at most two bounded calls
   to `mcp__codex-worker__codex` with model `gpt-5.6-terra` and sandbox
   `read-only`. They may run concurrently only when independent. Skip unavailable
   scouts rather than substituting another model.
4. Run `model-team-watch --mark implementation --actor codex-worker --task <id>`,
   then call `mcp__codex-worker__codex` once for implementation. Omit `model` so the
   machine's Codex default applies. Set `sandbox` to `danger-full-access` and
   `approval-policy` to `never`. Codex is the only writer. Require `STATUS`,
   `CHANGED_FILES`, `VERIFICATION` with commands and exit codes, and `RISKS` in
   its result, then independently collect the actual diff and test evidence.
5. Run `model-team-watch --mark review --actor fable --task review`, then resume
   the architect with the actual diff, acceptance criteria, and
   verification evidence. Require its `MODE: REVIEW` contract.
   Announce `MODEL-TEAM REVIEW | thread=<id> | reviewer=Fable | changed=<count> | tests=<summary>` before reviewing.
6. On `repair`, mark the repair phase and call `mcp__codex-worker__codex-reply`
   with the original `threadId`. On `replan`, resume the same architect first,
   then continue the original Codex thread. Allow one repair normally and a
   second only for a confirmed critical or high finding. Thread IDs live only
   for the current Codex MCP server process, so finish repairs in the same run.
   A later Claude process or resumed CLI invocation cannot continue that worker.
7. Independently verify before reporting completion.
   Mark `verification`, then `complete` or `failed` with `model-team-watch`.
   End with `MODEL-TEAM COMPLETE | thread=<id> | result=<pass|fail> | changed=<files|none> | tests=<summary> | risks=<summary|none>`.

Never forward full transcripts, raw Mempalace drawers, reasoning, or worker
event streams. Pass only the compact plan; return only changed files, test
evidence, remaining risks, and a concise result. Never allow concurrent writers,
nested model-team dispatch, or Codex access to outward services. For externally
backed work, Claude gives Codex an immutable snapshot of the relevant live state.
