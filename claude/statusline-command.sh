#!/usr/bin/env bash
# Claude Code statusLine — Material You · compact pill design
# Layout: dir · model · ctx · 5h · 7d · branch
#
# Design principle: COLOR = STATE, NEUTRAL = STATIC.
#   - dir / model / branch are static context → one muted neutral (they recede).
#   - ctx / 5h / 7d are stateful → calm teal when healthy, amber when low,
#     red when critical, so the ONE thing worth noticing is the only hot colour.
# All three stateful chips are coloured by the SAME "% left" they display, via
# style_for_left(), so colour and number can never disagree. One number per chip;
# the reset countdown appears only when that limit is in warn/crit. Text colour is
# chosen for legibility: white on the dark teal/red, dark on the bright amber.
# dir/branch are truncated so a long name can't blow out the bar width.

input=$(cat)

# ── Nerd Font rounded caps ────────────────────────────────────────────────────
LEFT_CAP=$(printf '\xee\x82\xb6')    # U+E0B6
RIGHT_CAP=$(printf '\xee\x82\xb4')   # U+E0B4
RESET='\033[0m'

# ── Palette (256-colour indices) ─────────────────────────────────────────────
FG_LIGHT=231    # near-white text
FG_DARK=16      # black text — for the bright amber chip (white on amber is illegible)
BG_STATIC=238   # muted grey  — dir / model / branch (static context, recedes)
BG_OK=23        # deep teal   — healthy   (>30% left)   · white ~6:1
BG_WARN=178     # bright amber — low       (11–30% left)  · dark  ~9:1
BG_CRIT=160     # red         — critical  (≤10% left)   · white ~5:1

# ── chip <bg> <text> [fg] ────────────────────────────────────────────────────
chip() {
  local c="$1" label="$2" fg="${3:-$FG_LIGHT}"
  printf "%b" "\033[38;5;${c}m${LEFT_CAP}${RESET}\033[48;5;${c}m\033[38;5;${fg}m${label}${RESET}\033[38;5;${c}m${RIGHT_CAP}${RESET}"
}

GAP="  "   # 2-space gap between chips (clear block separation)

_jq() { echo "$input" | jq -r "$1" 2>/dev/null; }

# Truncate an over-long label to N chars with an ellipsis, so dir/branch names
# can't dominate the bar.
trunc() {
  local s="$1" n="${2:-18}"
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$((n-1))}"; else printf '%s' "$s"; fi
}

# Compact token formatter: 4200 → 4.2k, 200000 → 200k (no trailing .0)
fmt_k() {
  local n="$1"
  { [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; } && { echo "0k"; return; }
  awk -v n="$n" 'BEGIN {
    v = n/1000
    if (v == int(v)) printf "%dk", v
    else              printf "%.1fk", v
  }'
}

# Single source of truth: given a "percent left", echo "<bg> <fg>" for the chip —
# so every stateful chip's colour and text-legibility match the number shown.
style_for_left() {
  local l="$1"
  if   [ "$l" -le 10 ]; then echo "$BG_CRIT $FG_LIGHT"
  elif [ "$l" -le 30 ]; then echo "$BG_WARN $FG_DARK"
  else                       echo "$BG_OK $FG_LIGHT"
  fi
}

# Compact reset countdown: minutes under 2h, hours under 2d, else days.
fmt_reset() {
  local epoch="$1"
  [ -z "$epoch" ] && return
  local diff=$(( epoch - $(date +%s) ))
  [ "$diff" -le 0 ] && return
  if   [ "$diff" -lt 7200 ];   then echo "$(( diff / 60 ))m"
  elif [ "$diff" -lt 172800 ]; then echo "$(( diff / 3600 ))h"
  else                              echo "$(( diff / 86400 ))d"
  fi
}

# ── 1. dir ───────────────────────────────────────────────────────────────────
cwd=$(_jq '.workspace.current_dir // .cwd // ""')
dir="${cwd##*/}"; [ -z "$dir" ] && dir="~"
dir=$(trunc "$dir" 18)

