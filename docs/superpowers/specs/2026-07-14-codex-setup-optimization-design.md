# Codex Setup Optimization Design

**Date:** 2026-07-14

## Objective

Make the repository the reliable source of truth for the user's Codex workflow,
restore the live installation to that source, and ensure Jira requests use the
Docker MCP `xebia` profile. Preserve unrestricted troubleshooting access.

## Constraints

- Keep `sandbox_mode = "danger-full-access"` and the existing broad trust,
  environment inheritance, and command rules.
- Do not change Jira credentials, Docker secrets, or the contents of the
  `xebia` Docker MCP profile.
- Preserve unrelated Codex models, plugins, marketplaces, MCP servers, project
  trust, UI settings, and generated hook-trust state.
- Do not delete existing backups or caches.
- Do not commit or push.
- Never run CLI `mempalace mine` while an MCP-backed session is live.

## Confirmed Problems

1. The repository and live Codex installation have drifted. The current doctor
   reports 24 failures across `AGENTS.md`, hooks, shared skills, and the fast
   profile.
2. The live global `AGENTS.md` contains Jira and workflow rules that are absent
   from the repository source, so reinstalling from the repository would erase
   them.
3. MCP_DOCKER is configured and its `xebia` profile exposes 57 tools, including
   49 Jira tools, but gateway initialization reaches Codex's default 10-second
   startup limit. The current task consequently has no native Jira tools.
4. `init.sh` only detects a bare `codex` command. On this Mac, Codex is available
   through the application bundle but is not on the invoking shell's `PATH`.
5. `codex/README.md` documents `./init.sh --codex`, but that option does not
   exist.
6. The deep mempalace health worker can repair the live palace while an MCP
   process is using it, contradicting the workflow's single-writer rule.
7. Graphify's post-edit hook uses a machine-global process check, so an update
   for one repository can suppress another repository's update.
8. The doctor checks file equality but does not adequately verify hook behavior
   or MCP_DOCKER/Jira readiness.

## Design

### Canonical instructions

`codex/AGENTS.md` remains the canonical global instruction file installed to
`~/.codex/AGENTS.md`. It will retain its compact personal-preference role and
add the live Jira policy, the memory-tooling reference, and the
`efficient-frontier` routing rule. The Jira policy will require a live
MCP_DOCKER result for every Jira request and require an explicit unavailability
notice before any fallback is used.

No root project `AGENTS.md` will be added. This repository is a portable setup
repository, and its global instruction source already has a clear install
destination.

### Installer and bootstrap

`init.sh` will support an explicit `--codex` option. That option will request
Codex installation even when a bare command is not on `PATH`. Automatic
detection will continue to work.

Codex discovery will check, in order:

1. `command -v codex`
2. `CODEX_BIN` when explicitly supplied
3. the macOS application-bundled Codex binary

`tools/codex/install-codex.sh` will continue to back up changed managed files
and install only repository-owned instructions, hooks, skills, and the fast
profile. Its TOML update will preserve all unrelated configuration. When an
existing `[mcp_servers.MCP_DOCKER]` table is present, it will upsert
`startup_timeout_sec = 60`; it will not create or rewrite the server command,
profile name, credentials, or tool policy.

The installer will remain idempotent: a second run against the same source must
not create new backups, rewrite unchanged files, or change hashes.

### MCP_DOCKER and Jira

The existing command remains:

```text
docker mcp gateway run --profile xebia
```

The only managed MCP_DOCKER behavior change is the 60-second startup timeout.
The design does not restrict tools or add approval gates because unrestricted
troubleshooting access is an explicit requirement. Behavioral safeguards stay
in `AGENTS.md`: external mutations still require explicit user authorization.

The doctor will confirm that:

- the bundled or PATH Codex binary recognizes MCP_DOCKER as enabled;
- the configured gateway references an existing Docker MCP profile;
- that profile includes the Atlassian server;
- gateway enumeration completes and returns Jira tools; and
- the startup timeout is at least 60 seconds.

No secret values will be printed during these checks.

### Hook reliability and safety

The repository versions of the Codex hooks will replace stale installed copies
through the normal backup-first installer. Hook matchers and payload parsing
will follow the current Codex hook contract.

The mempalace deep-health worker will detect a live `mempalace-mcp` process
before any database repair or FTS rebuild. When the MCP writer is live, it will
log that repair was deferred and leave the live palace unchanged. Read-only
health checks may still run. Out-of-session maintenance remains responsible for
repairs that require exclusive write access.

The Graphify post-edit hook will use the hook payload's working directory,
falling back to the process working directory. Coordination will be scoped to
that repository. A per-repository pending marker plus a single worker will
coalesce rapid edits and run another update when an edit arrives during an
active update, avoiding both cross-repository suppression and missed changes.

Headroom health output will refer to the active agent client rather than
hard-coding Claude Code. Unsupported live `SessionEnd` configuration will be
removed when the canonical hooks file is installed.

### Diagnostics

`tools/codex/doctor-workflow.sh` will use the same Codex discovery logic as the
bootstrap. Repository discovery will include the current repository root rather
than relying on the obsolete `~/claude-workflow` path.

The doctor will add checks for:

- shell syntax and JSON/TOML parsing;
- installed hook executability and source equality;
- representative Codex hook payload smoke tests;
- installer-managed TOML values;
- MCP_DOCKER profile and Jira tool readiness;
- Graphify repository configuration using real git roots; and
- clean installer idempotency.

The doctor will distinguish configuration drift from unavailable optional
tools. Its final message will name the specific corrective command instead of
emitting an unconditional mempalace fallback warning.

### Documentation

`codex/README.md` and the root README will describe the explicit and automatic
Codex install paths accurately, document the bundled-binary fallback on macOS,
and state that MCP_DOCKER configuration is preserved except for the managed
startup timeout.

## Error Handling

- Missing Codex: the bootstrap reports a precise skip or failure depending on
  whether Codex was auto-detected or explicitly requested with `--codex`.
- Missing MCP_DOCKER table: installation preserves the config and warns; it
  does not invent a Docker profile.
- Missing Docker, profile, Atlassian server, or Jira tools: the doctor fails the
  relevant readiness check without exposing secrets.
- Gateway startup failure: the doctor reports the failing command and leaves
  the existing profile untouched.
- Live mempalace MCP writer: repair is deferred rather than attempted.
- Graphify update failure: the pending state remains observable and the hook
  logs the failure without blocking the user's edit.

## Verification

1. Run `bash -n` and ShellCheck on the modified shell scripts.
2. Parse both repository and installed JSON/TOML files.
3. Run representative hook payload smoke tests in temporary state directories.
4. Run the installer once and inspect the resulting diff.
5. Run the installer a second time and prove that no managed file or backup was
   changed.
6. Run the Codex doctor twice; both runs must complete without failures.
7. Confirm `codex mcp list` shows MCP_DOCKER enabled.
8. Confirm the `xebia` gateway enumerates 57 tools and includes Jira tools.
9. Start a fresh Codex process and perform one read-only Jira query through
   MCP_DOCKER, returning only the minimum evidence needed to prove success.
10. Confirm the repository has only the intended uncommitted changes.

## Out of Scope

- Restricting filesystem, network, shell, trust, or command access.
- Pruning permissive rules, backups, plugin caches, or duplicate personal
  skills.
- Changing Docker MCP credentials, Jira data, or the `xebia` profile contents.
- Committing, pushing, or opening a pull request.
