#!/usr/bin/env bash
# SessionStart hook: launch the Mempalace diagnostic worker DETACHED and return
# immediately, so it can never add latency to (or hang) session start. The heavy
# work — quick_check, stale-lock cleanup, and a throttled query probe that
# reports corrupt indexes for offline recovery — runs in
# mempalace-health-deep.sh, reparented away from the invoking agent.
# Emits no context (exit 0, no stdout).
# Resolve relative to this installed wrapper.  The same repo-owned hook is
# installed into both ~/.claude/hooks and ~/.codex/hooks, so hard-coding the
# former made Codex depend on a separate Claude installation.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
DEEP="$HOOK_DIR/mempalace-health-deep.sh"
# setsid is Linux-only; on macOS fall back to nohup+disown (still detaches enough
# that a hook timeout will not kill the diagnostic worker).
if [ -x "$DEEP" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$DEEP" >/dev/null 2>&1 </dev/null &
  else
    nohup "$DEEP" >/dev/null 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
fi
exit 0
