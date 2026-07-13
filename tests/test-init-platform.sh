#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_SH="$ROOT/tools/codex/platform.sh"

detect() {
  env -i PATH="$PATH" HOME="$HOME" "$@" bash -c '
    source "$1"
    codex_detect_platform || exit $?
    printf "%s|%s|%s\n" "$PLATFORM_OS" "$IS_WSL" "$WSL_DISTRO"
  ' _ "$PLATFORM_SH"
}

expect() {
  local expected="$1"
  shift
  local actual
  actual="$(detect "$@")"
  [ "$actual" = "$expected" ] || {
    printf 'FAIL expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

expect 'Linux|0|' INIT_UNAME_S=Linux INIT_PROC_VERSION=Linux INIT_WSL_INTEROP=0
expect 'Darwin|0|' INIT_UNAME_S=Darwin INIT_PROC_VERSION=Darwin INIT_WSL_INTEROP=0
expect 'Linux|1|Ubuntu' INIT_UNAME_S=Linux INIT_PROC_VERSION=Linux \
  INIT_WSL_INTEROP=0 WSL_DISTRO_NAME=Ubuntu
expect 'Linux|1|' INIT_UNAME_S=Linux INIT_PROC_VERSION='Linux Microsoft WSL2' \
  INIT_WSL_INTEROP=0
expect 'Linux|1|archlinux' INIT_UNAME_S=Linux INIT_PROC_VERSION='Linux Microsoft WSL2' \
  INIT_WSL_INTEROP=0 CODEX_WSL_DISTRO=archlinux

for kernel in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0 FreeBSD; do
  if detect INIT_UNAME_S="$kernel" INIT_PROC_VERSION="$kernel" INIT_WSL_INTEROP=0 \
      >/dev/null 2>&1; then
    printf 'FAIL expected %s to be rejected\n' "$kernel" >&2
    exit 1
  fi
done

if output="$(INIT_UNAME_S=MINGW64_NT-10.0 INIT_PROC_VERSION=MINGW \
    INIT_WSL_INTEROP=0 "$ROOT/init.sh" 2>&1)"; then
  printf 'FAIL expected init.sh to reject native Windows shells\n' >&2
  exit 1
fi
case "$output" in
  *'native Windows shells are unsupported; run init.sh inside WSL'*) ;;
  *)
    printf 'FAIL init.sh returned the wrong native Windows guidance: %s\n' "$output" >&2
    exit 1
    ;;
esac

printf 'PASS init platform detection\n'
