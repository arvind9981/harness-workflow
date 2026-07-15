#!/usr/bin/env bash

# Print the Codex executable selected for this machine. PATH intentionally wins
# so shell-managed upgrades remain authoritative; CODEX_BIN is the explicit
# fallback for callers that know an installation path.
codex_resolve_bin() {
  local resolved candidate candidates old_ifs

  resolved="$(command -v codex 2>/dev/null || true)"
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  if [ -n "${CODEX_BIN:-}" ] && [ -x "$CODEX_BIN" ]; then
    printf '%s\n' "$CODEX_BIN"
    return 0
  fi

  candidates="${CODEX_APP_BUNDLE_PATHS:-/Applications/ChatGPT.app/Contents/Resources/codex:/Applications/Codex.app/Contents/Resources/codex}"
  old_ifs="$IFS"
  IFS=:
  for candidate in $candidates; do
    if [ -x "$candidate" ]; then
      IFS="$old_ifs"
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

# Find a Python interpreter with the standard-library TOML parser. Apple ships
# an older /usr/bin/python3 on some supported macOS versions, so continue through
# common Homebrew and uv-managed candidates instead of misreporting valid TOML.
codex_python_resolve() {
  local candidate resolved uv_candidate

  for candidate in "${CODEX_PYTHON_BIN:-}" "$(command -v python3 2>/dev/null || true)" \
    /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v uv >/dev/null 2>&1; then
    uv_candidate="$(uv python find '>=3.11' 2>/dev/null || true)"
    if [ -n "$uv_candidate" ] && [ -x "$uv_candidate" ] \
      && "$uv_candidate" -c 'import tomllib' >/dev/null 2>&1; then
      printf '%s\n' "$uv_candidate"
      return 0
    fi
  fi
  return 1
}
