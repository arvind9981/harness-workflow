---
name: jira-live
description: Use when a request reads, searches, creates, updates, transitions, comments on, or otherwise operates on Jira issues, tickets, projects, boards, sprints, or worklogs.
---

# Jira Live

Use live `MCP_DOCKER` Jira tools for every Jira request. Never present cached
session history or memory as current Jira state.

When the Docker gateway exposes `mcp-exec` instead of individual Jira tools,
make the live call through `mcp-exec` using this shape:

```json
{"name": "jira_<operation>", "arguments": {"<argument>": "<value>"}}
```

Treat that wrapper invocation as the Jira call for retry and write-safety rules.
Do not run `mcp-find`; the configured profile already owns server discovery.

## Transport Recovery

If a read-only Jira call error contains `Transport closed`, retry the identical read-only Jira tool call once, immediately and with identical arguments. Do not
list or discover tools, call `mcp-exec`, or launch another agent or Codex process
between attempts.

If the retry also contains `Transport closed`, report that the in-session
transport is unavailable, then call the same read-only Jira tool through the
configured Docker gateway:

```text
docker mcp tools call <tool-name> --gateway-arg=--profile=<configured-profile> 'key=value' ...
```

Reuse the profile configured for `MCP_DOCKER`; do not assume a machine-specific
profile name. Keep every value-containing argument quoted. Do not run catalog commands first.
If the direct call fails, report `MCP_DOCKER` as unavailable before considering
any non-live fallback.

Never automatically replay a Jira write after `Transport closed`; its outcome
may be ambiguous. First verify the current state with a live read-only call,
then decide whether another write is safe. In a model-team task, Claude is the
only Jira actor and passes Codex an immutable ticket snapshot.
