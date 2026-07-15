#!/usr/bin/env bash
# PostToolUse(Edit|Write) hook — refresh an existing repository graph without
# blocking the edit. Coordination files live inside that repository's
# graphify-out directory, so unrelated repositories never suppress each other.

set -u

lock_owner_live() {
  local owner
  owner="$(cat "$lock/pid" 2>/dev/null || true)"
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$owner" 2>/dev/null
}

lock_acquire() {
  local stale
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  lock_owner_live && return 1

  stale="$lock.stale.$$"
  mv "$lock" "$stale" 2>/dev/null || return 1
  rm -rf "$stale"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$lock/pid"
}

lock_release() {
  rm -f "$lock/pid"
  rmdir "$lock" 2>/dev/null || true
}

if [ "${1:-}" = "--worker" ]; then
  repo="${GRAPHIFY_UPDATE_REPO:?}"
  graphify="${GRAPHIFY_UPDATE_BIN:?}"
  state="$repo/graphify-out"
  pending="$state/.codex-update.pending"
  working="$state/.codex-update.working"
  lock="$state/.codex-update.lock"
  log="$state/.codex-update.log"
  printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || exit 0

  while :; do
    if ! "$graphify" update "$repo" >>"$log" 2>&1; then
      rm -f "$working"
      touch "$pending"
      lock_release
      exit 0
    fi
    rm -f "$working"

    if mv "$pending" "$working" 2>/dev/null; then
      continue
    fi

    # Release, then close the final race: an edit that observed the old lock may
    # have left a pending marker immediately before the release.
    lock_release
    if [ -e "$pending" ] && lock_acquire; then
      if mv "$pending" "$working" 2>/dev/null; then
        continue
      fi
      lock_release
    fi
    exit 0
  done
fi

[ "${CODEX_WORKFLOW_FAST:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
repo="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$repo" ] || repo="$(pwd -P)"
[ -d "$repo" ] || exit 0
repo="$(cd "$repo" 2>/dev/null && pwd -P)" || exit 0
state="$repo/graphify-out"
[ -f "$state/graph.json" ] || exit 0

graphify="${GRAPHIFY_BIN:-$HOME/.local/bin/graphify}"
if [ ! -x "$graphify" ]; then
  graphify="$(command -v graphify 2>/dev/null || true)"
fi
[ -n "$graphify" ] && [ -x "$graphify" ] || exit 0

pending="$state/.codex-update.pending"
working="$state/.codex-update.working"
lock="$state/.codex-update.lock"
touch "$pending"
lock_acquire || exit 0
rm -f "$working"
if ! mv "$pending" "$working" 2>/dev/null; then
  lock_release
  exit 0
fi

if command -v setsid >/dev/null 2>&1; then
  GRAPHIFY_UPDATE_REPO="$repo" GRAPHIFY_UPDATE_BIN="$graphify" \
    setsid "$0" --worker >/dev/null 2>&1 &
else
  GRAPHIFY_UPDATE_REPO="$repo" GRAPHIFY_UPDATE_BIN="$graphify" \
    nohup "$0" --worker >/dev/null 2>&1 &
fi
worker_pid=$!
printf '%s\n' "$worker_pid" > "$lock/pid" 2>/dev/null || true
exit 0
