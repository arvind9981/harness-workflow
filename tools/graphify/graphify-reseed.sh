#!/usr/bin/env bash
# graphify-reseed — keep mempalace's structural memory in sync with the code graph.
#
# RUNS ONLY WHEN NO MCP SERVER IS LIVE (standalone / manual out-of-session reseed):
#   A CLI `mempalace mine` running alongside a live mempalace MCP server writes the
#   shared chroma DB concurrently and corrupts its FTS5 index (observed: "malformed
#   inverted index"). The write-lock does NOT make this safe under sustained load,
#   so this script SKIPS whenever a mempalace-mcp process is running (exits 0).
#   In-session refreshes instead go through the in-process MCP mine tool, nudged by
#   the SessionStart hook (claude/hooks/graphify-reseed-session.sh). Each mine here
#   is still wrapped in a portable watchdog (_run_bounded) as a hang backstop.
#
# CYCLE (wipe-and-replace => zero staleness), run once per repo:
#   1. graphify update .                 refresh the AST graph (free, no API)
#   2. mempalace sync --wing W --apply   prune the previous run's drawers
#   3. mine ONLY GRAPH_REPORT.md         re-seed the wing from the fresh report
#
# Accepts one or more repo dirs as args (defaults to $PWD). Each repo gets its
# own wing (graphify_<repo>); a failure in one repo does not abort the others.
set -euo pipefail

# Repos to reseed: all args, or $PWD if none were given.
[ "$#" -gt 0 ] || set -- "$PWD"

MP="${MEMPALACE_BIN:-$HOME/.local/bin/mempalace}"

# Run "$@" with a hard wall-clock limit, portably (timeout(1) is absent on macOS).
# Backgrounds the command and kills it if it overruns. Returns 124 on timeout,
# else the command's own exit code.
_run_bounded() {
  _limit="$1"; shift
  "$@" & _wpid=$!
  _w=0
  while kill -0 "$_wpid" 2>/dev/null && [ "$_w" -lt "$_limit" ]; do sleep 1; _w=$((_w+1)); done
  if kill -0 "$_wpid" 2>/dev/null; then kill -9 "$_wpid" 2>/dev/null; wait "$_wpid" 2>/dev/null; return 124; fi
  wait "$_wpid"
}

# Concurrency guard (RESTORED): a CLI `mempalace mine` running alongside a live
# MCP server writes the shared chroma DB concurrently and corrupts its FTS5 index
# (observed: "malformed inverted index"). The lock does NOT make this safe under
# sustained load. So skip whenever any mempalace-mcp is running — an in-session
# refresh must go through the in-process server (MCP mine tool), not this process.
if pgrep -f 'mempalace-mcp' >/dev/null 2>&1; then
  echo "graphify-reseed: mempalace MCP server is live — skipping (a competing CLI mine corrupts the palace)"
  exit 0
fi

[ -x "$MP" ] || command -v mempalace >/dev/null 2>&1 || { echo "graphify-reseed: mempalace not found"; exit 1; }

rc=0
for REPO_DIR in "$@"; do
  # Isolate each repo in a subshell so cd, traps, and `set -e` don't leak between repos.
  (
    cd "$REPO_DIR" 2>/dev/null || { echo "graphify-reseed: cannot cd '$REPO_DIR' — skipping"; exit 0; }

    REPORT="graphify-out/GRAPH_REPORT.md"
    # Wing = graphify_<leaf>, hyphens preserved. $() strips the trailing newline;
    # bash replaces only disallowed chars (the old `tr` turned the newline into a
    # stray trailing '_' and hyphens into '_', mismatching the populated wings).
    _leaf="$(basename "$REPO_DIR")"
    WING="graphify_${_leaf//[^a-zA-Z0-9_-]/_}"

    # 1) Refresh the graph (AST-only, no API cost). Skip cleanly if graphify absent.
    if command -v graphify >/dev/null 2>&1; then
      graphify update . >/dev/null 2>&1 || echo "graphify-reseed: 'graphify update' failed in '$REPO_DIR' (continuing with existing report)"
    fi

    # Nothing to seed if the graph was never built.
    [ -f "$REPORT" ] || { echo "graphify-reseed: no $REPORT in '$REPO_DIR' — skipping"; exit 0; }

    # 2) Wipe the previous run's drawers in this wing (replace-on-update).
    #    Last run's source file (a temp path) is gone, so sync prunes the wing clean.
    "$MP" sync --wing "$WING" --apply >/dev/null 2>&1 || true

    # 3) Re-seed: mine ONLY the report. mine() slurps whole dirs, so isolate it.
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cp "$REPORT" "$TMP/"
    # Bounded mine: mempalace's lock serializes us against any live session; the
    # watchdog kills a mine that can't finish within the limit (retried next run).
    if _run_bounded 600 "$MP" mine "$TMP" --wing "$WING" --no-gitignore --agent graphify-reseed >/dev/null 2>&1; then
      echo "graphify-reseed: wing '$WING' reseeded from $REPORT"
    else
      echo "graphify-reseed: mine failed or timed out in '$REPO_DIR' — wing left wiped, will retry next run"
      exit 1
    fi
  ) || rc=1
done

exit "$rc"
