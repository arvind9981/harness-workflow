#!/usr/bin/env bash
# PreToolUse(Bash|Grep|Glob): enforce CLAUDE.md's "recall before re-deriving" the
# same way the graphify hook enforces graph-first search. Fires AT MOST ONCE per
# session, on the first real exploration action, injecting a MANDATORY reminder to
# run `mempalace search` before reconstructing context (past work, prior
# decisions, repo conventions) from raw files. No-op if mempalace isn't installed.
# Always exits 0 so it can never block a tool call.
MEMPALACE="$HOME/.local/bin/mempalace"
[ -x "$MEMPALACE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
cmd="$(printf '%s'  "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
sid="$(printf '%s'  "$payload" | jq -r '.session_id // "nosession"' 2>/dev/null)"

# Only fire on exploration intent: native Grep/Glob, or a Bash search/inspect cmd.
explore=0
case "$tool" in
  Grep|Glob) explore=1 ;;
  Bash) printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(grep|rg|ripgrep|find|fd|ack|ag|ls|cat|head|tail|sed|awk)([^[:alnum:]_]|$)' && explore=1 ;;
esac
[ "$explore" = 1 ] || exit 0

STATE="$HOME/.mempalace/hook_state"; mkdir -p "$STATE"
marker="$STATE/recall_nag_${sid//[^A-Za-z0-9_-]/_}"
[ -e "$marker" ] && exit 0    # already reminded this session
: > "$marker"

jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:"MANDATORY (CLAUDE.md: recall before re-deriving): before exploring files to reconstruct past work, prior decisions, or project/repo conventions, run `mempalace search \"<topic>\"` first and use what it returns. Skip only if you have already recalled for this task."}}'
exit 0
