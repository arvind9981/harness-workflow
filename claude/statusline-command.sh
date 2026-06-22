#!/usr/bin/env bash
# Claude Code statusLine — Material You · compact pill design
# Layout: dir · model · ctx · 5h · 7d · branch
# All chips use single-space inner padding; 1-space gap between chips.

input=$(cat)

# ── Nerd Font rounded caps ────────────────────────────────────────────────────
LEFT_CAP=$(printf '\xee\x82\xb6')    # U+E0B6
RIGHT_CAP=$(printf '\xee\x82\xb4')   # U+E0B4

RESET='\033[0m'
FG_WHITE='\033[97m'

# Material You chip colours (256-colour bg indices)
BG_DIR=67       # steel-blue   — dir
BG_MODEL=97     # soft violet  — model
BG_CTX_OK=65    # sage green   — ctx >30%
BG_CTX_WARN=136 # amber        — ctx 10-30%
BG_CTX_CRIT=131 # muted rose   — ctx <10%
BG_5H=73        # pale teal    — 5-hour
BG_7D=104       # periwinkle   — 7-day
BG_BRANCH=66    # muted green  — git branch

# ── chip <bg> <text> — single-space inner padding already in caller's text ───
chip() {
  local c="$1" label="$2"
  printf "%b" "\033[38;5;${c}m${LEFT_CAP}${RESET}\033[48;5;${c}m${FG_WHITE}${label}${RESET}\033[38;5;${c}m${RIGHT_CAP}${RESET}"
}

GAP="  "   # 2-space gap between chips (clear block separation)

_jq() { echo "$input" | jq -r "$1" 2>/dev/null; }

# Compact token formatter: 4200 → 4.2k, 200000 → 200k (no trailing .0)
fmt_k() {
  local n="$1"
  [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null && { echo "0k"; return; }
  awk -v n="$n" 'BEGIN {
    v = n/1000
    if (v == int(v)) printf "%dk", v
    else              printf "%.1fk", v
  }'
}

# Compact bar: 6 blocks, filled=█ empty=░
bar6() {
  local pct="$1" filled=$(( $1 * 6 / 100 )) bar="" i
  local empty=$(( 6 - filled ))
  for (( i=0; i<filled; i++ )); do bar="${bar}█"; done
  for (( i=0; i<empty;  i++ )); do bar="${bar}░"; done
  echo "$bar"
}

# Compact reset countdown: prefer minutes under 2h, else hours
fmt_reset() {
  local epoch="$1"
  [ -z "$epoch" ] && return
  local diff=$(( epoch - $(date +%s) ))
  [ "$diff" -le 0 ] && return
  if [ "$diff" -lt 7200 ]; then
    echo "$(( diff / 60 ))m"
  else
    echo "$(( diff / 3600 ))h"
  fi
}

# ── 1. dir ───────────────────────────────────────────────────────────────────
cwd=$(_jq '.workspace.current_dir // .cwd // ""')
dir="${cwd##*/}"; [ -z "$dir" ] && dir="~"

# ── 2. model — strip "Claude " prefix, lowercase, keep version short ─────────
model_raw=$(_jq '.model.display_name // .model.id // ""')
# "Claude Sonnet 4.5" → "sonnet 4.5" → "sonnet-4.5"
model=$(echo "$model_raw" \
  | sed 's/^[Cc]laude[[:space:]]*//' \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[[:space:]]/-/g')

# ── 3. context ───────────────────────────────────────────────────────────────
ctx_used=$(_jq '.context_window.total_input_tokens // empty')
ctx_total=$(_jq '.context_window.context_window_size // empty')
used_pct=$(_jq '.context_window.used_percentage // empty')
rem_pct=$(_jq '.context_window.remaining_percentage // empty')

ctx_chip=""
if [ -n "$used_pct" ] && [ -n "$ctx_total" ]; then
  rem_int=$(printf '%.0f' "$rem_pct")
  if   [ "$rem_int" -le 10 ]; then ctx_bg="$BG_CTX_CRIT"
  elif [ "$rem_int" -le 30 ]; then ctx_bg="$BG_CTX_WARN"
  else                              ctx_bg="$BG_CTX_OK"
  fi
  ctx_chip=$(chip "$ctx_bg" " ctx $(fmt_k "$ctx_used")/$(fmt_k "$ctx_total") · ${rem_int}% left ")
fi

# ── 4. 5-hour rate limit ─────────────────────────────────────────────────────
five_pct=$(_jq '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(_jq '.rate_limits.five_hour.resets_at // empty')

five_chip=""
if [ -n "$five_pct" ]; then
  p=$(printf '%.0f' "$five_pct")
  rst=$(fmt_reset "$five_reset")
  [ -n "$rst" ] && rst=" · ${rst}"
  five_chip=$(chip "$BG_5H" " 5h $((100 - p))% left${rst} ")
fi

# ── 5. 7-day rate limit ──────────────────────────────────────────────────────
week_pct=$(_jq '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(_jq '.rate_limits.seven_day.resets_at // empty')

week_chip=""
if [ -n "$week_pct" ]; then
  p=$(printf '%.0f' "$week_pct")
  rst=$(fmt_reset "$week_reset")
  [ -n "$rst" ] && rst=" · ${rst}"
  week_chip=$(chip "$BG_7D" " 7d $((100 - p))% left${rst} ")
fi

# ── 6. git branch ────────────────────────────────────────────────────────────
worktree_branch=$(_jq '.worktree.branch // empty')
git_branch=""
if [ -n "$worktree_branch" ]; then
  git_branch="$worktree_branch"
elif [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi

# ── assemble ─────────────────────────────────────────────────────────────────
out=$(chip "$BG_DIR" " ${dir} ")
[ -n "$model" ]      && out="${out}${GAP}$(chip "$BG_MODEL" " ${model} ")"
[ -n "$ctx_chip" ]   && out="${out}${GAP}${ctx_chip}"
[ -n "$five_chip" ]  && out="${out}${GAP}${five_chip}"
[ -n "$week_chip" ]  && out="${out}${GAP}${week_chip}"
[ -n "$git_branch" ] && out="${out}${GAP}$(chip "$BG_BRANCH" " ${git_branch} ")"

printf "%b" "$out"
