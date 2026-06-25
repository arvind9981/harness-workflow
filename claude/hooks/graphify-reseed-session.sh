#!/usr/bin/env bash
# SessionStart hook — NUDGE ONLY. If the graphify->mempalace wings are stale, ask
# the agent (via additionalContext) to refresh them through the in-process MCP
# `mine` tool.
#
# WHY IT DOES NOT MINE ITSELF: a CLI `mempalace mine` running alongside a live MCP
# server writes the shared chroma DB concurrently and corrupts its FTS5 index
# (observed). The only safe in-session write goes through the running MCP server,
# i.e. the agent does it. So this hook emits a request and touches NOTHING.
set -euo pipefail

CONF="${GRAPHIFY_REPOS_CONF:-$HOME/.mempalace/graphify-repos.conf}"
STATE="$HOME/.mempalace/hook_state"
STAMP="$STATE/last-reseed"          # last successful refresh (written by the agent)
NUDGED="$STATE/last-reseed-nudge"   # last nudge (written here; avoids per-session spam)
STALE_HOURS="${GRAPHIFY_RESEED_STALE_HOURS:-12}"
NUDGE_EVERY_HOURS="${GRAPHIFY_RESEED_NUDGE_HOURS:-3}"

[ -r "$CONF" ] || exit 0
mkdir -p "$STATE"
now="$(date +%s)"

_age() {  # echo seconds since the timestamp in file $1 (or a huge number if absent)
  if [ -f "$1" ]; then
    v="$(cat "$1" 2>/dev/null || echo 0)"; case "$v" in ''|*[!0-9]*) v=0 ;; esac
    echo "$(( now - v ))"
  else
    echo 999999999
  fi
}

# Quiet unless the wings are actually stale.
[ "$(_age "$STAMP")" -ge "$(( STALE_HOURS * 3600 ))" ] || exit 0
# And don't re-nudge every session in a burst.
[ "$(_age "$NUDGED")" -ge "$(( NUDGE_EVERY_HOURS * 3600 ))" ] || exit 0
echo "$now" > "$NUDGED"

if [ -f "$STAMP" ]; then stale_desc="~$(( $(_age "$STAMP") / 3600 ))h stale"; else stale_desc="never refreshed"; fi
repos="$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | tr '\n' ' ')"

# SessionStart additionalContext: a request the agent acts on early in the session.
printf '%s' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":'
printf '%s' "\"graphify→mempalace structural wings are ${stale_desc}. When convenient this session, refresh them via the IN-PROCESS MCP tools — do NOT run any CLI 'mempalace mine' or graphify-reseed.sh (a competing writer corrupts the live palace). Step 1: Bash 'GRAPHIFY_LABEL_ATTEMPTS=2 ~/.local/bin/graphify-sync.sh' — for each tracked repo it refreshes the AST and re-labels (NAMES communities via the claude-cli backend) ONLY repos whose code structure changed, printing 'MINE wing=<w> source=<s>' for those and 'SKIP <leaf>' for unchanged ones (which need no action). Step 2: for EACH 'MINE wing=<w> source=<s>' line, mine <s> into wing <w> via the mempalace_mine MCP tool — idempotent: the fixed stage path purges prior same-source drawers and re-files, so no duplication. Step 3: write \$(date +%s) to ${STAMP} to reset staleness. If graphify-sync prints 'FAIL <leaf>', its labeling did not converge — report it and do NOT mine that repo.\""
printf '%s\n' '}}'
exit 0
