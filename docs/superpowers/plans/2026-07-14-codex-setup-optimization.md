# Codex Setup Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make this repository the canonical, idempotent Codex setup and reliably expose the existing Docker MCP Jira tools without reducing troubleshooting access.

**Architecture:** Portable instructions, hooks, tests, installation, and diagnostics remain in this repository. Machine-specific Codex and Docker state remains live-only. The installer owns repository-managed files, proxy environment values, and only the startup timeout in an existing MCP_DOCKER table.

**Tech Stack:** Bash 3.2-compatible scripts, Python 3 `tomllib`, `jq`, Codex CLI 0.144.2, Docker MCP Toolkit 0.43.1.

## Global Constraints

- Preserve `danger-full-access`, shell inheritance `all`, project trust, and existing command rules.
- Preserve unrelated models, plugins, marketplaces, MCP servers, UI settings, credentials, and hook-trust state.
- Do not alter Jira data, Docker secrets, or the `xebia` profile contents.
- Do not delete backups or caches; do not commit or push.
- Never run CLI `mempalace mine` during an MCP-backed session.

---

### Task 1: Canonical instructions and Codex discovery

**Files:**
- Create: `tools/codex/lib.sh`
- Create: `tools/codex/test-workflow.sh`
- Modify: `codex/AGENTS.md`
- Modify: `init.sh:16`
- Modify: `init.sh:295`

**Interfaces:** `codex_resolve_bin` prints one executable path or returns 1; `--codex` makes missing Codex fatal while automatic detection remains a non-fatal skip.

- [ ] **Step 1: Write failing tests** — Add test groups asserting the repo AGENTS file contains the Jira/MCP_DOCKER rule, memory-tooling reference, and efficient-frontier rule; assert binary resolution precedence is PATH, explicit `CODEX_BIN`, then the ChatGPT/Codex macOS app bundles.
- [ ] **Step 2: Verify failure** — Run `./tools/codex/test-workflow.sh instructions` and `./tools/codex/test-workflow.sh discovery`; expect missing-rule and missing-helper failures.
- [ ] **Step 3: Implement discovery** — Add `codex_resolve_bin()` using `command -v`, an executable `CODEX_BIN`, `/Applications/ChatGPT.app/Contents/Resources/codex`, and `/Applications/Codex.app/Contents/Resources/codex`, in that order.
- [ ] **Step 4: Canonicalize AGENTS.md** — Merge the live Jira section, `references/memory-tooling.md` routing bullet, and marker-delimited efficient-frontier rule into `codex/AGENTS.md` without adding access restrictions.
- [ ] **Step 5: Wire bootstrap** — Parse and document `--codex`, source `tools/codex/lib.sh`, pass the resolved executable to installer/doctor through `CODEX_BIN`, fail only when explicit `--codex` resolution fails.
- [ ] **Step 6: Verify** — Run the two test groups, `bash -n init.sh tools/codex/{lib,test-workflow}.sh`, and ShellCheck. Expected: zero failures/warnings.
- [ ] **Step 7: Review checkpoint** — Inspect the focused diff; do not commit.

---

### Task 2: Idempotent installer and MCP timeout

**Files:**
- Modify: `tools/codex/test-workflow.sh`
- Modify: `tools/codex/install-codex.sh:77`

**Interfaces:** Upsert `startup_timeout_sec = 60` only inside an existing `[mcp_servers.MCP_DOCKER]`; preserve every unrelated TOML key/comment and `inherit = "all"`.

- [ ] **Step 1: Write a failing isolated test** — In a temporary `HOME`/`CODEX_DIR`, seed config with `danger-full-access`, the current MCP_DOCKER command/`xebia` args, a sentinel plugin, and inheritance `all`. Run installer, parse with `tomllib`, and assert all sentinels survive plus timeout 60. Run twice and assert hashes and backup counts do not change on run two.
- [ ] **Step 2: Verify failure** — Run `./tools/codex/test-workflow.sh installer`; expect the timeout assertion to fail.
- [ ] **Step 3: Extend the line-preserving renderer** — Detect exact MCP_DOCKER section, replace only its timeout, emit at section end/EOF, warn without creating the table when absent, and default a newly required shell policy to `inherit = "all"`.
- [ ] **Step 4: Verify** — Run installer tests, `bash -n`, ShellCheck, and parse the output TOML. Expected: all pass.
- [ ] **Step 5: Review checkpoint** — Confirm MCP command/profile and all unrelated tables remain untouched; do not commit.

---

### Task 3: Safe mempalace and repository-scoped Graphify hooks

**Files:**
- Modify: `tools/codex/test-workflow.sh`
- Modify: `workflow/hooks/mempalace-health-deep.sh:30`
- Modify: `workflow/hooks/graphify-autoupdate.sh`
- Modify: `workflow/hooks/headroom-health.sh:19`

**Interfaces:** A live `mempalace-mcp` prevents FTS rebuild/repair. Graphify reads hook JSON from stdin and coordinates only under `<cwd>/graphify-out` with pending, lock, and log files.

