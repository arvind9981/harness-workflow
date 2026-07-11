#!/usr/bin/env bash
# Refresh graphify-backed mempalace structural memory.
#
# Discovers actual git repos, writes graphify-repos.conf, runs graphify-sync.sh,
# mines confirmed MINE outputs only when it is safe to write to mempalace, and
# can prune stale graphify-out directories outside the discovered repo roots.
#
# MANUAL / OUT-OF-SESSION ONLY — not wired into any hook. It can CLI-mine and (with
# --stop-live-mempalace) stop live writers, so running it while a Claude session is
# open risks the concurrent-writer FTS5 corruption this stack guards against. For
# in-session refreshes use the SessionStart nudge (graphify-reseed-session.sh ->
# graphify-sync.sh) plus the in-process MCP mine tool instead.

set -uo pipefail

CONF="${GRAPHIFY_REPOS_CONF:-$HOME/.mempalace/graphify-repos.conf}"
STATE="$HOME/.mempalace/hook_state"
PENDING="$STATE/graphify-pending-mines"
SYNC="${GRAPHIFY_SYNC_BIN:-$HOME/.local/bin/graphify-sync.sh}"
MP="${MEMPALACE_BIN:-$HOME/.local/bin/mempalace}"
LABEL_ATTEMPTS="${GRAPHIFY_LABEL_ATTEMPTS:-2}"
INCLUDE_LARGE=0
DRY_RUN=0
STOP_LIVE_MEMPALACE=0
PRUNE_STALE=0
PRUNE_WORKTREES=0

