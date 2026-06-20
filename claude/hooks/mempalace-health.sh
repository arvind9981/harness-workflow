#!/usr/bin/env bash
# SessionStart hook: launch the mempalace self-heal worker DETACHED and return
# immediately, so it can never add latency to (or hang) session start. The heavy
# work — quick_check, stale-lock cleanup, and a throttled query probe that
# auto-repairs a corrupt index — runs in mempalace-health-deep.sh, reparented
# away from Claude Code so a hook timeout can't SIGKILL it mid-repair.
# Emits no context (exit 0, no stdout).
DEEP="$HOME/.claude/hooks/mempalace-health-deep.sh"
# setsid is Linux-only; on macOS fall back to nohup+disown (still detaches enough
# that a hook timeout won't SIGKILL the worker mid-repair).
if [ -x "$DEEP" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$DEEP" >/dev/null 2>&1 </dev/null &
  else
    nohup "$DEEP" >/dev/null 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
fi
exit 0