# ── 2. model — strip "Claude " prefix, lowercase, hyphenate ──────────────────
model_raw=$(_jq '.model.display_name // .model.id // ""')
model=$(echo "$model_raw" \
  | sed 's/^[Cc]laude[[:space:]]*//' \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[[:space:]]/-/g')

# ── 3. context — one number (% left); tokens remaining shown only in crit ────
ctx_used=$(_jq '.context_window.total_input_tokens // empty')
ctx_total=$(_jq '.context_window.context_window_size // empty')
rem_pct=$(_jq '.context_window.remaining_percentage // empty')

ctx_chip=""
if [ -n "$rem_pct" ] && [ -n "$ctx_total" ]; then
  rem_int=$(printf '%.0f' "$rem_pct")
  read -r bg fg <<< "$(style_for_left "$rem_int")"
  label=" ctx ${rem_int}% "
  if [ "$rem_int" -le 10 ] && [ -n "$ctx_used" ]; then
    label=" ctx ${rem_int}% · $(fmt_k "$(( ctx_total - ctx_used ))") left "
  fi
  ctx_chip=$(chip "$bg" "$label" "$fg")
fi

# ── 4. 5-hour rate limit — % left; reset shown only when low ─────────────────
five_pct=$(_jq '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(_jq '.rate_limits.five_hour.resets_at // empty')

five_chip=""
if [ -n "$five_pct" ]; then
  left=$(( 100 - $(printf '%.0f' "$five_pct") ))
  read -r bg fg <<< "$(style_for_left "$left")"
  label=" 5h ${left}% "
  if [ "$left" -le 30 ]; then
    rst=$(fmt_reset "$five_reset")
    [ -n "$rst" ] && label=" 5h ${left}% · ${rst} "
  fi
  five_chip=$(chip "$bg" "$label" "$fg")
fi

# ── 5. 7-day rate limit — % left; reset shown only when low ──────────────────
week_pct=$(_jq '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(_jq '.rate_limits.seven_day.resets_at // empty')

week_chip=""
if [ -n "$week_pct" ]; then
  left=$(( 100 - $(printf '%.0f' "$week_pct") ))
  read -r bg fg <<< "$(style_for_left "$left")"
  label=" 7d ${left}% "
  if [ "$left" -le 30 ]; then
    rst=$(fmt_reset "$week_reset")
    [ -n "$rst" ] && label=" 7d ${left}% · ${rst} "
  fi
  week_chip=$(chip "$bg" "$label" "$fg")
fi

# ── 6. git branch (+ dirty marker) ───────────────────────────────────────────
worktree_branch=$(_jq '.worktree.branch // empty')
git_branch=""; dirty=""
in_repo=""
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  in_repo=1
fi
if [ -n "$worktree_branch" ]; then
  git_branch="$worktree_branch"
elif [ -n "$in_repo" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi
# Uncommitted changes (staged, unstaged, or untracked) → dirty. One cheap git call.
if [ -n "$in_repo" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | head -1)" ]; then
  dirty=1
fi
[ -n "$git_branch" ] && git_branch=$(trunc "$git_branch" 18)

# ── assemble — static chips muted; stateful chips carry the only colour ──────
out=$(chip "$BG_STATIC" " ${dir} ")
[ -n "$model" ]      && out="${out}${GAP}$(chip "$BG_STATIC" " ${model} ")"
[ -n "$ctx_chip" ]   && out="${out}${GAP}${ctx_chip}"
[ -n "$five_chip" ]  && out="${out}${GAP}${five_chip}"
[ -n "$week_chip" ]  && out="${out}${GAP}${week_chip}"
if [ -n "$git_branch" ]; then
  blabel=" ${git_branch} "
  # dirty → a small amber dot (editor convention for "modified"), on the grey chip
  [ -n "$dirty" ] && blabel=" ${git_branch} \033[38;5;${BG_WARN}m●\033[38;5;${FG_LIGHT}m "
  out="${out}${GAP}$(chip "$BG_STATIC" "$blabel")"
fi

printf "%b" "$out"
