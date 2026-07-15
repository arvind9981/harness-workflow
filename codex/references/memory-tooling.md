# Memory & Graphify — Operational Detail

Loaded on demand from `AGENTS.md`. This is the recovery layer behind the short
standing rules.

## Hooks That Enforce The Memory Rules

- `mempalace-recall-enforce.sh` injects a once-per-session recall reminder on
  the first search or exploration action.
- The user-prompt hook surfaces relevant verbatim drawers.
- The session-end catch-up hook captures the session into Mempalace.
- `mempalace-recap-write.sh` writes a local-model project recap and falls back
  to a cleaned prompt list when the local model is unavailable.
- `mempalace-recap-show.sh` surfaces that recap at the next session start.

## The FTS5 Corruption Footgun

A standalone `mempalace mine` running alongside `mempalace-mcp` creates two
writers against the same Chroma database and can corrupt FTS5. Never run CLI
mining from a hook or during a live MCP-backed session. In-session mining goes
through the active MCP tool. Offline recovery must first stop `mempalace-mcp`.

The session health hook performs read-only probes and snapshots but never starts
an automatic `repair --mode from-sqlite`; that repair is an explicit offline
troubleshooting operation.

## Graphify Auto-Sync

- `graphify-autoupdate.sh` updates an existing graph after edits. Its pending,
  working, lock, PID, and log state is repository-local under `graphify-out/`.
- `graphify-reseed-session.sh` only nudges the agent. It never mines directly.
- `graphify-sync.sh` refreshes changed repositories and prints `MINE` handoffs;
  the agent processes those handoffs through the in-process Mempalace MCP tool.

## AST Map Versus Named Map

`graphify update` is AST-only and may leave unnamed communities. A complete map
requires `graphify label` with an explicit backend in non-interactive scripts;
shell functions are not inherited by hooks or `nohup` workers.

## Headroom

Headroom is transparent routing and compression. When asked about savings, use
`headroom perf` or live proxy statistics instead of estimating.
