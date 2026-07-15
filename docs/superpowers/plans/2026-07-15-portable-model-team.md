# Portable Model-Team Implementation Plan

**Goal:** Install and verify a portable Claude-controlled Codex MCP workflow.

**Architecture:** Claude owns orchestration, memory, Jira, and review. A
repo-managed Claude skill dispatches a `codex-worker` MCP server that has Jira
disabled internally and uses Codex's machine-default implementation model.

## Constraints

- Preserve the existing branch and uncommitted changes.
- Do not commit, push, create a branch, or mutate Jira.
- Preserve full troubleshooting access and unrelated machine configuration.
- Use test-first changes for installer and diagnostic behavior.

## Tasks

### 1. Portable skills and policy placement

- Add a Claude `model-team` skill with automatic, force-on, and force-off rules.
- Add a shared `jira-live` skill containing the existing Jira recovery policy.
- Remove the detailed Jira section from the always-loaded Codex instructions.
- Install shared skills into Claude as well as Codex and OpenCode without
  replacing unrelated skills.

### 2. Codex worker registration

- Add isolated tests for PATH, `CODEX_BIN`, and application-bundle discovery.
- Add tests proving only the repo-owned `codex-worker` entry changes and the
  second install is byte-for-byte idempotent.
- Register the resolved binary with `mcp-server` and
  `mcp_servers.MCP_DOCKER.enabled=false`.
- Keep worker access at `danger-full-access` with approval policy `never` in the
  model-team dispatch contract.

### 3. Diagnostics

- Add a token-free JSON-RPC smoke test for `initialize` and `tools/list`,
  requiring `codex` and `codex-reply`.
- Verify the installed model-team and Jira skills, Headroom `/health`,
  Mempalace binaries, and worker MCP configuration.
- Keep runtime/model calls optional so normal bootstrap remains deterministic.

### 4. Documentation and live deployment

- Document activation, ownership, token boundaries, service dependencies, and
  Headroom's verified routing scope.
- Run isolated tests before deploying repository-managed files.
- Install once, record hashes/backups, install again, and prove idempotency.
- Run a read-only worker smoke test and a temporary-repository write test when
  authentication and runtime support are available.

### 5. Final verification

- Run the repository test suite, Bash syntax, ShellCheck when installed,
  JSON/TOML parsing, and `git diff --check`.
- Run the workflow doctor twice.
- Inspect `headroom perf` and report actual controller savings without claiming
  unobserved Codex compression.
- Review the final diff against the design and report residual risks.
