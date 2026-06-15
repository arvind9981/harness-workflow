# claude-workflow — design

**Date:** 2026-06-15

## Goal

A git repo that reproduces my Claude Code workflow on any new machine with one
command: `git clone` → `./init.sh` → log in. No tokens travel with the repo.

## Decisions

- **Scope:** Claude only now; `codex/` left as a stub for later.
- **Knowledge:** tooling only — no memory files or claude-mem DB (they rebuild).
- **Permissions:** include `settings.local.json` but sanitized of absolute local
  paths (dropped 3 of 237 entries → 234 generic allows).
- **Secrets:** excluded by design; `.gitignore` defensively blocks
  credentials/tokens/keys.

## Key insight

`~/.claude/settings.json` already declares all marketplaces
(`extraKnownMarketplaces`) and `enabledPlugins`. Claude Code auto-installs them
on first launch, so the init script does **not** vendor or clone plugins.

## Layout

```
claude-workflow/
├── README.md
├── init.sh                       # idempotent installer, backs up before overwrite
├── .gitignore                    # blocks secrets + *.bak-init-*
├── claude/
│   ├── settings.json             # __HOME__ placeholder, rendered on install
│   └── settings.local.json       # sanitized allowlist (234)
├── tools/headroom/
│   ├── headroom-watch            # live compression stats script
│   └── headroom-proxy.service    # systemd user unit (uses %h, portable)
├── codex/README.md               # stub
└── docs/                         # this file
```

## init.sh steps

1. Prereq check (`git`/`curl`/`jq`/`systemctl`); offer to install `uv` if absent.
2. `uv tool install --upgrade headroom-ai`.
3. Install `headroom-watch` to `~/.local/bin`.
4. Render `__HOME__` → `$HOME` into `~/.claude/settings.json`; copy sanitized
   `settings.local.json`. Both backed up first.
5. Install + `enable --now` the headroom systemd user service.
6. Verify `/health`; print next steps (start `claude`, log in).

## Verification

`init.sh` run on the origin machine: since `$HOME` resolves identically and
files are backed up, the live config is unchanged — proving render parity and
idempotency.
