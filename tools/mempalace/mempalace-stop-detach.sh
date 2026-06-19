#!/usr/bin/env bash
# mempalace-stop-detach.sh — make the mempalace plugin's Stop hook run DETACHED.
#
# WHY: the plugin's Stop wrapper calls `mempalace hook run --hook stop`
# SYNCHRONOUSLY. Stop fires at every turn-end, so each turn blocked while
# mempalace re-mined the (growing, multi-MB) transcript — seconds up to the full
# Stop-hook timeout. And a mid-write SIGKILL at that timeout is exactly the
# HNSW/FTS5 corruption trigger we've had to recover from (see also
# mempalace-stop-timeout.sh, which raises the timeout as a safety net).
#
# This rewrites the wrapper so it re-execs DETACHED (setsid+nohup) and returns
# immediately: turn-end is instant, Claude Code's timeout can no longer kill the
# writer mid-write (the ingest finishes on its own), a flock single-flight
# prevents overlapping writers, and a throttle (MEMPALACE_STOP_THROTTLE, default
# 300s) skips re-ingesting the same transcript every turn. Since the ingest is
# now detached, the throttle affects CPU/capture granularity only — never the
# turn-end latency.
#
# The plugin manager OWNS the cache and rewrites it on (re)install, so this does
# NOT survive plugin updates. init.sh runs it best-effort at the end; otherwise
# run it by hand AFTER 'claude' login (first plugin install) and AFTER every
# mempalace plugin update:  mempalace-stop-detach.sh
#
# Idempotent — re-applies only when PATCH_VERSION changes.
set -euo pipefail
PATCH_VERSION=1
shopt -s nullglob

# --- the patched wrapper written into the plugin cache ----------------------
read -r -d '' PATCHED <<'PATCHEOF' || true
#!/bin/bash
# MemPalace Stop Hook — PATCHED by claude-workflow (MEMPAL_STOP_DETACH v1).
# Detached + single-flight + throttled. Re-applied by mempalace-stop-detach.sh
# after plugin updates. Do not hand-edit; edit the installer instead.

# ---- parent: capture stdin payload, re-exec detached, return now -----------
if [ "${MEMPAL_STOP_DETACH_CHILD:-}" != "1" ]; then
  __payload="$(cat 2>/dev/null)"
  MEMPAL_STOP_DETACH_CHILD=1 setsid nohup bash "$0" >/dev/null 2>&1 <<<"$__payload" &
  exit 0
fi

# ---- child: single-flight + throttle, then run the real ingest -------------
STATE_DIR="$HOME/.mempalace"
mkdir -p "$STATE_DIR" 2>/dev/null || true
THROTTLE="${MEMPALACE_STOP_THROTTLE:-300}"   # min seconds between ingests

# One writer at a time; if an ingest is already running, skip this turn.
exec 9>"$STATE_DIR/.stop-hook.lock"
flock -n 9 || exit 0

# Skip if we ingested recently (detached, so this is CPU/granularity, not latency).
stamp="$STATE_DIR/.stop-hook.lastrun"
now="$(date +%s)"
last="$(cat "$stamp" 2>/dev/null || echo 0)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
[ "$((now - last))" -ge "$THROTTLE" ] || exit 0
echo "$now" > "$stamp"

# ---- upstream wrapper logic (unchanged): locate + call the mempalace CLI ----
run_mempalace_hook() {
  if command -v mempalace >/dev/null 2>&1; then
    mempalace hook run "$@"
    return $?
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c "import mempalace" >/dev/null 2>&1; then
    python3 -m mempalace hook run "$@"
    return $?
  fi
  if command -v python >/dev/null 2>&1 && python -c "import mempalace" >/dev/null 2>&1; then
    python -m mempalace hook run "$@"
    return $?
  fi
  echo "MemPalace hook error: could not find a runnable mempalace command or module" >&2
  return 1
}

run_mempalace_hook --hook stop --harness claude-code
PATCHEOF

found=0
for hk in "$HOME"/.claude/plugins/cache/mempalace/mempalace/*/hooks/mempal-stop-hook.sh; do
  found=1
  if grep -q "MEMPAL_STOP_DETACH v${PATCH_VERSION}" "$hk"; then
    echo "stop-hook already detached (v${PATCH_VERSION}): $hk"
    continue
  fi
  cp -p "$hk" "$hk.orig-$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$PATCHED" > "$hk"
  chmod 0755 "$hk"
  echo "stop-hook patched -> detached (v${PATCH_VERSION}): $hk"
done

if [ "$found" = 0 ]; then
  echo "mempalace plugin not installed yet — run this after 'claude' login (plugin install)."
fi
