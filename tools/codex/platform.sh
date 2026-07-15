#!/usr/bin/env bash
# Shared platform detection for init.sh. Tests may override the probes with
# INIT_UNAME_S, INIT_PROC_VERSION, and INIT_WSL_INTEROP.
# shellcheck disable=SC2034 # Detection results are exported to scripts that source this file.

codex_detect_platform() {
  local kernel proc_version interop
  kernel="${INIT_UNAME_S:-$(uname -s)}"
  proc_version="${INIT_PROC_VERSION:-}"
  interop="${INIT_WSL_INTEROP:-}"

  if [ -z "$proc_version" ] && [ -r /proc/version ]; then
    proc_version="$(cat /proc/version 2>/dev/null || true)"
  fi
  if [ -z "$interop" ]; then
    if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then interop=1
    else interop=0
    fi
  fi

  PLATFORM_KERNEL="$kernel"
  PLATFORM_OS=""
  IS_WSL=0
  WSL_DISTRO=""
  PLATFORM_ERROR=""

  case "$kernel" in
    Linux)
      PLATFORM_OS="Linux"
      if [ -n "${WSL_DISTRO_NAME:-}" ] || [ "$interop" = 1 ] \
          || printf '%s' "$proc_version" | grep -qi microsoft; then
        IS_WSL=1
        WSL_DISTRO="${CODEX_WSL_DISTRO:-${WSL_DISTRO_NAME:-}}"
      fi
      ;;
    Darwin)
      PLATFORM_OS="Darwin"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      PLATFORM_ERROR="native Windows shells are unsupported; run init.sh inside WSL"
      return 1
      ;;
    *)
      PLATFORM_ERROR="unsupported operating system: $kernel"
      return 1
      ;;
  esac
}
