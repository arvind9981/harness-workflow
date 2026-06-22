#!/usr/bin/env bash
# mempalace-stop-detach.sh — harden the mempalace plugin's capture hooks.
#
# Patches BOTH writers that the plugin installs:
#   * Stop      (mempal-stop-hook.sh)       — detach + single-flight + throttle
#   * PreCompact (mempal-precompact-hook.sh) — (was unguarded/synchronous)
# and adds a shared MCP-live guard to each.
#
# WHY detach (Stop): the plugin's Stop wrapper calls `mempalace hook run --hook
# stop` SYNCHRONOUSLY. Stop fires at every turn-end, so each turn blocked while
# mempalace re-mined the (growing, multi-MB) transcript — seconds up to the full
# Stop-hook timeout. And a mid-write SIGKILL at that timeout is exactly the
# HNSW/FTS5 corruption trigger we've had to recover from (see also
# mempalace-stop-timeout.sh, which raises the timeout as a safety net).
# Detaching (setsid+nohup) returns turn-end instantly; Claude Code's timeout can
# no longer kill the writer mid-write; a flock single-flight prevents overlapping
# writers; a throttle (MEMPALACE_STOP_THROTTLE, default 300s) skips re-ingesting
# the same transcript every turn.
#
# WHY the MCP-live guard (Stop + PreCompact): the in-process MCP server (binary
# `mempalace-mcp`) holds the shared chroma DB open for the WHOLE session. A
# separate CLI `mempalace hook run` writing that DB concurrently corrupts its
# FTS5 index (the recurring hang/recovery). The CLI capture and the live MCP are
# mutually-exclusive writers, so whenever an `mempalace-mcp` process is alive we
# stand the CLI capture down entirely (`pgrep -f mempalace-mcp`). The MCP server
# never matches the CLI's own cmdline (`mempalace hook run`), so the check is
# unambiguous. Net effect: during normal (MCP) sessions auto-capture defers to
# deliberate in-session MCP add_drawer/mine (the safe writer); the separate
# recap-write hook (plain JSON, not chroma) is unaffected.
#
# The plugin manager OWNS the cache and rewrites it on (re)install, so this does
# NOT survive plugin updates. init.sh runs it best-effort at the end; otherwise
# run it by hand AFTER 'claude' login (first plugin install) and AFTER every
# mempalace plugin update:  mempalace-stop-detach.sh
#
# Idempotent — re-applies only when PATCH_VERSION changes.
set -euo pipefail
PATCH_VERSION=3
shopt -s nullglob

# --- the patched Stop wrapper written into the plugin cache -----------------
read -r -d '' PATCHED_STOP <<'PATCHEOF' || true
#!/bin/bash
# MemPalace Stop Hook — PATCHED by claude-workflow (MEMPAL_STOP_DETACH v3).
# Detached + single-flight + throttled, and stands down while a live MCP server
# holds the chroma DB. Re-applied by mempalace-stop-detach.sh after plugin
# updates. Do not hand-edit; edit the installer instead.

# ---- stand down if a live MCP server is the writer -------------------------
# `mempalace-mcp` holds the chroma DB open for the whole session; a concurrent
# CLI ingest corrupts its FTS5 index. While it's alive, skip capture entirely
# (deliberate in-session MCP add_drawer/mine is the safe writer instead).
if pgrep -f mempalace-mcp >/dev/null 2>&1; then
  exit 0
fi

# ---- parent: capture stdin payload, re-exec detached, return now -----------
if [ "${MEMPAL_STOP_DETACH_CHILD:-}" != "1" ]; then
  __payload="$(cat 2>/dev/null)"
  # setsid is Linux-only; on macOS fall back to nohup+disown.
  if command -v setsid >/dev/null 2>&1; then
    MEMPAL_STOP_DETACH_CHILD=1 setsid nohup bash "$0" >/dev/null 2>&1 <<<"$__payload" &
  else
    MEMPAL_STOP_DETACH_CHILD=1 nohup bash "$0" >/dev/null 2>&1 <<<"$__payload" &
  fi
  disown 2>/dev/null || true
  exit 0
fi

# ---- child: single-flight + throttle, then run the real ingest -------------
STATE_DIR="$HOME/.mempalace"
mkdir -p "$STATE_DIR" 2>/dev/null || true
THROTTLE="${MEMPALACE_STOP_THROTTLE:-300}"   # min seconds between ingests

# One writer at a time; if an ingest is already running, skip this turn.
# flock is Linux-only; fall back to an atomic mkdir lock on macOS.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/.stop-hook.lock"
  flock -n 9 || exit 0
else
  __lockdir="$STATE_DIR/.stop-hook.lock.d"
  mkdir "$__lockdir" 2>/dev/null || exit 0
  trap 'rmdir "$__lockdir" 2>/dev/null' EXIT
fi

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

# --- the patched PreCompact wrapper written into the plugin cache -----------
read -r -d '' PATCHED_PRECOMPACT <<'PATCHEOF' || true
#!/bin/bash
# MemPalace PreCompact Hook — PATCHED by claude-workflow (MEMPAL_PRECOMPACT_GUARD v3).
# Stands down while a live MCP server holds the chroma DB; otherwise runs the
# upstream synchronous ingest. Re-applied by mempalace-stop-detach.sh after
# plugin updates. Do not hand-edit; edit the installer instead.

# ---- stand down if a live MCP server is the writer -------------------------
# Compaction always happens mid-session, so `mempalace-mcp` is essentially
# always alive here; a concurrent CLI ingest corrupts its FTS5 index. Skip.
if pgrep -f mempalace-mcp >/dev/null 2>&1; then
  exit 0
fi

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

run_mempalace_hook --hook precompact --harness claude-code
PATCHEOF

# --- apply: Stop hook -------------------------------------------------------
found=0
for hk in "$HOME"/.claude/plugins/cache/mempalace/mempalace/*/hooks/mempal-stop-hook.sh; do
  found=1
  if grep -q "MEMPAL_STOP_DETACH v${PATCH_VERSION}" "$hk"; then
    echo "stop-hook already patched (v${PATCH_VERSION}): $hk"
    continue
  fi
  cp -p "$hk" "$hk.orig-$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$PATCHED_STOP" > "$hk"
  chmod 0755 "$hk"
  echo "stop-hook patched -> detached + MCP-guard (v${PATCH_VERSION}): $hk"
done

# --- apply: PreCompact hook -------------------------------------------------
for hk in "$HOME"/.claude/plugins/cache/mempalace/mempalace/*/hooks/mempal-precompact-hook.sh; do
  found=1
  if grep -q "MEMPAL_PRECOMPACT_GUARD v${PATCH_VERSION}" "$hk"; then
    echo "precompact-hook already patched (v${PATCH_VERSION}): $hk"
    continue
  fi
  cp -p "$hk" "$hk.orig-$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$PATCHED_PRECOMPACT" > "$hk"
  chmod 0755 "$hk"
  echo "precompact-hook patched -> MCP-guard (v${PATCH_VERSION}): $hk"
done

if [ "$found" = 0 ]; then
  echo "mempalace plugin not installed yet — run this after 'claude' login (plugin install)."
fi
