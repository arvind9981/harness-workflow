# Model-Team Observability Design

**Date:** 2026-07-15

## Objective

Make native Codex MCP work visibly verifiable without wrapping the MCP server,
forwarding worker transcripts, or adding stateful machinery to the critical
path. Also make `headroom-watch` identify the latest observed model and client.

## Interfaces

`model-team-watch` is a passive terminal dashboard:

```text
model-team-watch [--once] [--json] [--repo PATH] [-n SECONDS]
```

It reports:

- whether the isolated `codex mcp-server` process exists, plus PID and uptime;
- the latest completed Headroom request whose client is Codex, including model,
  timestamp, latency, and a five-minute unique-request count;
- Headroom health; and
- current repository branch, changed-file count, and diff summary.

The default mode refreshes continuously. `--once` is human-readable and
non-interactive. `--json` emits one machine-readable snapshot and exits.

`headroom-watch` keeps its existing compression dashboard and changes its header
to show the latest observed request model, client, and timestamp. This is labeled
as the latest observation rather than claiming an in-flight request can always
be identified.

## Lifecycle Receipts

The `model-team` skill announces standardized dispatch, review, and completion
receipts. Each dispatch names the phase, worker, selected/default model, access
level, and repository. Completion names the thread ID, changed files, and test
evidence. These are concise controller messages, not durable state files.

## Portability And Safety

- Use Bash, `ps`, `curl`, `jq`, and Git already required by the workflow.
- Support macOS and Linux process listings.
- Never read prompts, responses, raw worker transcripts, tokens, or credentials.
- Treat process existence as server availability and Headroom request timestamps
  as activity evidence; never label an idle server as an active model call.
- Keep the watcher entirely outside the MCP command path.

## Installation And Verification

`init.sh` installs `model-team-watch` into `~/.local/bin` when Codex is detected.
The model-team installer also deploys it for focused updates. Tests inject fixed
process and Headroom snapshots, verify text/JSON output and repository state,
confirm the enhanced Headroom header, and check second-run idempotency.
