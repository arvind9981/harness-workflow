#!/usr/bin/env bash
# graphify-reseed — keep mempalace's structural memory in sync with the code graph.
#
# WHY THIS RUNS OUT OF SESSION (nightly timer, not a per-edit hook):
#   A live Claude session holds the mempalace MCP server's palace write-lock.
#   A separate `mempalace mine` process then blocks on that lock forever (verified:
#   the miner sits at ~0% CPU holding mine_palace_*.lock). So the reseed must run
#   when no session is active. As a backstop it also detects a running MCP server
#   and skips that night rather than hang.
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

# Deadlock guard: never run while a mempalace MCP server holds the palace.
# Checked once up front — if a session is live, skip the whole run.
if pgrep -f 'mempalace-mcp' >/dev/null 2>&1; then
  echo "graphify-reseed: mempalace MCP server is live (active session) — skipping to avoid lock deadlock"
  exit 0
fi

[ -x "$MP" ] || command -v mempalace >/dev/null 2>&1 || { echo "graphify-reseed: mempalace not found"; exit 1; }

rc=0
for REPO_DIR in "$@"; do
  # Isolate each repo in a subshell so cd, traps, and `set -e` don't leak between repos.
  (
    cd "$REPO_DIR" 2>/dev/null || { echo "graphify-reseed: cannot cd '$REPO_DIR' — skipping"; exit 0; }

    REPORT="graphify-out/GRAPH_REPORT.md"
    WING="graphify_$(basename "$REPO_DIR" | tr -c 'a-zA-Z0-9_' '_')"

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
    # `timeout` is a backstop in case a session opened mid-run and grabbed the lock.
    timeout 600 "$MP" mine "$TMP" --wing "$WING" --no-gitignore --agent graphify-reseed >/dev/null \
      && echo "graphify-reseed: wing '$WING' reseeded from $REPORT" \
      || { echo "graphify-reseed: mine failed or timed out in '$REPO_DIR' (lock held?) — wing left wiped, will retry next run"; exit 1; }
  ) || rc=1
done

exit "$rc"
