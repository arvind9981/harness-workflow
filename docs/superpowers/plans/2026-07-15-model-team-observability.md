# Model-Team Observability Implementation Plan

**Goal:** Add a passive Codex worker dashboard and make Headroom's dashboard show
the latest observed model and client.

**Architecture:** Both dashboards read existing process, Headroom, and Git state.
They do not wrap or modify the Codex MCP transport. The model-team skill adds
human-readable lifecycle receipts around existing MCP calls.

**Tech Stack:** Bash, `jq`, `curl`, `ps`, Git.

## Global Constraints

- Preserve the current branch and unrelated uncommitted changes.
- Do not commit, push, mutate Jira, add dependencies, or modify MCP transport.
- Do not expose prompts, responses, transcripts, or credentials.
- Keep macOS and Linux support.

## Task 1: Observer contract

**Files:**

- Modify: `tools/model-team/test-model-team.sh`
- Create: `tools/model-team/model-team-watch`

1. Add failing tests with fixed process, Headroom, and Git fixtures.
2. Verify the tests fail because the watcher is absent.
3. Implement text, JSON, one-shot, continuous, repo, and interval interfaces.
4. Verify server availability, latest Codex request, request count, health, and
   repository output.

## Task 2: Headroom current-model visibility

**Files:**

- Modify: `tools/model-team/test-model-team.sh`
- Modify: `tools/headroom/headroom-watch`

1. Add a failing assertion for latest request model, client, and timestamp.
2. Update the dashboard header using `.request_logs` with safe fallbacks.
3. Verify Claude and Codex fixture variants.

## Task 3: Installation, receipts, and diagnostics

**Files:**

- Modify: `claude/skills/model-team/SKILL.md`
- Modify: `tools/model-team/install-model-team.sh`
- Modify: `tools/model-team/doctor-model-team.sh`
- Modify: `init.sh`
- Modify: `README.md`

1. Add failing source, installer, and doctor assertions.
2. Install the watcher idempotently and verify it in the doctor.
3. Add concise dispatch, review, and completion receipts to the skill.
4. Document both watcher commands.

## Task 4: Verification

1. Run focused tests and live one-shot dashboards.
2. Install twice and verify the second run is a no-op.
3. Run both workflow suites, Bash syntax, ShellCheck, skill validation,
   JSON/TOML validation, and `git diff --check`.
