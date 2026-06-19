#!/usr/bin/env bash
# MemPalace self-heal worker (runs DETACHED, never blocks a session).
# Launched fire-and-forget by mempalace-health.sh on SessionStart. Catches the
# three failure modes a crashed/SIGKILL'd writer leaves behind:
#   1. stale mine_palace lock (dead owner PID) -> removes it
#   2. malformed FTS5 inverted index           -> FTS5 'rebuild'
#   3. corrupt HNSW index (query DEADLOCKS)     -> repair --mode from-sqlite
# Throttled so it does the expensive query probe at most once per window.
# Everything is best-effort; always exits 0.
set -uo pipefail

MEMPALACE="$HOME/.local/bin/mempalace"
PALACE="${MEMPALACE_PALACE:-$HOME/.mempalace/palace}"
DB="$PALACE/chroma.sqlite3"
LOCKS="$HOME/.mempalace/locks"
STATE="$HOME/.mempalace/hook_state"
LOG="$HOME/.mempalace/logs/health.log"
STAMP="$STATE/last_health"
THROTTLE="${MEMPALACE_HEALTH_THROTTLE:-7200}"   # seconds between deep probes (2h)
PROBE_TIMEOUT="${MEMPALACE_HEALTH_PROBE_TIMEOUT:-25}"
EMBEDDER="${MEMPALACE_EMBEDDING_MODEL:-minilm}"

[ -x "$MEMPALACE" ] || exit 0
[ -f "$DB" ] || exit 0
mkdir -p "$STATE" "$(dirname "$LOG")"

log() { printf '%s  %s\n' "$(date -Is)" "$*" >> "$LOG"; }

# Single worker at a time (non-blocking).
exec 9>"$STATE/.health.lock"
flock -n 9 || exit 0

# ---- 1. stale lock cleanup (cheap, every run) -----------------------------
for lk in "$LOCKS"/mine_palace_*.lock; do
  [ -e "$lk" ] || continue
  pid="$(tr -d '\0' < "$lk" 2>/dev/null | awk '{print $1; exit}')"
  if [ -n "${pid:-}" ] && [[ "$pid" =~ ^[0-9]+$ ]]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lk" && log "removed stale lock $lk (dead pid $pid)"
    fi
  else
    rm -f "$lk" && log "removed malformed lock $lk"
  fi
done

# ---- 2. FTS5 quick_check (cheap, every run) -------------------------------
qc="$(sqlite3 "$DB" 'PRAGMA quick_check' 2>&1 | head -1)"
if [ "$qc" != "ok" ]; then
  log "quick_check NOT ok: $qc"
  if printf '%s' "$qc" | grep -qi 'fulltext\|fts'; then
    if sqlite3 "$DB" "INSERT INTO embedding_fulltext_search(embedding_fulltext_search) VALUES('rebuild');" 2>>"$LOG"; then
      log "FTS5 rebuild issued; quick_check now: $(sqlite3 "$DB" 'PRAGMA quick_check' 2>&1 | head -1)"
    fi
  fi
fi

# ---- 3. throttled HNSW probe (expensive: loads embedder + queries) --------
now="$(date +%s)"
last="$(cat "$STAMP" 2>/dev/null || echo 0)"
[[ "$last" =~ ^[0-9]+$ ]] || last=0
if [ "$((now - last))" -lt "$THROTTLE" ]; then
  exit 0
fi
echo "$now" > "$STAMP"

# A healthy drawers query returns in <1s; a corrupt HNSW deadlocks -> timeout.
timeout "$PROBE_TIMEOUT" "$MEMPALACE" search "health probe alpha" --results 1 </dev/null >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  exit 0   # healthy
fi

log "HNSW probe FAILED (rc=$rc; 124=deadlock/timeout) -> rebuilding index from sqlite"
if timeout 600 "$MEMPALACE" repair --mode from-sqlite --archive-existing --yes </dev/null >>"$LOG" 2>&1; then
  # from-sqlite does not repair FTS5; rebuild it, then re-record embedder identity.
  sqlite3 "$DB" "INSERT INTO embedding_fulltext_search(embedding_fulltext_search) VALUES('rebuild');" 2>>"$LOG" || true
  "$MEMPALACE" palace set-embedder --model "$EMBEDDER" </dev/null >>"$LOG" 2>&1 || true
  if timeout "$PROBE_TIMEOUT" "$MEMPALACE" search "health probe alpha" --results 1 </dev/null >/dev/null 2>&1; then
    log "self-heal SUCCESS: search healthy after rebuild"
  else
    log "self-heal INCOMPLETE: search still failing after rebuild — manual look needed"
  fi
else
  log "self-heal FAILED: repair --mode from-sqlite errored — manual recovery needed"
fi
exit 0
