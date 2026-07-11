#!/usr/bin/env bash
# SessionStart hook: inject a clean, project-scoped mempalace orientation at the
# start of a session — identity (L0) + the essential story (L1) for the current
# project's wing, with transcript/tool noise stripped out. On-device, zero network.
# Emits nothing (exit 0) when there's no palace, no wing match, or nothing clean
# survives filtering — so it never dumps junk into a fresh session.
#
# Pairs with mempalace-recall.sh (per-prompt recall). Tunables via MEMPALACE_CTX_*.

MEMPALACE="$HOME/.local/bin/mempalace"
[ -x "$MEMPALACE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# timeout(1) is GNU coreutils — absent on stock macOS. Use it when present,
# otherwise degrade to running the command without a time limit.
_to() { _s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$_s" "$@"; else "$@"; fi; }

MAX_BYTES="${MEMPALACE_CTX_MAX_BYTES:-2200}"   # hard cap on injected context

# cwd comes from the hook payload (fallback to $PWD); wing = slug of its leaf dir.
cwd="$(cat 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
leaf="$(basename "$cwd")"
wing="$(printf '%s' "$leaf" | tr '[:upper:] -' '[:lower:]__')"

# Wing-scoped wake-up; fall back to unscoped if the wing has nothing.
raw="$(_to 8 "$MEMPALACE" wake-up --wing "$wing" < /dev/null 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
printf '%s' "$raw" | grep -q '[A-Za-z]' || \
  raw="$(_to 3 "$MEMPALACE" wake-up < /dev/null 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
[ -n "$raw" ] || exit 0

# Strip transcript/tool/command noise that pollutes the recency-scored L1 story:
# (1) hook/command/credential/listing artifacts, (2) bullets that look like shell
# or code (tool calls, pipelines, json dumps), (3) wake-up chrome lines.
ctx="$(printf '%s' "$raw" | grep -ivE \
  'command-message|command-name|command-args|local-command|local-stdout|stdout>|<command|</|MCP server|Authorization header|badly formatted|Traceback|EOFError|\.credentials|redacted|REDACTED|drwx|\.rw-|→|/doctor|No identity configured' \
  | grep -ivE '\[Bash\]|python3|grep -|sed |curl |jq |systemctl|ollama |=== |```|for f in| -c "|\$\(|&&|\|\||installed_plugins|\.jsonl\)' \
  | grep -ivE 'Wake-up text|more in L3|^=+$|^-{3,}$' \
  | grep -vE '^\s*[-•]\s*$' | awk 'BEGIN{b=0} /^[[:space:]]*$/{b++;next} {if(b)print ""; b=0; print}')"

# If filtering left the L1 story with no surviving bullets, drop the empty
# "## L1 …" scaffold so we inject just the (clean) identity rather than clutter.
if ! printf '%s' "$ctx" | grep -qE '^\s*[-•]\s+\S'; then
  ctx="$(printf '%s' "$ctx" | sed '/## L1/,$d')"
fi
# Trim trailing blank lines (portable awk; the sed -e :a/ba idiom is GNU-only).
ctx="$(printf '%s' "$ctx" | awk '{a[NR]=$0} /[^[:space:]]/{last=NR} END{for(i=1;i<=last;i++)print a[i]}')"

# Require some real signal after filtering.
printf '%s' "$ctx" | grep -q '[A-Za-z]' || exit 0
ctx="$(printf '%s' "$ctx" | head -c "$MAX_BYTES")"

jq -cn --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Project memory (mempalace wake-up):\n"+$c)}}'
exit 0