- [ ] **Step 1: Write failing hook tests** — Fake `pgrep`/mempalace to prove no repair call with live MCP; fake Graphify across two temp repos; send two rapid same-repo edits and require a second update; force headroom failure and reject `Claude Code` wording. Poll for at most five seconds.
- [ ] **Step 2: Verify failure** — Run `./tools/codex/test-workflow.sh hooks`; expect Graphify and wording assertions to fail.
- [ ] **Step 3: Guard mutation points** — Add `mcp_live()` and defer/log before FTS rebuild and before `repair --mode from-sqlite`; retain read-only checks and safe snapshots.
- [ ] **Step 4: Coalesce Graphify updates** — Resolve payload `cwd`, touch a per-repo pending marker, acquire a lock with atomic `mkdir`, and detach one worker. The worker removes pending, runs `graphify update "$repo"`, loops when another edit recreates pending, and restores pending then stops on failure.
- [ ] **Step 5: Neutralize health text** — Refer to “this agent’s proxied API calls,” retaining platform recovery commands and supported hook output fields.
- [ ] **Step 6: Verify** — Run hook tests, `bash -n workflow/hooks/*.sh`, and ShellCheck. Expected: all pass without warnings.
- [ ] **Step 7: Review checkpoint** — Confirm no CLI mining and no live-palace repair path; do not commit.

---

### Task 4: Doctor coverage for current Codex and Jira readiness

**Files:**
- Modify: `tools/codex/test-workflow.sh`
- Modify: `tools/codex/doctor-workflow.sh`

**Interfaces:** Consume safe config fields and Docker tool names; emit specific PASS/WARN/FAIL actions; never call Jira or print secrets.

- [ ] **Step 1: Write failing doctor tests** — With fake `codex`/`docker` and isolated config, require explicit/bundled Codex resolution, timeout >=60, MCP_DOCKER enabled, configured profile present, Atlassian server present, at least one `jira_` tool, `$REPO_DIR` discovery, and removal of the unconditional CLI-drain warning. Allow `CODEX_DOCTOR_RUNTIME=0` only in isolated tests.
- [ ] **Step 2: Verify failure** — Run `./tools/codex/test-workflow.sh doctor`; expect missing diagnostic failures.
- [ ] **Step 3: Parse config structurally** — Source `lib.sh`; use `tomllib` to extract only proxy URLs, inherit mode, MCP command/args/profile, and timeout. Never print secret-like keys/values.
- [ ] **Step 4: Add live readiness checks** — Use resolved `codex mcp list`, `docker mcp profile list`, `profile server ls --filter`, and bounded `tools count/ls` calls. Require enabled MCP_DOCKER, timeout, profile, Atlassian, positive tool count, and Jira tools.
- [ ] **Step 5: Fix discovery/guidance** — Seed repos with `$REPO_DIR`, retain optional organization roots, remove mandatory `~/claude-workflow`, and emit distinct next actions for installer drift, Docker readiness, and invalid Graphify roots.
- [ ] **Step 6: Verify** — Run doctor tests, `bash -n`, and ShellCheck. Expected: all pass.
- [ ] **Step 7: Review checkpoint** — Confirm no Jira mutation/read call and no secret output; do not commit.

---

### Task 5: Documentation and live deployment

**Files:**
- Modify: `codex/README.md`
- Modify: `README.md:157`
- Modify live: `~/.mempalace/graphify-repos.conf`
- Deploy live: repository-managed `~/.codex` files plus narrow config upsert.

- [ ] **Step 1: Update docs** — Document app-bundle detection, explicit `--codex`, supported standalone profile file, preserved machine MCP state, and managed 60-second timeout.
- [ ] **Step 2: Verify the repository** — Run `./tools/codex/test-workflow.sh all`, Bash syntax, ShellCheck, `jq empty codex/hooks.json`, `tomllib` parse of `codex/fast.config.toml`, and `git diff --check`. Expected: all pass.
- [ ] **Step 3: Repair Graphify live state** — Back up the repo list, replace only the obsolete missing checkout with `/Users/arvind.thevar/harness-workflow`, retain other valid git roots, validate each with `git rev-parse`, and do not mine.
- [ ] **Step 4: Deploy once** — Run `CODEX_BIN='/Applications/ChatGPT.app/Contents/Resources/codex' ./tools/codex/install-codex.sh`; parse live config and confirm full access, inheritance all, plugins preserved, xebia args unchanged, timeout 60.
- [ ] **Step 5: Prove idempotency** — Record managed hashes/backup counts, rerun installer, and require no hash or backup-count changes.
- [ ] **Step 6: Run doctor twice** — Require zero failures twice. A dirty-repo warning is acceptable; config/MCP warnings are not.
- [ ] **Step 7: Review checkpoint** — Inspect status, stat, full diff, and diff check; confirm no secrets/caches/backups entered git; do not commit.

---

### Task 6: Fresh-process Jira MCP verification

**Files:** None.

- [ ] **Step 1: Verify inventory** — Run `docker mcp tools count --gateway-arg=--profile=xebia` and Jira-filtered tool listing. Expected: 57 tools and Jira names.
- [ ] **Step 2: Verify through fresh Codex** — Use bundled Codex to invoke MCP_DOCKER `jira_search` read-only with `ORDER BY updated DESC`, `limit=1`, returning only tool name and result count. Expected: bounded live result (including valid empty result) and no startup timeout.
- [ ] **Step 3: Re-check access** — Parse live config for danger-full-access, inheritance all, timeout 60; confirm rules file hash equals its pre-change hash.
- [ ] **Step 4: Final evidence** — Report passing commands, Jira tool evidence, all changed files, no commit/push, and any `/hooks` re-trust needed.
