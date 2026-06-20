#!/usr/bin/env bash
# Periodic snapshot of the mempalace palace's transactional source of truth
# (chroma.sqlite3). The HNSW vector index and FTS5 full-text index are DERIVED
# and rebuildable from this file (see `mempalace repair --mode from-sqlite` and
# the FTS5 'rebuild' command), so a crash that corrupts those indexes is fully
# recoverable as long as a good chroma.sqlite3 exists. Uses sqlite's online
# `.backup` so it's safe to run while writers are active. Rotates, keeps N.
set -euo pipefail

PALACE="${MEMPALACE_PALACE:-$HOME/.mempalace/palace}"
SRC="$PALACE/chroma.sqlite3"
DEST_DIR="${MEMPALACE_SNAPSHOT_DIR:-$HOME/.mempalace/snapshots}"
KEEP="${MEMPALACE_SNAPSHOT_KEEP:-14}"

[ -f "$SRC" ] || { echo "no palace at $SRC; nothing to snapshot"; exit 0; }
mkdir -p "$DEST_DIR"

# Serialize against another snapshot run (non-blocking: skip if one is active).
# flock is Linux-only; fall back to an atomic mkdir lock on macOS.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$DEST_DIR/.snapshot.lock"
  flock -n 9 || { echo "another snapshot in progress; skipping"; exit 0; }
else
  _lockdir="$DEST_DIR/.snapshot.lock.d"
  mkdir "$_lockdir" 2>/dev/null || { echo "another snapshot in progress; skipping"; exit 0; }
  trap 'rmdir "$_lockdir" 2>/dev/null' EXIT
fi

ts="$(date +%Y%m%d-%H%M%S)"
tmp="$DEST_DIR/chroma-$ts.sqlite3"

# Atomic online backup (consistent even with concurrent writers), then verify.
sqlite3 "$SRC" ".backup '$tmp'"
chk="$(sqlite3 "$tmp" 'PRAGMA quick_check' 2>&1 | head -1)"
if [ "$chk" != "ok" ]; then
  # Source itself is corrupt — keep the snapshot but flag it so we never rotate
  # away the last KNOWN-GOOD one in favour of a bad capture.
  mv "$tmp" "$tmp.SUSPECT"
  echo "WARNING: snapshot quick_check != ok ($chk); saved as $tmp.SUSPECT"
  gzip -f "$tmp.SUSPECT"
  exit 0
fi

gzip -f "$tmp"
echo "snapshot ok: $tmp.gz ($(du -h "$tmp.gz" | cut -f1))"

# Rotation: keep the newest $KEEP clean snapshots; never count SUSPECT toward
# the keep set, and never auto-delete SUSPECT files (they need a human look).
mapfile -t old < <(ls -1t "$DEST_DIR"/chroma-*.sqlite3.gz 2>/dev/null | tail -n +"$((KEEP+1))")
if [ "${#old[@]}" -gt 0 ]; then
  for f in "${old[@]}"; do
    [ -n "$f" ] || continue
    rm -f "$f" && echo "rotated out: $f"
  done
fi
exit 0   # success regardless of whether rotation had anything to remove
