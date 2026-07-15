---
name: model-team
description: Use when explicitly forced with /team, or automatically for medium or high implementation work involving multiple files or components, ambiguity, architecture, migrations, security, authentication, concurrency, deployment, production risk, difficult rollback, complex verification, or token-heavy investigation.
---

# Model Team

<!-- harness-workflow: managed opencode skill -->

OpenCode is the control plane, Sol is the only writer, Claude supplies read-only
Sonnet/Fable judgment, and Terra supplies bounded reconnaissance.

## Route automatically

Score scope, coupling, ambiguity, blast radius, reversibility, and verification
from 0-2 each.

- score 0-2: Sol works inline.
- score 3-6: start Claude role `advisor` before implementation and resume it for
  `routine-review` after verification.
- score 7-12: start Claude role `architect` and resume it for
  `critical-review` after verification.

Security, authentication, data migration, concurrency, production deployment,
irreversible changes, cross-system architecture, and ambiguous high-impact
failures always take the high route. `/team` forces at least the standard route
without inflating the score. An
explicit single-agent instruction always disables dispatch for that request.

Do not wait for the user to invoke an agent. Announce the route, score, and
reasons, then dispatch automatically.

## Execute

1. When prior work or durable conventions matter, dispatch the `memory`
   subagent for bounded Mempalace recall and retain at most five distilled bullets.
2. Call `claude-worker_claude` with the selected role, objective, constraints,
   acceptance criteria, distilled context, likely files, and verification.
3. Retain its `sessionId`. Use at most two independent `explore` or `scout`
   tasks when reconnaissance is genuinely useful.
4. Implement sequentially as Sol. Collect the actual diff and command exit
   codes; never trust summaries alone.
5. Call `claude-worker_claude-reply` with the retained session and actual
   evidence. Apply one bounded repair normally; allow a second only for a
   confirmed critical or high finding.
6. Independently rerun verification and report the route, changed files, tests,
   and remaining risks.

Never allow concurrent writers, nested model-team runs, Claude writes, or raw
transcript and memory forwarding.
