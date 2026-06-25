#!/usr/bin/env bash
# graphify-sync.sh — smart in-session driver for the graphify->mempalace complete map.
#
# For each repo: refresh the AST (graphify update), then re-label+stage ONLY if the
# code STRUCTURE changed since the last successful mine — detected by the node·edge
# signature, which is stable across labeling (label changes names, not AST). Emits one
# line per repo:
#     MINE wing=<w> source=<stage>   (changed -> labeled+staged; AGENT must mine it)
#     SKIP <leaf> (unchanged: ...)   (no code change; wing already correct)
#     FAIL <leaf> ...                (labeling did not converge; not mineable)
#
# The AGENT mines each MINE line via the in-process MCP `mine` tool — the ONLY safe
# in-session store writer. This script writes NOTHING to the palace.
#
# Skipping unchanged repos avoids re-spending the LLM label pass on large stable repos
# (e.g. xebia ~2.5k communities every staleness window).
#
# Stock-macOS bash 3.2 compatible (no mapfile / associative arrays).
#
# Usage: graphify-sync.sh [<repo> ...]   (default: repos in graphify-repos.conf)
set -uo pipefail

CONF="${GRAPHIFY_REPOS_CONF:-$HOME/.mempalace/graphify-repos.conf}"
STATE="$HOME/.mempalace/hook_state"
HELPER="$HOME/.local/bin/graphify-complete-map.sh"
STAGE_ROOT="${GRAPHIFY_RESEED_STAGE:-$HOME/.mempalace/reseed-stage}"
mkdir -p "$STATE"

REPOS=()
if [ "$#" -gt 0 ]; then
  REPOS=( "$@" )
else
  [ -r "$CONF" ] || { echo "graphify-sync: no conf $CONF and no args"; exit 0; }
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    REPOS+=( "$line" )
  done < "$CONF"
fi

# node:edge signature from the report (stable across labeling). Extract the two
# numbers separately to avoid matching the multibyte "·" separator. Empty if no report.
sig_of() {
  local r="$1/graphify-out/GRAPH_REPORT.md" n e
  [ -f "$r" ] || return 0
  n="$(grep -m1 -oE '[0-9]+ nodes' "$r" 2>/dev/null | grep -oE '[0-9]+')"
  e="$(grep -m1 -oE '[0-9]+ edges' "$r" 2>/dev/null | grep -oE '[0-9]+')"
  [ -n "$n" ] && [ -n "$e" ] && echo "$n:$e"
}

for d in "${REPOS[@]}"; do
  d="${d/#\~/$HOME}"
  [ -d "$d" ] || { echo "SKIP $(basename "$d") (no dir)"; continue; }
  leaf="$(basename "$d")"
  wing="graphify_${leaf//[^a-zA-Z0-9_-]/_}"
  stage="$STAGE_ROOT/$leaf"
  sigf="$STATE/graph-sig-$leaf"

  # Refresh AST (free, no LLM). Bare binary is fine — update needs no backend.
  ( cd "$d" 2>/dev/null && command -v graphify >/dev/null 2>&1 && graphify update . >/dev/null 2>&1 ) || true

  cur="$(sig_of "$d")"
  [ -n "$cur" ] || { echo "SKIP $leaf (no report)"; continue; }
  prev="$(cat "$sigf" 2>/dev/null || true)"

  if [ "$cur" = "$prev" ]; then
    # Unchanged: wing is already correct. `update` just reset the disk report to
    # placeholders, so restore the named staged copy to keep disk == wing.
    [ -f "$stage/GRAPH_REPORT.md" ] && cp "$stage/GRAPH_REPORT.md" "$d/graphify-out/GRAPH_REPORT.md" 2>/dev/null || true
    echo "SKIP $leaf (unchanged: $cur)"
    continue
  fi

  # Changed (or first run): label via claude-cli + stage (helper guards against a bad
  # label and refuses to stage placeholders).
  if "$HELPER" "$d" >/dev/null 2>&1; then
    echo "MINE wing=$wing source=$stage  (changed: ${prev:-none} -> $cur)"
    printf '%s' "$cur" > "$sigf"
  else
    echo "FAIL $leaf (label/stage did not converge — not mineable; sig unchanged)"
  fi
done