usage() {
  cat <<'USAGE'
Usage: tools/graphify/refresh-structural-memory.sh [options]

Discovers actual git repo roots under:
  ~/claude-workflow
  ~/xebia/*
  ~/complion/*

Then writes ~/.mempalace/graphify-repos.conf, runs graphify-sync.sh for the
selected repos, and mines confirmed MINE outputs into graphify_<repo> mempalace
wings.

Options:
  --dry-run               Show discovered repos and planned actions without writes.
  --include-large         Include large label-heavy repos such as ACE-Agents.
  --stop-live-mempalace   Stop live mempalace writer processes before CLI mining.
                           Use only to drain pending mines when no MCP mine tool
                           is available in the current session.
  --prune-stale           Remove graphify-out dirs not under discovered repo roots.
  --prune-worktrees       With --prune-stale, also prune graphify-out dirs inside
                           git worktrees that are not discovered repo roots.
  -h, --help              Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --include-large) INCLUDE_LARGE=1 ;;
    --stop-live-mempalace) STOP_LIVE_MEMPALACE=1 ;;
    --prune-stale) PRUNE_STALE=1 ;;
    --prune-worktrees) PRUNE_WORKTREES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "refresh-structural-memory: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

repo_root_of() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || true
}

discover_repos() {
  repo_root_of "$HOME/claude-workflow"

  for root in "$HOME/xebia" "$HOME/complion"; do
    [ -d "$root" ] || continue

    for child in "$root"/*; do
      [ -d "$child" ] || continue
      repo_root_of "$child"
    done
  done | awk 'NF && !seen[$0]++' | sort
}

is_large_repo() {
  case "$(basename "$1")" in
    ACE-Agents) return 0 ;;
    *) return 1 ;;
  esac
}

repo_list_contains() {
  local needle="$1"
  local line

  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$repos
EOF

  return 1
}

discover_graphify_dirs() {
  for root in "$HOME/claude-workflow" "$HOME/xebia" "$HOME/complion"; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 4 -type d -name graphify-out 2>/dev/null
  done | sort
}

prune_stale_graphify_dirs() {
  local dirs="$1"
  local dir
  local owner
  local git_root
  local stale=""
  local skipped_worktrees=""

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    owner="${dir%/graphify-out}"

    if repo_list_contains "$owner"; then
      continue
    fi

    git_root="$(repo_root_of "$owner")"
    if [ -n "$git_root" ] && [ "$git_root" = "$owner" ] && [ "$PRUNE_WORKTREES" -eq 0 ]; then
      skipped_worktrees="${skipped_worktrees}${dir}
"
      continue
    fi

    stale="${stale}${dir}
"
  done <<EOF
$dirs
EOF

  if [ -n "$skipped_worktrees" ]; then
    echo "Stale worktree graphify-out dirs skipped:"
    printf '%s\n' "$skipped_worktrees" | sed '/^$/d; s/^/  /'
  fi

  if [ -z "$stale" ]; then
    echo "No stale graphify-out dirs to prune."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "Would prune stale graphify-out dirs:"
    printf '%s\n' "$stale" | sed '/^$/d; s/^/  /'
    return 0
  fi

  echo "Pruning stale graphify-out dirs:"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    echo "  $dir"
    rm -rf "$dir" || return 1
  done <<EOF
$stale
EOF
}

mempalace_writer_pids() {
  ps -axo pid=,command= 2>/dev/null | awk '
    {
      pid = $1
      cmd = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", cmd)
    }
    cmd ~ /(^|\/)mempalace-mcp([[:space:]]|$)/ {
      print pid
      next
    }
    cmd ~ /(^|\/)mempalace[[:space:]]+mine([[:space:]]|$)/ {
      print pid
    }
  '
}

mempalace_writer_live() {
  [ -n "$(mempalace_writer_pids)" ]
}

stop_mempalace_writers() {
  local pids
  local remaining
  local i

  pids="$(mempalace_writer_pids)"
  [ -n "$pids" ] || return 0

  echo "Stopping live mempalace writer processes:"
  printf '%s\n' "$pids" | sed 's/^/  pid /'

  if ! kill $pids 2>/dev/null; then
    echo "refresh-structural-memory: failed to stop one or more mempalace writer processes" >&2
    return 1
  fi

  i=0
  while [ "$i" -lt 20 ]; do
    remaining="$(mempalace_writer_pids)"
    [ -z "$remaining" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done

  echo "refresh-structural-memory: mempalace writer still live after TERM:" >&2
  printf '%s\n' "$remaining" >&2
  return 1
}

ensure_mempalace_yaml() {
  local source="$1"
  local wing="$2"
  local config="$source/mempalace.yaml"

  [ -f "$config" ] && return 0

  cat > "$config" <<EOF
wing: "$wing"
rooms:
  - name: general
    description: Graphify structural report
    keywords:
      - graphify
      - structural
      - codebase
EOF
}

mine_line() {
  # Expected: MINE wing=<wing> source=<source> ...
  local line="$1"
  local wing
  local source

  wing="$(printf '%s\n' "$line" | sed -n 's/.*wing=\([^ ]*\).*/\1/p')"
  source="$(printf '%s\n' "$line" | sed -n 's/.*source=\([^ ]*\).*/\1/p')"

  if [ -z "$wing" ] || [ -z "$source" ]; then
    echo "FAIL mine-parse ($line)" >&2
    return 1
  fi

  if [ ! -d "$source" ]; then
    echo "FAIL mine-source-missing wing=$wing source=$source" >&2
    return 1
  fi

  if [ ! -x "$MP" ] && ! command -v "$MP" >/dev/null 2>&1; then
    echo "PENDING $line"
    echo "mempalace binary not found: $MP" >&2
    return 1
  fi

  ensure_mempalace_yaml "$source" "$wing" || return 1
  "$MP" mine "$source" --wing "$wing"
}

print_pending_commands() {
  local line
  local wing
  local source

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    wing="$(printf '%s\n' "$line" | sed -n 's/.*wing=\([^ ]*\).*/\1/p')"
    source="$(printf '%s\n' "$line" | sed -n 's/.*source=\([^ ]*\).*/\1/p')"

    if [ -n "$wing" ] && [ -n "$source" ]; then
      printf '%q mine %q --wing %q\n' "$MP" "$source" "$wing"
    else
      printf 'UNPARSED %s\n' "$line"
    fi
  done
}

write_last_reseed() {
  if ! date +%s > "$STATE/last-reseed"; then
    echo "refresh-structural-memory: failed to update $STATE/last-reseed" >&2
    return 1
  fi

  echo "Updated $STATE/last-reseed"
}

repos="$(discover_repos)"
if [ -z "$repos" ]; then
  echo "refresh-structural-memory: no git repos discovered" >&2
  exit 1
fi

normal_repos=""
large_repos=""
while IFS= read -r repo; do
  [ -n "$repo" ] || continue

  if is_large_repo "$repo"; then
    large_repos="${large_repos}${repo}
