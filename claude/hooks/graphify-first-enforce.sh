#!/usr/bin/env bash
# PreToolUse(Bash|Read|Glob): when the project has a graphify graph, remind the
# agent ONCE per session to orient via `graphify query` before grepping or reading
# raw source. Replaces two always-on inline settings.json guards that re-injected
# the SAME MANDATORY text on every matching call (a per-turn context leak); throttled
# here the same way mempalace-recall-enforce.sh throttles its reminder. Always exits 0.
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name  // empty'      2>/dev/null)"
cwd="$(printf '%s'  "$payload" | jq -r '.cwd         // empty'      2>/dev/null)"
sid="$(printf '%s'  "$payload" | jq -r '.session_id  // "nosession"' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Only relevant when this project actually has a graphify graph.
[ -f "$cwd/graphify-out/graph.json" ] || exit 0

# Exploration intent: a Bash search command, or a Read/Glob of a source file
# (never the graph's own files under graphify-out/).
explore=0
case "$tool" in
  Bash)
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(grep|rg|ripgrep|find|fd|ack|ag)([^[:alnum:]_]|$)' && explore=1 ;;
  Read|Glob)
    tgt="$(printf '%s' "$payload" | jq -r '[.tool_input.file_path, .tool_input.pattern, .tool_input.path] | map(. // "") | join(" ") | ascii_downcase' 2>/dev/null | tr '\\' '/')"
    case "$tgt" in
      *graphify-out/*) ;;
      *) printf '%s' "$tgt" | grep -qE '\.(py|js|ts|tsx|jsx|go|rs|java|rb|c|h|cpp|hpp|cc|cs|kt|swift|php|scala|lua|sh|md|rst|txt)([^a-z0-9]|$)' && explore=1 ;;
    esac ;;
esac
[ "$explore" = 1 ] || exit 0

STATE="$HOME/.mempalace/hook_state"; mkdir -p "$STATE"
marker="$STATE/graphify_nag_${sid//[^A-Za-z0-9_-]/_}"
[ -e "$marker" ] && exit 0    # already reminded this session
: > "$marker"

jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:"MANDATORY: this project has a graphify graph (graphify-out/graph.json). Orient with `graphify query \"<question>\"` (or `graphify explain` / `graphify path`) BEFORE grepping or reading raw source files. Read or grep raw files only after graphify has oriented you, or to modify/debug specific lines. Applies to subagents too."}}'
exit 0
