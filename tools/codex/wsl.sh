#!/usr/bin/env bash
# Windows Codex App bridge helpers for callers running inside WSL.

detect_windows_codex_dir() {
  [ "$IS_WSL" = 1 ] || return 1

  if [ -n "${CODEX_WINDOWS_DIR:-}" ]; then
    printf '%s\n' "$CODEX_WINDOWS_DIR"
    return 0
  fi

  case "${CODEX_HOME:-}" in
    [A-Za-z]:\\*)
      command -v wslpath >/dev/null 2>&1 || return 1
      wslpath -u "$CODEX_HOME"
      return 0
      ;;
  esac

  local windows_home="" windows_mount="${CODEX_WINDOWS_MOUNT:-/mnt/c}"
  if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    if ! windows_home="$(cd "$windows_mount" 2>/dev/null \
        && cmd.exe /d /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | tail -n 1)"; then
      windows_home=""
    fi
    if [ -n "$windows_home" ]; then
      printf '%s/.codex\n' "$(wslpath -u "$windows_home")"
      return 0
    fi
  fi

  local candidates=() candidate
  if [ -d "$windows_mount/Users" ]; then
    while IFS= read -r candidate; do candidates+=("$(dirname "$candidate")"); done \
      < <(find "$windows_mount/Users" -mindepth 3 -maxdepth 3 -type f \
        -path '*/.codex/config.toml' 2>/dev/null)
  fi
  [ "${#candidates[@]}" -eq 1 ] || return 1
  printf '%s\n' "${candidates[0]}"
}

install_windows_codex_bridge() {
  local windows_codex_dir="$1" source_json="$REPO_DIR/codex/hooks.json"
  local linux_rendered windows_rendered dest agents_dest src rel skill_dest
  local config rendered_config
  linux_rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooks-linux.XXXXXX")"
  windows_rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooks-windows.XXXXXX")"
  dest="$windows_codex_dir/hooks.json"

  sed "s#__HOME__#$HOME#g" "$source_json" > "$linux_rendered"
  if ! jq --arg distro "$WSL_DISTRO" '
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(
            .command = ("wsl.exe -d " + ($distro | @json)
              + " --exec bash -lc " + (.command | @json))
          )
        )
      )
    ' "$linux_rendered" > "$windows_rendered"; then
    rm -f "$linux_rendered" "$windows_rendered"
    warn "could not render Windows Codex App hooks"
    return 1
  fi
  rm -f "$linux_rendered"

  mkdir -p "$windows_codex_dir"
  if [ -f "$dest" ] && cmp -s "$windows_rendered" "$dest"; then
    rm -f "$windows_rendered"
    ok "Windows Codex App hooks already bridged ($dest)"
  else
    backup "$dest"
    install -m 0644 "$windows_rendered" "$dest"
    rm -f "$windows_rendered"
    ok "Windows Codex App hooks -> $dest (WSL distro: $WSL_DISTRO)"
  fi

  agents_dest="$windows_codex_dir/AGENTS.md"
  if [ ! -f "$agents_dest" ] || ! cmp -s "$REPO_DIR/codex/AGENTS.md" "$agents_dest"; then
    backup "$agents_dest"
    install -m 0644 "$REPO_DIR/codex/AGENTS.md" "$agents_dest"
    ok "Windows Codex App AGENTS.md -> $agents_dest"
  else
    ok "Windows Codex App AGENTS.md already current"
  fi

  if [ -d "$REPO_DIR/workflow/skills" ]; then
    while IFS= read -r -d '' src; do
      rel="${src#"$REPO_DIR/workflow/skills/"}"
      skill_dest="$windows_codex_dir/skills/$rel"
      mkdir -p "$(dirname "$skill_dest")"
      if [ ! -f "$skill_dest" ] || ! cmp -s "$src" "$skill_dest"; then
        backup "$skill_dest"
        if [ -x "$src" ]; then install -m 0755 "$src" "$skill_dest"
        else install -m 0644 "$src" "$skill_dest"
        fi
      fi
    done < <(find "$REPO_DIR/workflow/skills" -type f -print0)
    ok "Windows Codex App workflow skills -> $windows_codex_dir/skills"
  fi

  config="$windows_codex_dir/config.toml"
  rendered_config="$(mktemp "${TMPDIR:-/tmp}/codex-windows-config.XXXXXX")"
  touch "$config"
  if ! python3 - "$config" "$rendered_config" "$WSL_DISTRO" \
      "$HOME/.local/bin/mempalace-mcp" "$HOME/.mempalace/palace" <<'PY'
import json
import sys
from pathlib import Path

source, output, distro, command, palace = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
lines = text.splitlines()
result = []
in_mempalace = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1]
        if section == "mcp_servers.mempalace":
            in_mempalace = True
            continue
        in_mempalace = False
    if not in_mempalace:
        result.append(line)

while result and not result[-1].strip():
    result.pop()
if result:
    result.append("")
result.extend([
    "[mcp_servers.mempalace]",
    'command = "wsl.exe"',
    "args = " + json.dumps([
        "-d", distro, "--exec", command, "--palace", palace,
    ]),
    "startup_timeout_sec = 120",
])
Path(output).write_text("\n".join(result) + "\n", encoding="utf-8")
PY
  then
    rm -f "$rendered_config"
    warn "could not configure the Windows Codex App Mempalace MCP"
    return 1
  fi
  if cmp -s "$rendered_config" "$config"; then
    rm -f "$rendered_config"
    ok "Windows Codex App Mempalace MCP already configured"
  else
    backup "$config"
    install -m 0644 "$rendered_config" "$config"
    rm -f "$rendered_config"
    ok "Windows Codex App Mempalace MCP registered through WSL"
  fi

  info "fully restart the Codex App so it reloads AGENTS.md, skills, hooks, and MCPs"
}
