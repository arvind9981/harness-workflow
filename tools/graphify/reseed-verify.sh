#!/usr/bin/env bash
# reseed-verify.sh — verify the IN-SESSION complete-map path for the given repos
# (default: ~/complion ~/xebia).
#
# Pipeline being verified:
#   graphify-complete-map.sh : graphify label --backend claude-cli (re-cluster + NAME
#                              communities) -> stage labeled GRAPH_REPORT.md
#   Claude (MCP mine tool)   : mine each staged report into graphify_<leaf>
#
# RUN IN-SESSION (Claude open). Two reasons this is now the opposite of the old
# out-of-session reseed:
#   1. Labeling uses the claude-cli backend (spawns the Claude CLI); a bare/script
#      `graphify` has NO backend and silently keeps "Community N" placeholders, so the
#      helper passes --backend claude-cli explicitly.
#   2. Labeling writes NOTHING to the mempalace store, so it is safe alongside a live
#      session — no concurrent-writer hazard.
# The mine step is intentionally NOT here: only the in-process MCP mine tool may write
# the store in-session. This script stages well-labeled reports and emits the
# (wing, source) pairs + STATUS: PASS_PENDING_MCP_MINE for Claude to finish + verify
# the wings via MCP list_wings / search.
#
# Log: ~/.mempalace/hook_state/reseed-verify.log
#
# NOTE: this RE-LABELS each repo (the helper's job). complion is cheap (~20
# communities); xebia is large/slow (~2.5k). Pass specific repos to scope the run,
# e.g.  reseed-verify.sh ~/complion
set -uo pipefail   # not -e: RECORD failures, don't abort on the first one

REPOS=( "$@" )
[ "${#REPOS[@]}" -eq 0 ] && REPOS=( "$HOME/complion" "$HOME/xebia" )
LOG="${RESEED_VERIFY_LOG:-$HOME/.mempalace/hook_state/reseed-verify.log}"
HELPER="$HOME/.local/bin/graphify-complete-map.sh"
STAGE_ROOT="${GRAPHIFY_RESEED_STAGE:-$HOME/.mempalace/reseed-stage}"
mkdir -p "$(dirname "$LOG")"

# Assert against the STAGED report (what will actually be mined), not the repo copy.
sph()   { local n; n=$(grep -cE '"Community [0-9]+"' "$1/GRAPH_REPORT.md" 2>/dev/null); echo "${n:-NA}"; }
snamed(){ local n; n=$(grep -cE '^### Community [0-9]+ - ' "$1/GRAPH_REPORT.md" 2>/dev/null); echo "${n:-NA}"; }

{
  echo "=== RESEED-VERIFY (in-session complete-map) @ $(date '+%F %T') ==="
  echo "    repos: ${REPOS[*]}"
  [ -x "$HELPER" ] || { echo "ABORT: helper missing/not executable: $HELPER"; echo "STATUS: ABORTED_NO_HELPER"; echo "=== END ==="; exit 1; }

  pass=0; fail=0
  declare -a MINE
  for d in "${REPOS[@]}"; do
    leaf="$(basename "$d")"
    wing="graphify_${leaf//[^a-zA-Z0-9_-]/_}"
    stage="$STAGE_ROOT/$leaf"
    echo "--- $leaf ---"

    # Helper labels (verify-retries) and stages; it exits non-zero and refuses to
    # stage if labeling never converged, so a clean exit already implies a good report.
    if "$HELPER" "$d"; then hrc=0; else hrc=$?; fi

    p="$(sph "$stage")"; n="$(snamed "$stage")"
    # Good: helper succeeded, staged report exists, has named communities, and
    # placeholders are <=20% of them (same bar the helper enforces).
    if [ "$hrc" -eq 0 ] && [ -f "$stage/GRAPH_REPORT.md" ] \
       && [ "${n:-0}" != NA ] && [ "${n:-0}" -gt 0 ] \
       && [ "${p:-NA}" != NA ] && [ "${p}" -le $(( (n + 4) / 5 )) ]; then
      echo "PASS: $leaf -> staged labeled report ($n named, $p placeholder) at $stage"
      MINE+=("MINE wing=$wing source=$stage  (named=$n placeholders=$p)")
      pass=$((pass+1))
    else
      echo "FAIL: $leaf -> helper rc=$hrc, staged report $p/$n placeholders (not mineable)"
      fail=$((fail+1))
    fi
  done

  echo "--- SUMMARY: $pass passed, $fail failed ---"
  echo "--- NEXT (Claude): mine each staged report via the in-process MCP mine tool, then confirm wings via list_wings + a named-community search ---"
  for m in "${MINE[@]}"; do echo "$m"; done
  if [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]; then echo "STATUS: PASS_PENDING_MCP_MINE"; else echo "STATUS: FAIL"; fi
  echo "=== END ==="
} 2>&1 | tee "$LOG"
