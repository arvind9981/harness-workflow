# macOS compatibility for the portable setup — design

2026-06-16

## Goal

`./init.sh` runs cleanly on both Linux and macOS from a single script, with full
service parity (auto-start on login, auto-restart on crash). No behavior change on
Linux.

## What is Linux-specific today

- **systemd user services** — `headroom-proxy.service` and `litellm-qwen.service`
  installed to `~/.config/systemd/user`, managed with `systemctl --user`, plus the
  `loginctl enable-linger` tip. macOS has no systemd.
- **`sed -i "expr"`** in `upsert_env` — GNU syntax. BSD/macOS `sed` requires
  `sed -i '' "expr"`.
- A few Linux-only hints in status/restart messages.

Everything else — `uv` install, `headroom-ai`/`litellm` install, `settings.json`
(`__HOME__` rendering), `CLAUDE.md`, Ollama detection, the claude-mem `.env`
wiring, and the `curl` health checks — is already cross-platform.

## Decisions

- **One cross-platform `init.sh`** that detects the OS with `uname -s` and branches
  the platform-specific bits behind small helpers. One script, both OSes in sync.
- **launchd LaunchAgents on macOS** for the two background services — native,
  auto-start on login, auto-restart on crash; full parity with the systemd setup.

## Design

### OS detection + paths

```bash
OS="$(uname -s)"                          # Linux | Darwin
UNIT_DIR="$HOME/.config/systemd/user"     # systemd (Linux)
LAUNCH_DIR="$HOME/Library/LaunchAgents"   # launchd (macOS)
```

App-defined paths (`~/.local/bin`, `~/.config/litellm`, `~/.claude`,
`~/.claude-mem`) are identical on both — `uv`, Ollama, and the apps use the same
locations on macOS.

### `sed -i` portability

A `sed_inplace` helper routes to the right syntax; `upsert_env` calls it.

```bash
sed_inplace() {  # GNU: sed -i 'expr' f  |  BSD/macOS: sed -i '' 'expr' f
  if [ "$OS" = "Darwin" ]; then sed -i '' "$1" "$2"; else sed -i "$1" "$2"; fi
}
```

### Service abstraction

The two inline systemd blocks collapse into one helper called twice:

```bash
svc_enable <linux_unit_file> <mac_plist_file>
```

- **Linux:** `cp` the `.service` to `~/.config/systemd/user/`, `daemon-reload`,
  `enable --now` (unchanged behavior).
- **macOS:** render `__HOME__` → `$HOME` in the `.plist` (launchd has no `%h`
  specifier, so we reuse the `settings.json` rendering trick), write to
  `~/Library/LaunchAgents/`, `launchctl unload` (ignore errors), `launchctl load -w`.

### New vendored plist files

- `tools/headroom/com.user.headroom-proxy.plist`
- `tools/litellm/com.user.litellm-qwen.plist`

Each declares `ProgramArguments` (absolute `__HOME__/.local/bin/...` path),
`RunAtLoad=true`, `KeepAlive → SuccessfulExit=false` (= systemd
`Restart=on-failure`), `ThrottleInterval=3` (= `RestartSec=3`), an
`EnvironmentVariables.PATH` covering `~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin` (launchd does not inherit the shell PATH), and logs to
`~/Library/Logs/<name>.log`.

### Per-OS message tweaks (cosmetic)

- Prereq check probes `launchctl` on macOS instead of `systemctl`.
- Missing-dependency death suggests `brew install …` on macOS.
- The `loginctl enable-linger` tip is Linux-only.
- Status / restart hints branch: `systemctl --user status|restart …` vs
  `launchctl list | grep …` / `launchctl kickstart -k gui/$(id -u)/…`.

## Files touched

- `init.sh` — edited (OS layer, `sed_inplace`, `svc_enable`, message branches).
- `tools/headroom/com.user.headroom-proxy.plist` — new.
- `tools/litellm/com.user.litellm-qwen.plist` — new.
- `README.md` — Requirements + service bullets note launchd/Homebrew on macOS.
- Linux `.service` files — unchanged.

## Out of scope

- Homebrew-based auto-install of `jq` (just detected + instructed, matching the
  existing "install via your package manager" stance).
- `codex/` bootstrap (still a placeholder).
