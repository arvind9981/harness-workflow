#!/usr/bin/env bash
# Re-apply the mempalace plugin's Stop-hook timeout (default 90s, up from the
# shipped 30s). WHY: a Stop-hook capture whose ChromaDB flush exceeds the timeout
# gets SIGKILL'd mid-write, and ChromaDB's HNSW + FTS5 indexes are not crash-atomic
# -> corruption + a hung palace. 90s gives the flush room to finish.
#
# The plugin manager OWNS hooks/hooks.json and rewrites it on (re)install, so this
# bump does NOT survive plugin installs/updates. Run this AFTER `claude` login
# (first plugin install) and AFTER every mempalace plugin update. init.sh runs it
# best-effort at the end; otherwise run it by hand:  mempalace-stop-timeout.sh
#
# Idempotent. Usage: mempalace-stop-timeout.sh [timeout_seconds]   (default 90)
set -euo pipefail
TIMEOUT="${1:-${MEMPALACE_STOP_TIMEOUT:-90}}"
shopt -s nullglob

found=0
for hj in "$HOME"/.claude/plugins/cache/mempalace/mempalace/*/hooks/hooks.json; do
  found=1
  cur="$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$hj" 2>/dev/null || true)"
  if [ "$cur" = "$TIMEOUT" ]; then
    echo "Stop timeout already ${TIMEOUT}s: $hj"
    continue
  fi
  cp -p "$hj" "$hj.bak-$(date +%Y%m%d-%H%M%S)"
  tmp="$(mktemp)"
  jq --argjson t "$TIMEOUT" '.hooks.Stop[0].hooks[0].timeout = $t' "$hj" > "$tmp" && mv "$tmp" "$hj"
  echo "Stop timeout ${cur:-unset} -> ${TIMEOUT}s: $hj"
done

if [ "$found" = 0 ]; then
  echo "mempalace plugin not installed yet — run this after 'claude' login (plugin install)."
fi
