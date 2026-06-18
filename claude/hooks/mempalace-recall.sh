#!/usr/bin/env bash
# UserPromptSubmit hook: inject relevant mempalace drawers for the current prompt
# via the local palace (semantic + bm25 over chromadb). Verbatim recall, no
# network, fully on-device. Emits nothing (exit 0, no stdout) when there's no
# prompt, the prompt is trivial, or there's no match — so it never adds noise.
#
# Replaces claude-mem-recall.sh as the auto-recall source during the
# mempalace migration trial. Reversible: re-point settings.json back if needed.

MEMPALACE="$HOME/.local/bin/mempalace"
[ -x "$MEMPALACE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

prompt="$(cat | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)"
[ -n "$prompt" ] || exit 0
# skip trivial prompts (fewer than 3 words aren't worth a search)
[ "$(printf '%s' "$prompt" | wc -w)" -ge 3 ] || exit 0

# Cap query length; run the local palace search (semantic + bm25), strip ANSI.
q="$(printf '%s' "$prompt" | head -c 400)"
raw="$(timeout 8 "$MEMPALACE" search "$q" --results 5 < /dev/null 2>/dev/null \
  | sed -r 's/\x1B\[[0-9;]*[mK]//g')"

# Only inject when there were real hits (search prints "Source:" per result).
printf '%s' "$raw" | grep -q 'Source:' || exit 0

# Trim the banner, keep the results block, cap size so injection stays light.
ctx="$(printf '%s' "$raw" | sed -n '/Results for:/,$p' | head -c 4000)"
[ -n "$ctx" ] || exit 0

jq -cn --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:("Relevant memory (mempalace verbatim recall):\n"+$c)}}'
exit 0
