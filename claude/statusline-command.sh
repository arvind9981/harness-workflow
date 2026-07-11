#!/usr/bin/env bash
# Claude Code statusLine — Material You · compact pill design
# Layout: dir · model · ctx · 5h · 7d · branch
#
# COLOUR SYSTEM (24-bit truecolor, so it's vivid regardless of terminal theme):
#   - A cohesive COOL jewel palette for the normal bar (blue, violet, emerald,
#     cyan, indigo, teal) — vibrant but harmonious.
#   - WARM is reserved: amber = low (11–30% left), red = critical (≤10% left).
#     Since nothing else on the bar is warm, a warning is the only hot chip and
#     pops instantly.
# The three stateful chips (ctx / 5h / 7d) are driven by the SAME "% left" they
# display via stateful(), so colour and number can never disagree. One number per
# chip; the reset countdown appears only in warn/crit. dir/branch are truncated so
# a long name can't blow out the width; a dirty repo adds a small amber dot.

input=$(cat)

# ── Nerd Font rounded caps ────────────────────────────────────────────────────
LEFT_CAP=$(printf '\xee\x82\xb6')    # U+E0B6
RIGHT_CAP=$(printf '\xee\x82\xb4')   # U+E0B4

# ── Palette (truecolor "R;G;B") ──────────────────────────────────────────────
WHITE="240;244;248"      # light text
DARKTX="24;26;30"        # dark text — for the bright amber chip
DIR_BG="45;110;225"      # blue
MODEL_BG="128;90;232"    # violet
BRANCH_BG="17;145;150"   # teal
CTX_OK="14;165;110"      # emerald   — ctx healthy
FIVE_OK="20;150;190"     # cyan      — 5h healthy
WEEK_OK="95;95;218"      # indigo    — 7d healthy
WARN_BG="240;160;24"     # amber     — low       (dark text)
CRIT_BG="228;58;58"      # red       — critical  (light text)
DIRTY="240;160;24"       # amber dot — uncommitted changes

# ── chip <bg_rgb> <fg_rgb> <label> ───────────────────────────────────────────
chip() {
  local b="$1" f="$2" label="$3"
  printf "%b" "\033[38;2;${b}m${LEFT_CAP}\033[0m\033[48;2;${b}m\033[38;2;${f}m${label}\033[0m\033[38;2;${b}m${RIGHT_CAP}\033[0m"
}

GAP="  "   # 2-space gap between chips

_jq() { echo "$input" | jq -r "$1" 2>/dev/null; }

# Truncate an over-long label to N chars with an ellipsis.
trunc() {
  local s="$1" n="${2:-18}"
  if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$((n-1))}"; else printf '%s' "$s"; fi
}

# Compact token formatter: 4200 → 4.2k, 200000 → 200k.
fmt_k() {
  local n="$1"
  { [ -z "$n" ] || [ "$n" -eq 0 ] 2>/dev/null; } && { echo "0k"; return; }
  awk -v n="$n" 'BEGIN { v=n/1000; if (v==int(v)) printf "%dk", v; else printf "%.1fk", v }'
}

# Single source of truth: "percent left" + this chip's healthy colour → "bg|fg".
# Warm (amber/red) overrides the cool healthy colour when the number is low, so
# colour and number always agree.
stateful() {
  local l="$1" ok="$2"
  if   [ "$l" -le 10 ]; then echo "${CRIT_BG}|${WHITE}"
  elif [ "$l" -le 30 ]; then echo "${WARN_BG}|${DARKTX}"
  else                       echo "${ok}|${WHITE}"
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

# ── 3. context — % left; tokens remaining shown only in crit ─────────────────
ctx_used=$(_jq '.context_window.total_input_tokens // empty')
ctx_total=$(_jq '.context_window.context_window_size // empty')
rem_pct=$(_jq '.context_window.remaining_percentage // empty')

ctx_chip=""
if [ -n "$rem_pct" ] && [ -n "$ctx_total" ]; then
  rem_int=$(printf '%.0f' "$rem_pct")
  IFS='|' read -r bg fg <<< "$(stateful "$rem_int" "$CTX_OK")"
  label=" ctx ${rem_int}% "
  if [ "$rem_int" -le 10 ] && [ -n "$ctx_used" ]; then
    label=" ctx ${rem_int}% · $(fmt_k "$(( ctx_total - ctx_used ))") left "
  fi
  ctx_chip=$(chip "$bg" "$fg" "$label")
fi

# ── 4. 5-hour rate limit — % left; reset shown only when low ─────────────────
five_pct=$(_jq '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(_jq '.rate_limits.five_hour.resets_at // empty')

five_chip=""
if [ -n "$five_pct" ]; then
  left=$(( 100 - $(printf '%.0f' "$five_pct") ))
  IFS='|' read -r bg fg <<< "$(stateful "$left" "$FIVE_OK")"
  label=" 5h ${left}% "
  if [ "$left" -le 30 ]; then
    rst=$(fmt_reset "$five_reset")
    [ -n "$rst" ] && label=" 5h ${left}% · ${rst} "
  fi
  five_chip=$(chip "$bg" "$fg" "$label")
fi

# ── 5. 7-day rate limit — % left; reset shown only when low ──────────────────
week_pct=$(_jq '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(_jq '.rate_limits.seven_day.resets_at // empty')

week_chip=""
if [ -n "$week_pct" ]; then
  left=$(( 100 - $(printf '%.0f' "$week_pct") ))
  IFS='|' read -r bg fg <<< "$(stateful "$left" "$WEEK_OK")"
  label=" 7d ${left}% "
  if [ "$left" -le 30 ]; then
    rst=$(fmt_reset "$week_reset")
    [ -n "$rst" ] && label=" 7d ${left}% · ${rst} "
  fi
  week_chip=$(chip "$bg" "$fg" "$label")
fi

# ── 6. git branch (+ dirty marker) ───────────────────────────────────────────
worktree_branch=$(_jq '.worktree.branch // empty')
git_branch=""; dirty=""; in_repo=""
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  in_repo=1
fi
if [ -n "$worktree_branch" ]; then
  git_branch="$worktree_branch"
elif [ -n "$in_repo" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi
if [ -n "$in_repo" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | head -1)" ]; then
  dirty=1
fi
[ -n "$git_branch" ] && git_branch=$(trunc "$git_branch" 18)

# ── assemble ─────────────────────────────────────────────────────────────────
out=$(chip "$DIR_BG" "$WHITE" " ${dir} ")
[ -n "$model" ]     && out="${out}${GAP}$(chip "$MODEL_BG" "$WHITE" " ${model} ")"
[ -n "$ctx_chip" ]  && out="${out}${GAP}${ctx_chip}"
[ -n "$five_chip" ] && out="${out}${GAP}${five_chip}"
[ -n "$week_chip" ] && out="${out}${GAP}${week_chip}"
if [ -n "$git_branch" ]; then
  blabel=" ${git_branch} "
  [ -n "$dirty" ] && blabel=" ${git_branch} \033[38;2;${DIRTY}m●\033[38;2;${WHITE}m "
  out="${out}${GAP}$(chip "$BRANCH_BG" "$WHITE" "$blabel")"
fi

printf "%b" "$out"
