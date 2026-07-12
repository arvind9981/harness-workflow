#!/usr/bin/env bash
# Install this repository's optional OpenCode workflow adapter.
#
# This leaves opencode.json, providers, credentials, and unrelated user files
# untouched. It installs the consult command/agent/skill, an OpenCode-native
# lifecycle plugin, and local copies of the shared helper scripts it runs.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.config/opencode}"
WORKFLOW_DIR="$OPENCODE_DIR/workflow"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARKER='claude-workflow: managed opencode'
CHANGED=0
INSTALL_MCPS="${OPENCODE_INSTALL_MCPS:-1}"

backup() {
  [ -e "$1" ] && cp -p "$1" "$1.bak-opencode-$STAMP"
  return 0
}

install_managed() {  # <src> <dest> <mode>
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 0
  fi
  if [ -e "$dest" ] && ! grep -Fq "$MARKER" "$dest"; then
    printf 'install-opencode: refusing to replace non-workflow file: %s\n' "$dest" >&2
    printf 'Move or rename it, then rerun the installer.\n' >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  backup "$dest"
  install -m "$mode" "$src" "$dest"
  CHANGED=$((CHANGED + 1))
}

install_managed "$REPO_DIR/opencode/agents/consult.md" \
  "$OPENCODE_DIR/agents/consult.md" 0644
install_managed "$REPO_DIR/opencode/commands/consult.md" \
  "$OPENCODE_DIR/commands/consult.md" 0644
install_managed "$REPO_DIR/opencode/plugins/workflow.ts" \
  "$OPENCODE_DIR/plugins/workflow.ts" 0644

# The lifecycle plugin executes these copies so OpenCode stays independent of
# ~/.codex and can be installed on a machine where Codex is absent. A marker
# prevents this workflow from adopting an unrelated local helper directory.
if [ -d "$WORKFLOW_DIR" ] && [ ! -f "$WORKFLOW_DIR/.claude-workflow-managed" ]; then
  printf 'install-opencode: refusing to replace unmanaged helper directory: %s\n' "$WORKFLOW_DIR" >&2
  exit 1
fi
mkdir -p "$WORKFLOW_DIR/hooks"
for src in "$REPO_DIR"/workflow/hooks/*.sh; do
  [ -e "$src" ] || continue
  dest="$WORKFLOW_DIR/hooks/$(basename "$src")"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    continue
  fi
  backup "$dest"
  install -m 0755 "$src" "$dest"
  CHANGED=$((CHANGED + 1))
done
printf 'claude-workflow managed OpenCode helpers\n' > "$WORKFLOW_DIR/.claude-workflow-managed"

# Copy the neutral skill source after the managed-directory marker is present.
# This retains bundled scripts and lets future installs update only this
# workflow's own skill names, leaving unrelated OpenCode skills alone.
while IFS= read -r -d '' src; do
  rel="${src#"$REPO_DIR/workflow/skills/"}"
  dest="$OPENCODE_DIR/skills/$rel"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  backup "$dest"
  mode=0644
  [ -x "$src" ] && mode=0755
  install -m "$mode" "$src" "$dest"
  CHANGED=$((CHANGED + 1))
done < <(find "$REPO_DIR/workflow/skills" -type f -print0)

ensure_mcp() {  # <name> <command> [arg...]
  local name="$1"
  shift
  local list
  list="$(opencode mcp list 2>/dev/null || true)"
  if printf '%s' "$list" | grep -q "$name"; then
    return 0
  fi
  opencode mcp add "$name" -- "$@"
}

# Use OpenCode's own config writer rather than editing opencode.jsonc ourselves.
# A custom OPENCODE_DIR is used for isolated tests, so it never changes the
# caller's actual global OpenCode config.
if [ "$INSTALL_MCPS" = 1 ] && [ "$OPENCODE_DIR" = "$HOME/.config/opencode" ]; then
  if command -v opencode >/dev/null 2>&1 && command -v mempalace-mcp >/dev/null 2>&1; then
    ensure_mcp mempalace mempalace-mcp
  else
    printf 'install-opencode: Mempalace MCP skipped (opencode or mempalace-mcp unavailable)\n' >&2
  fi
  if command -v opencode >/dev/null 2>&1 && command -v headroom >/dev/null 2>&1; then
    ensure_mcp headroom headroom mcp serve
  else
    printf 'install-opencode: Headroom MCP skipped (opencode or headroom unavailable)\n' >&2
  fi
fi

printf 'OpenCode workflow installed into %s (%s file(s) updated)\n' "$OPENCODE_DIR" "$CHANGED"
