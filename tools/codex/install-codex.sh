#!/usr/bin/env bash
# Install the workflow's shared hooks and Codex instructions into Codex.
#
# This intentionally avoids plugin marketplace setup. Codex owns its plugin
# catalog in ~/.codex/config.toml; this script only wires the workflow pieces
# that this repo maintains: hooks, AGENTS.md, and shell env required by hooks.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CODEX_INSTALL_OS="${CODEX_INSTALL_OS:-$(uname -s)}"
STAMP="$(date +%Y%m%d-%H%M%S)"

backup() {
  [ -e "$1" ] && cp -p "$1" "$1.bak-codex-$STAMP"
  return 0
}

CHANGED=0
# Install src -> dest only when the content differs (backup-first). Skipping identical
# writes keeps file mtimes/hashes stable, so an unchanged redeploy does NOT re-trigger
# Codex's per-hook trust review. A genuine hook change still writes (and rightly needs
# re-trust). cmp -s is portable to BSD/macOS.
install_if_changed() {  # <src> <dest> <mode>
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 0
  fi
  backup "$dest"
  install -m "$mode" "$src" "$dest"
  CHANGED=$((CHANGED + 1))
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'install-codex: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require python3
require sed

mkdir -p "$CODEX_DIR/hooks" "$CODEX_DIR/skills"

for hook in "$REPO_DIR"/workflow/hooks/*.sh; do
  [ -e "$hook" ] || continue
  install_if_changed "$hook" "$CODEX_DIR/hooks/$(basename "$hook")" 0755
done

# Install shared workflow skills without touching unrelated personal skills.
if [ -d "$REPO_DIR/workflow/skills" ]; then
  while IFS= read -r -d '' src; do
    rel="${src#"$REPO_DIR/workflow/skills/"}"
    dest="$CODEX_DIR/skills/$rel"
    mkdir -p "$(dirname "$dest")"
    mode=0644
    [ -x "$src" ] && mode=0755
    install_if_changed "$src" "$dest" "$mode"
  done < <(find "$REPO_DIR/workflow/skills" -type f -print0)
fi

# Older Codex builds do not register ~/.codex/commands. Remove only the
# obsolete command this workflow previously installed; leave user files alone.
rm -f "$CODEX_DIR/commands/consult.md"

# Render __HOME__ first, then write hooks.json only if the result differs.
rendered="$(mktemp "${TMPDIR:-/tmp}/codex-hooksjson.XXXXXX")"
sed "s#__HOME__#$HOME#g" "$REPO_DIR/codex/hooks.json" > "$rendered"
install_if_changed "$rendered" "$CODEX_DIR/hooks.json" 0644
rm -f "$rendered"

install_if_changed "$REPO_DIR/codex/AGENTS.md" "$CODEX_DIR/AGENTS.md" 0644
mkdir -p "$CODEX_DIR/references"
install_if_changed "$REPO_DIR/codex/references/memory-tooling.md" "$CODEX_DIR/references/memory-tooling.md" 0644
install_if_changed "$REPO_DIR/codex/fast.config.toml" "$CODEX_DIR/fast.config.toml" 0644

config="$CODEX_DIR/config.toml"
if [ ! -e "$config" ]; then
  (umask 077 && : > "$config")
fi

CODEX_BIN_DIR="$BIN_DIR" CODEX_EXISTING_PATH="${PATH:-}" CODEX_BACKUP_SUFFIX=".bak-codex-$STAMP" python3 - "$config" <<'PY'
import os
import json
import re
import shutil
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

try:
    parsed_config = tomllib.loads(text)
except tomllib.TOMLDecodeError as exc:
    raise SystemExit(f"install-codex: invalid TOML in {path}: {exc}")

docker_config = parsed_config.get("mcp_servers", {}).get("MCP_DOCKER", {})
docker_args = docker_config.get("args")
normalized_mcp_args = None
if (
    docker_config.get("command") == "docker"
    and isinstance(docker_args, list)
    and docker_args[:3] == ["mcp", "gateway", "run"]
):
    normalized_mcp_args = []
    index = 0
    while index < len(docker_args):
        arg = docker_args[index]
        if arg == "--tools":
            index += 2
            continue
        if isinstance(arg, str) and arg.startswith("--tools="):
            index += 1
            continue
        normalized_mcp_args.append(arg)
        index += 1
    normalized_mcp_args.extend(["--tools", "mcp-exec"])

bin_dir = os.environ["CODEX_BIN_DIR"]
existing = os.environ.get("CODEX_EXISTING_PATH", "")
parts = [bin_dir] + [p for p in existing.split(":") if p and p != bin_dir]
codex_path = ":".join(parts)

desired = {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
    "OPENAI_BASE_URL": "http://127.0.0.1:8787/v1",
    "PATH": codex_path,
    "TERM": "xterm-256color",
}
desired_top = {
    "openai_base_url": "http://127.0.0.1:8787/v1",
}

def section_of(line: str):
    s = line.strip()
    match = re.match(r"^\[([^]]+)\](?:\s*#.*)?$", s)
    if match:
        return match.group(1)
    return None

out: list[str] = []
section = ""
seen_policy = False
seen_set = False
inserted = False
inserted_top = False
mcp_section = "mcp_servers.MCP_DOCKER"
seen_mcp = False
inserted_mcp_timeout = False
inserted_mcp_args = False

def emit_desired(target: list[str]) -> None:
    for key, value in desired.items():
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        target.append(f'{key} = "{escaped}"')

def emit_desired_top(target: list[str]) -> None:
    for key, value in desired_top.items():
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        target.append(f'{key} = "{escaped}"')

i = 0
while i < len(lines):
    line = lines[i]
    next_section = section_of(line)
    if next_section is not None:
      if section == mcp_section and not inserted_mcp_timeout:
          out.append("startup_timeout_sec = 60")
          inserted_mcp_timeout = True
      if section == "" and not inserted_top:
          emit_desired_top(out)
          inserted_top = True
      if section == "shell_environment_policy.set" and not inserted:
          while out and not out[-1].strip():
              out.pop()
          emit_desired(out)
          out.append("")
          inserted = True
      section = next_section
      seen_mcp = seen_mcp or section == mcp_section
      seen_policy = seen_policy or section == "shell_environment_policy"
      seen_set = seen_set or section == "shell_environment_policy.set"
      out.append(line)
      i += 1
      continue

    if section == "":
        stripped = line.lstrip()
        if any(stripped.startswith(f"{key} ") or stripped.startswith(f"{key}=") for key in desired_top):
            i += 1
            continue

    if section == "shell_environment_policy.set":
        stripped = line.lstrip()
        if any(stripped.startswith(f"{key} ") or stripped.startswith(f"{key}=") for key in desired):
            i += 1
            continue

    if section == mcp_section:
        stripped = line.lstrip()
        if normalized_mcp_args is not None and re.match(r"^args\s*=", stripped):
            if not inserted_mcp_args:
                out.append(f"args = {json.dumps(normalized_mcp_args)}")
                inserted_mcp_args = True
            i += 1
            continue
        if re.match(r"^startup_timeout_sec\s*=", stripped):
            if not inserted_mcp_timeout:
                out.append("startup_timeout_sec = 60")
                inserted_mcp_timeout = True
            i += 1
            continue

    out.append(line)
    i += 1

if section == "" and not inserted_top:
    emit_desired_top(out)
    inserted_top = True

if section == "shell_environment_policy.set" and not inserted:
    while out and not out[-1].strip():
        out.pop()
    emit_desired(out)
    inserted = True

if section == mcp_section and not inserted_mcp_timeout:
    out.append("startup_timeout_sec = 60")
    inserted_mcp_timeout = True

if not seen_policy:
    if out and out[-1].strip():
        out.append("")
    out.extend(["[shell_environment_policy]", 'inherit = "all"'])

if not seen_set:
    if out and out[-1].strip():
        out.append("")
    out.append("[shell_environment_policy.set]")
    emit_desired(out)

new_text = "\n".join(out).rstrip() + "\n"
if new_text != text:
    suffix = os.environ.get("CODEX_BACKUP_SUFFIX", "")
    if suffix and text:
        shutil.copy2(path, Path(str(path) + suffix))
    path.write_text(new_text, encoding="utf-8")

if not seen_mcp:
    print("install-codex: MCP_DOCKER table not found; startup timeout left unmanaged", file=sys.stderr)
PY

if [ "$CODEX_INSTALL_OS" = Darwin ]; then
  rendered_zshrc="$(mktemp "${TMPDIR:-/tmp}/codex-zshrc.XXXXXX")"
  python3 - "$HOME/.zshrc" "$REPO_DIR/codex/zshrc-probe.macos" "$rendered_zshrc" <<'PY'
from pathlib import Path
import re
import sys

destination, managed_path, output = map(Path, sys.argv[1:])
current = destination.read_text(encoding="utf-8") if destination.exists() else ""
managed = managed_path.read_text(encoding="utf-8").strip()
block = re.compile(
    r"^# BEGIN HARNESS CODEX SHELL PROBE$.*?"
    r"^# END HARNESS CODEX SHELL PROBE$",
    re.MULTILINE | re.DOTALL,
)

if block.search(current):
    updated = block.sub(managed, current, count=1)
else:
    updated = managed + ("\n\n" + current if current else "\n")

output.write_text(updated, encoding="utf-8")
PY
  install_if_changed "$rendered_zshrc" "$HOME/.zshrc" 0644
  rm -f "$rendered_zshrc"

  CODEX_ENV_BACKUP_SUFFIX=".bak-codex-$STAMP" python3 - \
    "$REPO_DIR/codex/codex.env.macos" "$CODEX_DIR/.env" <<'PY'
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

template, destination = map(Path, sys.argv[1:])
desired = template.read_text(encoding="utf-8").strip()
current = destination.read_text(encoding="utf-8") if destination.exists() else ""
pattern = re.compile(r"^\s*(?:export\s+)?PATH\s*=.*$")
lines = current.splitlines()
out = []
inserted = False

for line in lines:
    if pattern.match(line):
        if not inserted:
            out.append(desired)
            inserted = True
        continue
    out.append(line)

if not inserted:
    out.append(desired)

updated = "\n".join(out).rstrip() + "\n"
if updated != current:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.copy2(destination, Path(str(destination) + os.environ["CODEX_ENV_BACKUP_SUFFIX"]))
    fd, temporary = tempfile.mkstemp(prefix=".env.", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(updated)
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
else:
    os.chmod(destination, 0o600)
PY
fi

printf 'Codex workflow installed into %s (%s hook/instruction file(s) updated)\n' "$CODEX_DIR" "$CHANGED"

# The model-team helper owns only Codex agent profiles, the bounded Claude MCP
# entry, and cleanup of the retired Claude-led bridge. Keeping it behind the
# Codex installer makes direct and full-bootstrap installs behave identically.
if [ "${CODEX_INSTALL_MODEL_TEAM:-1}" = 1 ]; then
  CODEX_DIR="$CODEX_DIR" BIN_DIR="$BIN_DIR" \
    bash "$REPO_DIR/tools/model-team/install-model-team.sh"
fi
