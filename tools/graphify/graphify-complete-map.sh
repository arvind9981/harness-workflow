#!/usr/bin/env bash
# graphify-complete-map.sh — IN-SESSION prep for a complete (labeled) graphify map.
#
# Runs `graphify label` (re-clusters + NAMES communities via the live-session LLM
# backend / headroom) and stages the labeled GRAPH_REPORT.md to the shared reseed
# stage path. It does NOT write the mempalace store — Claude mines each staged report
# afterward via the in-process MCP `mine` tool, the only safe in-session writer.
#
# WHY this split (see also graphify-reseed.sh):
#   - `graphify label` authenticates ONLY inside a live Claude session; standalone,
#     headroom returns 401, so out-of-session labeling silently no-ops.
#   - `mempalace mine` from a CLI alongside a live MCP server = two chroma writers =
#     FTS5 index corruption. The in-process MCP mine avoids that.
# So the named map can only be built in-session, and only mined via MCP.
#
# Staging to the SAME path graphify-reseed.sh uses keeps the MCP mine idempotent:
# mine purges drawers whose source_file matches, then re-files — a clean in-place
# replace of the wing's report-derived drawers.
#
# Usage: graphify-complete-map.sh <repo_dir> [<repo_dir> ...]
# Output: one "MINE wing=<w> source=<stage>" line per repo for Claude to act on.
set -uo pipefail

STAGE_ROOT="${GRAPHIFY_RESEED_STAGE:-$HOME/.mempalace/reseed-stage}"
rc=0

for REPO_DIR in "$@"; do
  (
    cd "$REPO_DIR" 2>/dev/null || { echo "SKIP: cannot cd '$REPO_DIR'"; exit 0; }
    command -v graphify >/dev/null 2>&1 || { echo "SKIP: graphify not on PATH"; exit 0; }
    leaf="$(basename "$REPO_DIR")"
    wing="graphify_${leaf//[^a-zA-Z0-9_-]/_}"
    report="graphify-out/GRAPH_REPORT.md"

    # label = re-cluster + name (the named layer that makes it a complete map).
    # AST re-extraction is handled continuously by the PostToolUse update hook.
    #
    # graphify label is FLAKY: it re-clusters every run and the LLM naming pass
    # sometimes no-ops (exits 0 but leaves every community as "Community N"). So we
    # retry until the placeholder share is small, and refuse to stage a bad report
    # — mining placeholders would silently degrade the wing.
    ph()    { grep -cE '"Community [0-9]+"' "$report" 2>/dev/null || true; }
    named() { grep -cE '^### Community [0-9]+ - ' "$report" 2>/dev/null || true; }

    # In a script the `graphify` shell function is NOT loaded, so we must pass the
    # backend explicitly — bare `graphify label` finds no LLM backend and silently
    # keeps "Community N" placeholders. claude-cli labels by shelling to the Claude CLI.
    llog="/tmp/graphify-label-$leaf.log"
    attempts="${GRAPHIFY_LABEL_ATTEMPTS:-4}"
    ok=""
    for i in $(seq 1 "$attempts"); do
      GRAPHIFY_CLAUDE_CLI_MODEL="${GRAPHIFY_CLAUDE_CLI_MODEL:-sonnet}" \
        graphify label . --backend claude-cli >"$llog" 2>&1 || true
      [ -f "$report" ] || { echo "SKIP: no $report in '$REPO_DIR'"; exit 0; }
      p="$(ph)"; n="$(named)"
      # Good when there ARE named communities and placeholders are <20% of them.
      if [ "${n:-0}" -gt 0 ] && [ "${p:-0}" -le $(( (n + 4) / 5 )) ]; then
        echo "labeled: $leaf (attempt $i — $n named, $p placeholder)"
        ok=1; break
      fi
      echo "retry: $leaf attempt $i left $p/$n as placeholders"
    done

    p="$(ph)"; n="$(named)"
    stage="$STAGE_ROOT/$leaf"
    if [ -z "$ok" ]; then
      echo "FAIL: $leaf still $p/$n placeholders after $attempts attempts — NOT staging (would degrade wing)"
      exit 1
    fi
    mkdir -p "$stage"; rm -f "$stage"/* 2>/dev/null || true; cp "$report" "$stage/"
    echo "MINE  wing=$wing  source=$stage  placeholders_left=${p:-NA}  named=${n:-NA}"
  ) || rc=1
done

exit "$rc"
