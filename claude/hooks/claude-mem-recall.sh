#!/usr/bin/env bash
# UserPromptSubmit hook: inject relevant claude-mem observations for the current
# prompt via a local FTS5 query. No network, no worker dependency — reads the
# SQLite store directly so it stays sub-millisecond and safe to run every turn.
# Emits nothing (exit 0, no stdout) when there's no prompt or no match, so it
# never adds noise to trivial turns.

DB="$HOME/.claude-mem/claude-mem.db"
[ -f "$DB" ] || exit 0
command -v jq      >/dev/null 2>&1 || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0

prompt="$(cat | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)"
[ -n "$prompt" ] || exit 0

# Build a safe FTS5 OR-query: lowercase, keep alphanumeric tokens >=3 chars,
# cap at 12, quote each (quoting prevents any FTS operator / SQL-quote injection
# since tokens are already stripped to [a-z0-9]).
query="$(printf '%s' "$prompt" \
  | tr '[:upper:]' '[:lower:]' \
  | grep -oE '[a-z0-9]{3,}' 2>/dev/null \
  | head -12 \
  | awk '{printf "%s\"%s\"", (NR>1 ? " OR " : ""), $0}')"
[ -n "$query" ] || exit 0

results="$(sqlite3 -separator '|' "$DB" "
SELECT o.id, o.title, COALESCE(o.subtitle,'')
FROM observations_fts f
JOIN observations o ON o.id = f.rowid
WHERE observations_fts MATCH '$query'
ORDER BY bm25(observations_fts) LIMIT 5;" 2>/dev/null)"
[ -n "$results" ] || exit 0

list="$(printf '%s\n' "$results" | awk -F'|' 'NF{printf "- #%s %s — %s\n", $1, $2, $3}')"
ctx="$(printf 'Possibly relevant claude-mem observations from prior sessions (pull full detail with get_observations([ids]) only if useful to this turn):\n%s' "$list")"

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
