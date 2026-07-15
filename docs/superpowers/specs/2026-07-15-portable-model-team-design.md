# Portable Claude–Codex Model-Team Design

**Date:** 2026-07-15

## Objective

Add a portable macOS/Linux model-team workflow in which Claude Code plans and
reviews while a native Codex MCP worker implements and verifies.

## Activation

The workflow uses three precedence-ordered modes:

1. An explicit single-agent instruction disables model-team for that task.
2. `/model-team <task>` explicitly enables it.
3. Otherwise Claude activates it automatically only for architecture,
   migration, security, authentication, concurrency, deployment, ambiguous
   production debugging, multi-component implementation, token-heavy scans, or
   work with at least two independent bounded subtasks.

Questions, read-only advice, mechanical edits, documentation, formatting,
small single-file changes, and latency-sensitive requests stay single-agent.
Automatic activation must be announced with its reason before dispatch.

## Architecture

Claude Code is the control plane. It owns Mempalace recall, planning, Jira,
review, and outward-facing actions. Codex is registered in Claude as the
user-scoped `codex-worker` MCP server and owns repository investigation,
implementation, debugging, and verification.

The installer resolves Codex from `PATH`, then `CODEX_BIN`, then supported
macOS application bundles. It starts the worker with
`mcp_servers.MCP_DOCKER.enabled=false`, preventing duplicate Jira access and
removing Jira tool schemas from worker context. Each Codex call uses
`danger-full-access`, approval policy `never`, and the target machine's Codex
default model. The current machine default is GPT-5.6 Sol.

Fable performs planning and focused review. Optional Terra reconnaissance is
read-only and runs only for bounded independent investigation. Codex is the
only writer. Repairs continue through `codex-reply(threadId)`; one round is the
default and a second is permitted only for a confirmed high-severity issue.
The thread is scoped to the current Codex MCP server process, so repair rounds
must finish within the same controller run. Nested model-team dispatch is
forbidden.

## Handoff Contract

Claude sends Codex only:

- objective and constraints;
- acceptance criteria;
- no more than five prior-context bullets;
- suggested files and verification commands; and
- an instruction to return changed files, verification evidence, and risks.

Full controller transcripts, worker event streams, and raw Mempalace drawers
are never forwarded.

## Headroom And Mempalace

Headroom remains mandatory for the Claude/Fable control path through the
existing `ANTHROPIC_BASE_URL` and SessionStart health hook. The Codex installer
also routes the native CLI worker's OpenAI-compatible base URL through Headroom.
The live doctor verified that configuration, and `headroom perf` recorded the
`gpt-5.6-sol` and `gpt-5.6-terra` worker models during smoke testing. This is
evidence for the CLI worker route only; it does not claim unrelated ChatGPT app
traffic is proxied, and no replacement bridge is introduced.

Claude owns Mempalace recall and distills relevant memory into the handoff.
Existing MCP-only live mining and single-writer safeguards remain unchanged.
The model-team workflow does not add duplicate recall or health calls.

## Jira

Detailed Jira recovery behavior moves from always-loaded `AGENTS.md` guidance
to a shared `jira-live` skill. The skill triggers only for Jira work and keeps
the existing live `MCP_DOCKER`, identical read-only retry, Docker gateway
fallback, and ambiguous-write safeguards. During model-team execution, Claude
is the only Jira actor; Codex receives an immutable ticket snapshot.

## Portability And Safety

- Support macOS/launchd and Linux/systemd; Windows is out of scope.
- Store portable sources in the repository and render machine paths at install.
- Back up before replacement and make a second install a no-op.
- Preserve unrelated credentials, MCP servers, plugins, permissions, trust,
  and user configuration.
- Do not commit, push, create a branch, or mutate Jira.

## Verification

Verification covers isolated path discovery and config reconciliation,
token-free MCP `initialize`/`tools/list`, Headroom and Mempalace health,
read-only and temporary-write model-team smoke tests, installer idempotency,
doctor output, shell/static checks, and `headroom perf` evidence.
