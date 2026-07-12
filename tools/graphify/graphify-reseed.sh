#!/usr/bin/env bash
# graphify-reseed — TRUE wipe-and-replace reseed of mempalace's structural wings
# (graphify_<repo>) from each repo's graphify-out/GRAPH_REPORT.md.
#
# OUT-OF-SESSION ONLY. This opens the palace store directly; doing that while a
# mempalace MCP server is live means two concurrent writers on the shared chroma
# DB, which corrupts its FTS5 index ("malformed inverted index"). So the script
# SKIPS whenever a mempalace-mcp process is running. In-session refreshes go
# through the in-process MCP mine tool, nudged by the SessionStart hook
# (workflow/hooks/graphify-reseed-session.sh) — which mines from the SAME stable
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

# Helper: is a mempalace MCP server live? Checked at start, AGAIN right before the
# irreversible wipe, AND polled throughout the mine. The old launch-only check left
# a TOCTOU gap — a Claude session opening mid-run meant two concurrent chroma
# writers (hang + FTS5 corruption), which is exactly how a reseed once ran 3h+.
mcp_live() { pgrep -f 'mempalace-mcp' >/dev/null 2>&1; }

# Cumulative CPU seconds for a PID, parsed from `ps -o time=` (portable macOS/Linux).
# Used as a no-activity probe: if this stops advancing, the mine is HUNG — e.g.
# blocked on the chroma DB lock, the exact signature of the 3.5h stall (~82s CPU
# over 3.5h wall). Empty output (process gone / unreadable) -> caller treats as
# "no sample", never as progress.
cpu_secs() {
  ps -o time= -p "$1" 2>/dev/null | awk '
    { gsub(/ /,""); n=$0; sub(/\.[0-9]+$/,"",n)
      d=0; if (n ~ /-/) { split(n,x,"-"); d=x[1]; n=x[2] }
      c=split(n,p,":")
      if (c==3)      s=p[1]*3600+p[2]*60+p[3]
      else if (c==2) s=p[1]*60+p[2]
      else           s=p[1]
      print d*86400+s }'
}

# --- Out-of-session guard: a competing CLI/store writer corrupts the live palace.
if mcp_live; then
  echo "graphify-reseed: mempalace MCP server is live — skipping (out-of-session only; close Claude first)"
  exit 0
fi

# --- Single-runner lock: stop two reseeds from clobbering the store concurrently.
# flock is util-linux (Linux); stock macOS lacks it -> degrade with a warning.
LOCK="${GRAPHIFY_RESEED_LOCK:-$HOME/.mempalace/reseed.lock}"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "graphify-reseed: another reseed holds $LOCK — skipping"; exit 0; }
else
  echo "graphify-reseed: WARNING flock unavailable — concurrent-reseed protection degraded"
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
    # NOTE: community *naming* is deliberately NOT done here. `graphify label` needs
    # Anthropic auth that only exists inside a live Claude session (headroom returns
    # 401 standalone), so it cannot run out-of-session. The complete (named) map is
    # refreshed in-session via graphify-complete-map.sh + the in-process MCP mine tool.
    if command -v graphify >/dev/null 2>&1; then
      graphify update . >/dev/null 2>&1 || echo "graphify-reseed: 'graphify update' failed in '$REPO_DIR' (using existing report)"
    fi
    [ -f "$REPORT" ] || { echo "graphify-reseed: no $REPORT in '$REPO_DIR' — skipping"; exit 0; }

    # 2) Stable stage dir holding ONLY the report (mine slurps whole dirs).
    STAGE="$STAGE_ROOT/$_leaf"
    mkdir -p "$STAGE"; rm -f "$STAGE"/* 2>/dev/null || true; cp "$REPORT" "$STAGE/"

    # Re-check just before the IRREVERSIBLE wipe: a Claude session may have opened
    # during the slow 'graphify update' above. Closes most of the launch-time gap.
    if mcp_live; then
      echo "graphify-reseed: MCP server appeared before wipe — skipping '$WING' (out-of-session only)"
      exit 0
    fi

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

    # 4) Mine fresh from the stable path, but guard the WHOLE run: the mine can take
    # minutes, and a Claude session opening mid-mine is the two-writer case that
    # hangs/corrupts chroma. Run it backgrounded and poll — abort the instant an MCP
    # server appears, or if it blows past the hang cap. Bash-only (no flock/timeout),
    # so it works on stock macOS. A killed mine leaves the wing PARTIAL, but the
    # pre-wipe snapshot makes that recoverable and the SessionStart in-process mine
    # refills it. Idempotent on future runs (same source_file).
    "$MP" mine "$STAGE" --wing "$WING" --no-gitignore --agent graphify-reseed >/dev/null 2>&1 &
    _mine_pid=$!
    # Watchdog: kill the mine on ANY of three conditions, so it can never sit for
    # hours like before — (a) an MCP server appears (two-writer hazard), (b) NO
    # ACTIVITY: CPU time stops advancing for _stall s (hung / lock-blocked), or
    # (c) a hard wall-clock cap. All env-tunable; all bash-only (no flock/timeout).
    SECONDS=0; _abort=""
    _cap="${GRAPHIFY_RESEED_MINE_CAP:-1200}"   # hard wall-clock ceiling (s)
    _stall="${GRAPHIFY_RESEED_STALL:-180}"     # kill if CPU flat this long (s)
    _poll="${GRAPHIFY_RESEED_POLL:-5}"         # sample interval (s)
    _last_cpu=-1; _stall_since=0
    while kill -0 "$_mine_pid" 2>/dev/null; do
      if mcp_live; then _abort="MCP server appeared mid-mine"; break; fi
      _cpu="$(cpu_secs "$_mine_pid")"
      if [ -n "$_cpu" ] && [ "$_cpu" != "$_last_cpu" ]; then _last_cpu="$_cpu"; _stall_since="$SECONDS"; fi
      if [ "$(( SECONDS - _stall_since ))" -ge "$_stall" ]; then _abort="no activity for ${_stall}s (hung — CPU time flat)"; break; fi
      if [ "$SECONDS" -ge "$_cap" ]; then _abort="exceeded ${_cap}s wall-clock cap"; break; fi
      sleep "$_poll"
    done
    if [ -n "$_abort" ]; then
      kill -TERM "$_mine_pid" 2>/dev/null || true; wait "$_mine_pid" 2>/dev/null || true
      echo "graphify-reseed: ABORTED mine for '$WING' ($_abort) — wing left PARTIAL; snapshot taken, re-run out-of-session or let the SessionStart mine refill"
      exit 1
    fi
    if wait "$_mine_pid"; then
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
