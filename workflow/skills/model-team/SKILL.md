---
name: model-team
description: Use explicitly with $model-team, or automatically for complex or high-risk implementation involving architecture, migrations, security, authentication, concurrency, deployment, ambiguous production debugging, multiple coupled components, or at least two independent bounded investigations.
---

# Codex Model Team

Codex is the control plane and only writer. Sol owns the main task, Terra handles
bounded read-only reconnaissance, Sonnet supplies routine independent judgment,
and Fable supplies high-risk architecture and critical review.

## Activation

Precedence:

1. An explicit single-agent instruction disables the team for that task.
2. `$model-team <task>` forces at least the standard path.
3. Otherwise score scope, coupling, ambiguity, blast radius, reversibility, and
   verification difficulty from 0 to 2 each.
   - 0-2: Sol handles the task inline.
   - 3-6: standard path; use Terra only for an independent read-heavy subtask and
     Sonnet only when a second opinion materially reduces uncertainty.
   - 7-12: high-risk path; use Fable for architecture and evidence-based review,
     with Terra reconnaissance only where it removes real uncertainty.

Questions, advice, documentation, formatting, small mechanical changes, and
latency-sensitive work remain single-agent. Security, authentication, data
migration, concurrency, production deployment, irreversible changes, and
ambiguous high-impact failures always use the high-risk path when implementation
is requested.

Before automatic activation, announce the score, material dimensions, selected
workers, and why their extra token cost is justified.

## Standard path

1. Sol states the objective, constraints, risk, and acceptance checks.
2. If repository reconnaissance is independently useful, spawn one
   `terra-explorer`; use a second only for a genuinely independent question.
3. When independent judgment is useful, call `mcp__claude-worker__claude` with
   role `advisor`, a stable `taskId`, the repository path, and no more than five
   distilled context bullets. Sonnet has no tools and one turn.
4. Sol implements as the only writer and runs proportional verification.
5. Use `mcp__claude-worker__claude-reply` for routine review only when the change
   is behaviorally meaningful or the acceptance evidence is ambiguous.
6. Allow one bounded repair. Do not repeat unchanged tests or reviews.

Standard implementation uses at most two Claude calls: advice and review.

## High-risk path

1. Call `mcp__claude-worker__claude` with role `architect`. Fable may use only
   Read, Glob, and Grep and must return a compact plan, risks, acceptance gates,
   and stop conditions.
2. Sol validates the plan against the actual repository and live constraints.
   Use at most two independent Terra reconnaissance tasks when evidence is
   missing; never use concurrent writers.
3. Sol implements and captures the actual diff plus command exit codes.
4. Continue the same Claude session with `mcp__claude-worker__claude-reply` for
   critical review of the diff and evidence.
5. Permit one repair normally. A second requires a confirmed critical or high
   finding and must continue the existing review context.

High-risk implementation uses at most three Claude calls. Never retry a blocked
provider call automatically; continue safely with Sol and report the degraded
review path.

## Handoff and isolation

Send workers only the objective, constraints, acceptance criteria, up to five
relevant context bullets, suggested files, and verification commands. Return
only findings, changed files, command evidence, and remaining risks. Never send
full transcripts, raw memory drawers, secrets, broad logs, or hidden reasoning.

Claude workers are read-only and have no MCP, agent, web, Bash, plugin, hook, or
outward-action access. Terra agents are read-only and may not invoke MCPs or
other agents. Sol owns memory recall, live services, permissions, edits,
verification, commits, pushes, and all other outward actions.

Use `claude-worker-watch` only when a Claude call is active or when diagnosing
its usage guard. Native GPT workers are visible in the Codex Subagents panel.
