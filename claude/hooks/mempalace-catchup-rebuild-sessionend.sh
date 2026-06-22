#!/usr/bin/env bash
# SessionEnd catch-up rebuild — restore vector search after the HNSW has lagged
# enough to trip the BM25 fallback, WITHOUT blocking and WITHOUT risk of bricking
# the palace.
#
# CONTEXT (pairs with the divergence-threshold patch, chroma #6852)
# The patch makes mempalace fall back to BM25-only search whenever the on-disk
# HNSW lags sqlite (so the MCP never opens the deadlocking segment). That keeps
# the session alive but degrades semantic recall until the HNSW is rebuilt. A full
# `repair --mode from-sqlite` rebuild takes minutes (sync_threshold=2 re-persists
# the index thousands of times), so it cannot run synchronously at SessionStart.
# This hook runs it at SessionEnd instead — detached, so the session ends
# immediately — and only restores vector search for next time.
#
# ABORT-SAFE BY CONSTRUCTION
# It builds a brand-new palace into a TEMP dir from the real palace's sqlite
# (`repair --source <real> --palace <temp>`), leaving the real palace untouched.
# Only after the build succeeds AND no mempalace-mcp is live does it swap the temp
# dir into place (two renames on the same filesystem). If the build is killed, or
# no MCP-free window opens, the temp dir is discarded and the real palace is left
# exactly as it was (still fully usable via BM25). Nothing is ever written to the
# live store, so it cannot corrupt a concurrent session.
#
# GATED + THROTTLED
# - Skips unless divergence exceeds the vector-disable point (no point rebuilding
#   a store whose vectors are already fine).
# - Throttled so it runs at most once per interval (a full rebuild is CPU-heavy).
# - Single-runner flock.
set -uo pipefail

PALACE="${MEMPALACE_PALACE:-$HOME/.mempalace/palace}"
DB="$PALACE/chroma.sqlite3"
MP="${MEMPALACE_BIN:-$HOME/.local/bin/mempalace}"
SNAPSHOT="${MEMPALACE_SNAPSHOT_BIN:-$HOME/.local/bin/mempalace-snapshot.sh}"
STATE="$HOME/.mempalace/hook_state"
LOG="$HOME/.mempalace/logs/catchup-rebuild.log"
LOCK="${MEMPALACE_CATCHUP_LOCK:-$HOME/.mempalace/catchup-rebuild.lock}"
STAMP="$STATE/last-catchup"

MIN_INTERVAL="${MEMPALACE_CATCHUP_MIN_INTERVAL:-21600}"   # throttle: >= this many s between rebuilds (6h)
MIN_DIVERGENCE="${MEMPALACE_CATCHUP_MIN_DIVERGENCE:-5}"    # only rebuild when divergence >= this (vectors degraded)
BUILD_CAP="${MEMPALACE_CATCHUP_BUILD_CAP:-600}"            # watchdog: abort a stuck build after Ns
WINDOW_WAIT="${MEMPALACE_CATCHUP_WINDOW_WAIT:-180}"        # max s to wait for a no-MCP window before the swap
ARCHIVE_KEEP="${MEMPALACE_CATCHUP_ARCHIVE_KEEP:-2}"

mkdir -p "$STATE" "$(dirname "$LOG")" 2>/dev/null || true
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }

mcp_live() { pgrep -f 'mempalace-mcp' >/dev/null 2>&1; }