"
  else
    normal_repos="${normal_repos}${repo}
"
  fi
done <<EOF
$repos
EOF

echo "Discovered repos:"
printf '%s\n' "$repos" | sed 's/^/  /'

if [ "$INCLUDE_LARGE" -eq 0 ] && [ -n "$large_repos" ]; then
  echo "Large repos skipped by default:"
  printf '%s\n' "$large_repos" | sed '/^$/d; s/^/  /'
fi

if [ "$PRUNE_STALE" -eq 1 ]; then
  prune_stale_graphify_dirs "$(discover_graphify_dirs)" || exit 1
fi

sync_repos="$normal_repos"
if [ "$INCLUDE_LARGE" -eq 1 ]; then
  sync_repos="${sync_repos}${large_repos}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Would write $CONF with discovered repos."
  echo "Would sync repos:"
  printf '%s\n' "$sync_repos" | sed '/^$/d; s/^/  /'
  exit 0
fi

if ! mkdir -p "$(dirname "$CONF")" "$STATE"; then
  echo "refresh-structural-memory: failed to create state directories" >&2
  exit 1
fi

if [ -f "$CONF" ]; then
  cp "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
fi

if ! printf '%s\n' "$repos" > "$CONF"; then
  echo "refresh-structural-memory: failed to write $CONF" >&2
  exit 1
fi

if [ -z "$(printf '%s\n' "$sync_repos" | sed '/^$/d')" ]; then
  echo "No repos selected for sync."
  write_last_reseed
  exit "$?"
fi

if [ ! -x "$SYNC" ]; then
  if command -v graphify-sync.sh >/dev/null 2>&1; then
    SYNC="$(command -v graphify-sync.sh)"
  else
    echo "refresh-structural-memory: graphify-sync.sh not found" >&2
    exit 1
  fi
fi

set --
while IFS= read -r repo; do
  [ -n "$repo" ] && set -- "$@" "$repo"
done <<EOF
$sync_repos
EOF

tmp="$(mktemp)"
GRAPHIFY_LABEL_ATTEMPTS="$LABEL_ATTEMPTS" "$SYNC" "$@" | tee "$tmp"
sync_status=${PIPESTATUS[0]}

if [ "$sync_status" -ne 0 ]; then
  echo "refresh-structural-memory: graphify-sync failed with status $sync_status" >&2
  rm -f "$tmp"
  exit "$sync_status"
fi

mine_lines="$(grep '^MINE ' "$tmp" || true)"
fail_lines="$(grep '^FAIL ' "$tmp" || true)"
all_mine_lines="$(
  {
    [ -f "$PENDING" ] && cat "$PENDING"
    printf '%s\n' "$mine_lines"
  } | awk '
    NF {
      wing = ""
      source = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^wing=/) wing = substr($i, 6)
        if ($i ~ /^source=/) source = substr($i, 8)
      }
      key = wing SUBSEP source
      if (wing != "" && source != "" && !seen[key]++) print
    }
  '
)"

if [ -n "$fail_lines" ]; then
  echo "refresh-structural-memory: sync reported failures; not marking reseed complete" >&2
  printf '%s\n' "$fail_lines" >&2
  rm -f "$tmp"
  exit 1
fi

if [ -n "$all_mine_lines" ]; then
  if ! printf '%s\n' "$all_mine_lines" > "$PENDING"; then
    echo "refresh-structural-memory: failed to write $PENDING" >&2
    rm -f "$tmp"
    exit 1
  fi

  if mempalace_writer_live; then
    if [ "$STOP_LIVE_MEMPALACE" -eq 1 ]; then
      stop_mempalace_writers || { rm -f "$tmp"; exit 1; }
    else
      echo "refresh-structural-memory: mempalace MCP/CLI writer is live; refusing CLI mine." >&2
      echo "Pending MINE lines:"
      printf '%s\n' "$all_mine_lines"
      echo "Pending CLI mine commands:"
      print_pending_commands <<EOF
$all_mine_lines
EOF
      rm -f "$tmp"
      exit 1
    fi
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mine_line "$line" || { rm -f "$tmp"; exit 1; }
  done <<EOF
$all_mine_lines
EOF

  rm -f "$PENDING"
fi

write_last_reseed
rm -f "$tmp"
