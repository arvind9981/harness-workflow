#!/usr/bin/env bash
# Shared launchd/systemd helpers. The caller provides install/backup and log helpers.

codex_systemd_user_ready() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1
}

codex_service_manager() {
  case "$1" in
    Darwin)
      if command -v launchctl >/dev/null 2>&1; then printf 'launchd\n'; else printf 'none\n'; fi
      ;;
    Linux)
      if codex_systemd_user_ready; then printf 'systemd\n'; else printf 'none\n'; fi
      ;;
    *) printf 'none\n' ;;
  esac
}

codex_enable_service() {
  local manager="$1" linux_unit="$2" mac_plist="$3"
  local dest rendered unit changed=0

  case "$manager" in
    launchd)
      mkdir -p "$LAUNCH_DIR" "$HOME/Library/Logs"
      dest="$LAUNCH_DIR/$(basename "$mac_plist")"
      rendered="$(mktemp)"
      sed "s#__HOME__#$HOME#g" "$mac_plist" > "$rendered"
      if replace_if_changed "$rendered" "$dest"; then
        launchctl unload "$dest" >/dev/null 2>&1 || true
        if launchctl load -w "$dest"; then
          ok "$(basename "$dest") loaded (launchd)"
        else
          warn "launchctl could not load $(basename "$dest")"
          return 1
        fi
      elif launchctl list "$(basename "$dest" .plist)" >/dev/null 2>&1 \
          || launchctl load -w "$dest"; then
        ok "$(basename "$dest") already current and loaded (launchd)"
      else
        warn "launchctl could not load $(basename "$dest")"
        return 1
      fi
      ;;
    systemd)
      mkdir -p "$UNIT_DIR"
      unit="$(basename "$linux_unit")"
      if install_if_changed "$linux_unit" "$UNIT_DIR/$unit" 0644; then
        changed=1
        systemctl --user daemon-reload || return 1
      fi
      if systemctl --user is-active --quiet "$unit"; then
        if [ "$changed" -eq 1 ]; then
          if systemctl --user restart "$unit"; then
            ok "$unit updated and restarted (systemd)"
          else
            warn "systemctl could not restart $unit"
            return 1
          fi
        else
          ok "$unit already current and active (systemd)"
        fi
      elif systemctl --user enable --now "$unit"; then
        ok "$unit enabled and started (systemd)"
      else
        warn "systemctl could not enable $unit"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

codex_enable_timer() {
  local manager="$1" success="$2" service_file="$3" timer_file="$4" mac_plist="$5"
  local dest rendered changed=0 file timer label

  case "$manager" in
    launchd)
      mkdir -p "$LAUNCH_DIR"
      dest="$LAUNCH_DIR/$(basename "$mac_plist")"
      label="$(basename "$dest" .plist)"
      rendered="$(mktemp)"
      sed "s#__HOME__#$HOME#g" "$mac_plist" > "$rendered"
      if replace_if_changed "$rendered" "$dest"; then
        launchctl unload "$dest" >/dev/null 2>&1 || true
      fi
      if launchctl list "$label" >/dev/null 2>&1 || launchctl load -w "$dest"; then
        ok "$success"
      else
        warn "could not load $(basename "$dest")"
        return 1
      fi
      ;;
    systemd)
      mkdir -p "$UNIT_DIR"
      for file in "$service_file" "$timer_file"; do
        if install_if_changed "$file" "$UNIT_DIR/$(basename "$file")" 0644; then changed=1; fi
      done
      if [ "$changed" -eq 1 ]; then systemctl --user daemon-reload || return 1; fi
      timer="$(basename "$timer_file")"
      if systemctl --user enable --now "$timer"; then
        ok "$success"
      else
        warn "could not enable $timer"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}