# ===========================================================================
# Detached worker: the slow build + guarded swap. Re-invoked via --worker so the
# hook body can return immediately and let the session end.
# ===========================================================================
if [ "${1:-}" = "--worker" ]; then
  # Hold the lock for the whole worker lifetime (best-effort).
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" 2>/dev/null || true
    flock -n 9 2>/dev/null || { log "worker: another catch-up holds the lock — exiting"; exit 0; }
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  TMP="${PALACE}.catchup-build-$ts"
  rm -rf "$TMP" 2>/dev/null || true

  # 1) Build a fresh palace into TMP from the real palace's sqlite. Real palace is
  #    only READ (sqlite is isolated), never modified — safe even if this session's
  #    MCP is still shutting down.
  log "worker: building fresh palace into $TMP from $PALACE (sqlite source)"
  "$MP" --palace "$TMP" repair --mode from-sqlite --source "$PALACE" --backup --yes >>"$LOG" 2>&1 &
  bpid=$!
  ( sleep "$BUILD_CAP"; kill -9 "$bpid" 2>/dev/null ) & wd=$!
  wait "$bpid" 2>/dev/null; brc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null || true
  if [ "$brc" -ne 0 ] || [ ! -f "$TMP/chroma.sqlite3" ]; then
    log "worker: build failed (rc=$brc) — discarding $TMP, real palace untouched"
    rm -rf "$TMP" 2>/dev/null || true
    exit 0
  fi

  # 2) Wait for a window with NO mempalace-mcp live (the swap must not rename the
  #    palace out from under a running server). Poll up to WINDOW_WAIT.
  waited=0
  while mcp_live; do
    if [ "$waited" -ge "$WINDOW_WAIT" ]; then
      log "worker: no MCP-free window within ${WINDOW_WAIT}s — discarding $TMP, will retry next SessionEnd"
      rm -rf "$TMP" 2>/dev/null || true
      exit 0
    fi
    sleep 3; waited=$(( waited + 3 ))
  done

  # 3) Snapshot (best-effort), then atomically swap TMP into place.
  [ -x "$SNAPSHOT" ] && { "$SNAPSHOT" >>"$LOG" 2>&1 && log "worker: pre-swap snapshot taken" || log "worker: snapshot failed (continuing)"; }
  # Final re-check immediately before the rename pair (closes the poll-to-swap gap).
  if mcp_live; then
    log "worker: MCP reappeared just before swap — discarding $TMP"
    rm -rf "$TMP" 2>/dev/null || true
    exit 0
  fi
  ARCH="${PALACE}.pre-rebuild-$ts"
  if mv "$PALACE" "$ARCH" 2>>"$LOG" && mv "$TMP" "$PALACE" 2>>"$LOG"; then
    date +%s > "$STAMP" 2>/dev/null || true
    log "worker: swapped in fresh palace; old archived at $ARCH"
  else
    # Best-effort recovery: if the first rename happened but the second failed,
    # put the original back so the palace is never missing.
    [ -d "$PALACE" ] || { [ -d "$ARCH" ] && mv "$ARCH" "$PALACE" 2>>"$LOG"; }
    log "worker: ERROR during swap — restored original; discarding $TMP"
    rm -rf "$TMP" 2>/dev/null || true
    exit 0
  fi

  # 4) Prune old archives (keep the most recent $ARCHIVE_KEEP). Built from a pure
  #    bash glob — no `ls`/`find` (immune to ls aliases/colorized output) and no
  #    GNU-only `head -n -N` or bash-4 mapfile, so it behaves identically on macOS
  #    BSD tools + bash 3.2 and on Linux. Timestamped names sort chronologically,
  #    so we delete the OLDEST (total - keep) via a positive `head -n N`.
  _arch_list=""
  for _d in "${PALACE}.pre-rebuild-"*; do
    [ -d "$_d" ] || continue                 # skip the literal pattern when no match
    _arch_list="${_arch_list}${_d}
"
  done
  _arch_n=$(printf '%s' "$_arch_list" | grep -c .)
  if [ "${_arch_n:-0}" -gt "$ARCHIVE_KEEP" ]; then
    printf '%s' "$_arch_list" | sort | head -n "$(( _arch_n - ARCHIVE_KEEP ))" | while IFS= read -r old; do
      [ -n "$old" ] && rm -rf -- "$old" 2>/dev/null && log "worker: pruned old archive $(basename "$old")"
    done
  fi
  exit 0
fi

# ===========================================================================
# Hook body: cheap gates, then detach the worker and return immediately.
# ===========================================================================
[ -f "$DB" ] || exit 0
command -v "$MP" >/dev/null 2>&1 || [ -x "$MP" ] || exit 0

# Throttle.
if [ -f "$STAMP" ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$(( $(date +%s) - last ))" -ge "$MIN_INTERVAL" ] || exit 0
fi

# Divergence gate (read-only; no chroma client). Only rebuild if vectors degraded.
div_n="$("$MP" --palace "$PALACE" repair-status 2>/dev/null | grep -oiE 'divergence:[[:space:]]+[0-9,]+' | grep -oE '[0-9,]+' | tr -d ',' | sort -nr | head -1)"
case "$div_n" in ''|*[!0-9]*) exit 0 ;; esac
[ "$div_n" -ge "$MIN_DIVERGENCE" ] || exit 0

log "SessionEnd: divergence=$div_n >= $MIN_DIVERGENCE — launching detached catch-up rebuild"
# Detach the worker so it survives the ending session (setsid if available).
if command -v setsid >/dev/null 2>&1; then
  setsid "$0" --worker >/dev/null 2>&1 < /dev/null &
else
  nohup "$0" --worker >/dev/null 2>&1 < /dev/null &
fi
disown 2>/dev/null || true
exit 0
