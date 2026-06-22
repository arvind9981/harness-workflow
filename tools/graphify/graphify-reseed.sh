#!/usr/bin/env bash
# graphify-reseed — TRUE wipe-and-replace reseed of mempalace's structural wings
# (graphify_<repo>) from each repo's graphify-out/GRAPH_REPORT.md.
#
# OUT-OF-SESSION ONLY. This opens the palace store directly; doing that while a
# mempalace MCP server is live means two concurrent writers on the shared chroma
# DB, which corrupts its FTS5 index ("malformed inverted index"). So the script
# SKIPS whenever a mempalace-mcp process is running. In-session refreshes go
# through the in-process MCP mine tool, nudged by the SessionStart hook
# (claude/hooks/graphify-reseed-session.sh) — which mines from the SAME stable
# stage path used here, so the in-process mine is idempotent.
#
# WHY A STABLE STAGE PATH (not mktemp): `mempalace mine` is idempotent only for a
# repeated *source path* — before re-filing it purges drawers whose source_file
# matches the file being mined. The old script staged into `mktemp -d` (a new path
# every run), so prior drawers were never matched/purged and wings DOUBLED on each
# reseed. Staging to a fixed path per repo makes mine replace-in-place.
#
# WHY AN EXPLICIT STORE WIPE (not `mempalace sync`): these report-derived drawers
# report as out_of_scope to `sync --wing` (it scopes by project_dir), so sync
# prunes nothing and cannot wipe. We delete the wing's drawers via the store, then
# mine once. A palace snapshot is taken first so the wipe is recoverable.
#
# Accepts one or more repo dirs (defaults to $PWD). One repo's failure does not
# abort the others.
set -euo pipefail

PALACE="${MEMPALACE_PALACE:-$HOME/.mempalace/palace}"
MP="${MEMPALACE_BIN:-$HOME/.local/bin/mempalace}"
PY="${MEMPALACE_PY:-$HOME/.local/share/uv/tools/mempalace/bin/python}"
STAGE_ROOT="${GRAPHIFY_STAGE_ROOT:-$HOME/.mempalace/reseed-stage}"
SNAPSHOT="${MEMPALACE_SNAPSHOT_BIN:-$HOME/.local/bin/mempalace-snapshot.sh}"

[ "$#" -gt 0 ] || set -- "$PWD"

# --- Out-of-session guard: a competing CLI/store writer corrupts the live palace.
if pgrep -f 'mempalace-mcp' >/dev/null 2>&1; then
  echo "graphify-reseed: mempalace MCP server is live — skipping (out-of-session only; close Claude first)"
  exit 0
fi
[ -x "$MP" ] || command -v mempalace >/dev/null 2>&1 || { echo "graphify-reseed: mempalace not found"; exit 1; }
[ -x "$PY" ] || { echo "graphify-reseed: python interpreter not found at $PY"; exit 1; }

# --- Safety: snapshot the palace before any destructive wipe (best-effort).
if [ -x "$SNAPSHOT" ]; then
  "$SNAPSHOT" >/dev/null 2>&1 && echo "graphify-reseed: pre-wipe palace snapshot taken" \
    || echo "graphify-reseed: WARNING snapshot failed — proceeding (wipe is still per-wing)"
fi

rc=0
for REPO_DIR in "$@"; do
  # Subshell per repo so cd / set -e / traps don't leak between repos.
  (
    cd "$REPO_DIR" 2>/dev/null || { echo "graphify-reseed: cannot cd '$REPO_DIR' — skipping"; exit 0; }
    _leaf="$(basename "$REPO_DIR")"
    # Wing = graphify_<leaf>, hyphens preserved (only disallowed chars -> '_').
    WING="graphify_${_leaf//[^a-zA-Z0-9_-]/_}"
    REPORT="graphify-out/GRAPH_REPORT.md"

    # 1) Refresh the AST graph (free, no API). Continue with existing report on failure.
    if command -v graphify >/dev/null 2>&1; then
      graphify update . >/dev/null 2>&1 || echo "graphify-reseed: 'graphify update' failed in '$REPO_DIR' (using existing report)"
    fi
    [ -f "$REPORT" ] || { echo "graphify-reseed: no $REPORT in '$REPO_DIR' — skipping"; exit 0; }

    # 2) Stable stage dir holding ONLY the report (mine slurps whole dirs).
    STAGE="$STAGE_ROOT/$_leaf"
    mkdir -p "$STAGE"; rm -f "$STAGE"/* 2>/dev/null || true; cp "$REPORT" "$STAGE/"

    # 3) WIPE the wing at the store level (sync can't — see header).
    "$PY" - "$PALACE" "$WING" <<'PY' || { echo "graphify-reseed: wipe failed for $WING"; exit 1; }
import sys
palace, wing = sys.argv[1], sys.argv[2]
from mempalace.palace import get_collection, mine_palace_lock
with mine_palace_lock(palace):
    col = get_collection(palace)
    try:
        n = len((col.get(where={"wing": wing}) or {}).get("ids") or [])
    except Exception:
        n = -1
    col.delete(where={"wing": wing})
    print(f"  wiped wing {wing} (had {n if n >= 0 else '?'} drawers)")
PY

    # 4) Mine fresh from the stable path. Idempotent on future runs (same source_file).
    if "$MP" mine "$STAGE" --wing "$WING" --no-gitignore --agent graphify-reseed >/dev/null 2>&1; then
      echo "graphify-reseed: wing '$WING' reseeded from $REPORT"
    else
      echo "graphify-reseed: mine failed in '$REPO_DIR'"
      exit 1
    fi
  ) || rc=1
done

# 5) Repair any link/index inconsistencies left by the wing wipe.
"$MP" repair >/dev/null 2>&1 || true

# 6) On full success, reset the SessionStart hook's staleness stamp so it stops nudging.
if [ "$rc" -eq 0 ]; then
  mkdir -p "$HOME/.mempalace/hook_state"
  date +%s > "$HOME/.mempalace/hook_state/last-reseed"
fi
exit "$rc"
