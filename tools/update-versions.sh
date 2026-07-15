#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HARNESS_WORKFLOW_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYPI_BASE_URL="${PYPI_BASE_URL:-https://pypi.org/pypi}"
MODE="check"

usage() {
  cat <<'EOF'
Usage: tools/update-versions.sh [--check|--apply]

  --check  Report pinned and latest PyPI versions without changing files.
  --apply  Update synchronized pins in init.sh, README.md, and regression tests.

Environment:
  PYPI_BASE_URL          Registry base URL (default: https://pypi.org/pypi)
  HARNESS_WORKFLOW_ROOT  Repository root override for isolated testing
EOF
}

die() {
  printf 'update-versions: %s\n' "$1" >&2
  exit 1
}

case "${1:-}" in
  ""|--check) MODE="check" ;;
  --apply) MODE="apply" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

for command_name in curl jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
for required in init.sh README.md tools/codex/test-workflow.sh; do
  [ -f "$ROOT/$required" ] || die "required repository file not found: $ROOT/$required"
done

read_pin() {
  local name="$1" value
  value="$(sed -n "s/^${name}_VERSION=\"\${${name}_VERSION:-\\([^}]*\\)}\"$/\\1/p" "$ROOT/init.sh")"
  [ -n "$value" ] || die "cannot read ${name}_VERSION from $ROOT/init.sh"
  printf '%s' "$value"
}

fetch_latest() {
  local package="$1" value
  value="$(curl -fsSL "${PYPI_BASE_URL%/}/$package/json" \
    | jq -er '.info.version | select(type == "string" and length > 0)' 2>/dev/null)" \
    || die "cannot read latest $package version from ${PYPI_BASE_URL%/}/$package/json"
  case "$value" in
    *[!0-9A-Za-z.+_-]*|"") die "registry returned an unsafe $package version: $value" ;;
  esac
  printf '%s' "$value"
}

headroom_current="$(read_pin HEADROOM)"
mempalace_current="$(read_pin MEMPALACE)"
graphify_current="$(read_pin GRAPHIFY)"

# Read every registry value before allowing --apply to touch the repository.
headroom_latest="$(fetch_latest headroom-ai)"
mempalace_latest="$(fetch_latest mempalace)"
graphify_latest="$(fetch_latest graphifyy)"

report_version() {
  local package="$1" current="$2" latest="$3" status="current"
  [ "$current" = "$latest" ] || status="available"
  printf '%s current=%s latest=%s update=%s\n' "$package" "$current" "$latest" "$status"
}

report_version headroom-ai "$headroom_current" "$headroom_latest"
report_version mempalace "$mempalace_current" "$mempalace_latest"
report_version graphifyy "$graphify_current" "$graphify_latest"

[ "$MODE" = "apply" ] || exit 0

if [ "$headroom_current" = "$headroom_latest" ] \
    && [ "$mempalace_current" = "$mempalace_latest" ] \
    && [ "$graphify_current" = "$graphify_latest" ]; then
  printf 'All workflow tool pins are current.\n'
  exit 0
fi

python3 - "$ROOT" \
  "$headroom_current" "$headroom_latest" \
  "$mempalace_current" "$mempalace_latest" \
  "$graphify_current" "$graphify_latest" <<'PY'
from pathlib import Path
import os
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
versions = [
    ("HEADROOM", "Headroom", "init pins the default Headroom version", sys.argv[2], sys.argv[3]),
    ("MEMPALACE", "Mempalace", "init pins the default Mempalace version", sys.argv[4], sys.argv[5]),
    ("GRAPHIFY", "Graphify", "init pins the default Graphify version", sys.argv[6], sys.argv[7]),
]
paths = {
    "init": root / "init.sh",
    "readme": root / "README.md",
    "tests": root / "tools/codex/test-workflow.sh",
}
texts = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}

for variable, label, test_label, current, latest in versions:
    if current == latest:
        continue
    old_pin = variable + '_VERSION="${' + variable + '_VERSION:-' + current + '}"'
    new_pin = variable + '_VERSION="${' + variable + '_VERSION:-' + latest + '}"'
    replacements = {
        "init": (old_pin, new_pin),
        "readme": (f"| {label} | {current} |", f"| {label} | {latest} |"),
        "tests": (
            f'  assert_file_contains "$REPO_DIR/init.sh" \'{old_pin}\' \'{test_label}\'',
            f'  assert_file_contains "$REPO_DIR/init.sh" \'{new_pin}\' \'{test_label}\'',
        ),
    }
    for name, (old, new) in replacements.items():
        count = texts[name].count(old)
        if count != 1:
            raise SystemExit(
                f"update-versions: expected one {label} pin in {paths[name]}, found {count}"
            )
        texts[name] = texts[name].replace(old, new, 1)

# Validate every replacement before writing any destination. Each destination is
# then replaced atomically in its own directory while preserving its file mode.
for name, path in paths.items():
    original = path.read_text(encoding="utf-8")
    if texts[name] == original:
        continue
    mode = path.stat().st_mode
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(texts[name])
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

print("Updated init.sh, README.md, and tools/codex/test-workflow.sh.")
PY
