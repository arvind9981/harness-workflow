#!/usr/bin/env bash
# Re-apply the HNSW divergence-threshold patch to mempalace's chroma backend.
#
# WHY: chromadb 1.5.9's Rust HNSW "apply logs" path hard-deadlocks the tokio
# runtime on macOS ARM when it replays ANY un-flushed embeddings_queue tail into a
# lagging on-disk segment on open (upstream chroma #6852, open/unfixed; 1.5.9 is
# the latest release). mempalace ALREADY guards this: on client open it runs
# hnsw_capacity_status() and, if "diverged", routes search to a BM25 sqlite
# fallback WITHOUT opening the vector segment. But stock thresholds only flag
# divergence > 2000 (_HNSW_DIVERGENCE_FALLBACK_FLOOR=2000; the 10% fraction = 758
# is smaller), while chroma deadlocks at divergence ~6 — leaving a ~6..2000 dead
# zone where the store wedges but the fallback never engages. Zeroing both
# constants collapses the threshold to ``2 * sync_threshold`` (=4 for the
# sync_threshold=2 palaces this stack creates), so the fallback kicks in on small
# lag and the MCP never opens the deadlocking segment.
#
# This patch lives in mempalace's installed site-packages, so a `uv tool upgrade`
# overwrites it. init.sh calls this script after (re)install to re-apply it.
# Idempotent: a no-op if already patched. Defensive: if the stock constants are
# not found verbatim (mempalace changed them), it warns and leaves the file
# untouched rather than mis-patching — so a version change is noticed, not masked.
#
# Upstream-worthy: report to MemPalace that the fallback threshold should track the
# chroma deadlock floor (any lag) on affected chroma builds, not a fixed 2000.
set -uo pipefail

MARK="LOCAL PATCH (chroma #6852"
PY="${MEMPALACE_PY:-$HOME/.local/share/uv/tools/mempalace/bin/python}"

# Resolve the installed chroma backend module path via the mempalace interpreter
# (robust to venv layout / python version changes).
F="$("$PY" -c 'import mempalace.backends.chroma as m; print(m.__file__)' 2>/dev/null)"
if [ -z "${F:-}" ] || [ ! -f "$F" ]; then
  echo "patch-divergence-threshold: cannot locate mempalace.backends.chroma — skipping" >&2
  exit 0
fi

if grep -q "$MARK" "$F" 2>/dev/null; then
  echo "patch-divergence-threshold: already patched ($F)"
  exit 0
fi

# Only patch if BOTH stock constants are present verbatim.
if ! grep -qE '^_HNSW_DIVERGENCE_FALLBACK_FLOOR = 2000$' "$F" \
   || ! grep -qE '^_HNSW_DIVERGENCE_FRACTION = 0\.10$' "$F"; then
  echo "patch-divergence-threshold: stock constants not found verbatim in $F" >&2
  echo "  -> mempalace may have changed them; NOT patching. Review the HNSW divergence" >&2
  echo "     threshold so the BM25 fallback engages on small lag (chroma #6852)." >&2
  exit 0
fi

cp "$F" "$F.bak-divergence-patch-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

# Replace the two constant lines, prepending the marker comment before the first.
# Use a temp file + python for a precise, multiline-safe edit (no sed portability
# pitfalls with the comment block).
"$PY" - "$F" "$MARK" <<'PYEOF'
import sys
path, mark = sys.argv[1], sys.argv[2]
src = open(path).read()
block = (
    f'# {mark}, macOS-ARM HNSW replay deadlock): collapse the divergence\n'
    '# threshold to 2*sync_threshold so the existing _vector_disabled BM25 fallback\n'
    '# engages on small HNSW lag and the MCP never opens the deadlocking segment.\n'
    '# Re-applied by tools/mempalace/patch-divergence-threshold.sh after (re)install.\n'
    '_HNSW_DIVERGENCE_FALLBACK_FLOOR = 0\n'
    '_HNSW_DIVERGENCE_FRACTION = 0.0'
)
old = '_HNSW_DIVERGENCE_FALLBACK_FLOOR = 2000\n_HNSW_DIVERGENCE_FRACTION = 0.10'
if old not in src:
    sys.exit("expected stock constants block not found")
src = src.replace(old, block, 1)
open(path, "w").write(src)
PYEOF

# Verify the module still imports and the constants are zeroed.
if "$PY" -c 'import mempalace.backends.chroma as m; assert m._HNSW_DIVERGENCE_FALLBACK_FLOOR==0 and m._HNSW_DIVERGENCE_FRACTION==0.0' 2>/dev/null; then
  echo "patch-divergence-threshold: applied ($F)"
else
  echo "patch-divergence-threshold: ERROR — verification failed after patch ($F)" >&2
  exit 1
fi
