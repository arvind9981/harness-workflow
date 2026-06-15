# Local-model claude-mem routing — design

**Date:** 2026-06-15

## Goal

Capture the local-model optimization into the portable `claude-workflow` repo so a
fresh machine reproduces it with `./init.sh`. The optimization routes claude-mem's
observation generation to a **local model with zero rate limits and zero cloud
cost**, via:

```
claude-mem  →  ANTHROPIC_BASE_URL=http://127.0.0.1:4000  →  LiteLLM gateway  →  Ollama (qwen3.6:latest, 23 GB) on :11434
```

Today this lives only in the running machine's config; the repo still describes a
headroom-only setup. This change makes it reproducible without shipping secrets or
the 23 GB model.

## Decisions

- **Automation scope:** `init.sh` installs only the portable bits it owns
  (litellm uv tool, proxy config, systemd unit, claude-mem `.env` patch). Ollama
  and the `qwen3.6:latest` model are **documented prerequisites**, not
  auto-installed — they are heavyweight (23 GB) and hardware-specific.
- **claude-mem wiring:** `init.sh` surgically upserts three keys into the existing
  `~/.claude-mem/.env`, backing it up first and leaving all other lines (including
  secret API keys) untouched. Skipped with a notice if claude-mem is absent.
- **Allowlist:** sanitize and sync `settings.local.json` — fold in the new generic
  `ollama`/`litellm`/`claude-mem` allows, drop machine-specific paths and any
  entry carrying a key string.
- **Secrets:** unchanged policy — nothing secret enters the repo. The proxy config
  and systemd unit are loopback-only / `%h`-based and carry no secrets.

## Layout (new + changed)

```
claude-workflow/
├── init.sh                          # + 4 steps (litellm tool, config, unit, .env patch)
├── README.md                        # + "Local-model claude-mem routing" section
├── claude/
│   └── settings.local.json          # sanitized re-sync (234 → sanitized superset)
├── tools/
│   ├── headroom/                    # (unchanged)
│   └── litellm/                     # NEW
│       ├── qwen-proxy.yaml          # LiteLLM proxy config (loopback-only, no secrets)
│       └── litellm-qwen.service     # systemd user unit (%h, portable)
└── docs/
    └── 2026-06-15-local-model-routing-design.md   # this file
```

## Components

### `tools/litellm/qwen-proxy.yaml`
Copied verbatim from `~/.config/litellm/qwen-proxy.yaml`, with one edit: the
header comment that references a machine-specific `hardware-strix-halo.md` note is
generalized. Content: a single `model_name: "*"` wildcard mapping to
`ollama_chat/qwen3.6:latest` at `http://127.0.0.1:11434`, with `think: false` and
`drop_params: true`. No secrets.

### `tools/litellm/litellm-qwen.service`
Copied verbatim. Uses `%h` for `ExecStart` paths so it is portable as-is.
`Restart=on-failure`, `WantedBy=default.target`. No secrets.

## init.sh — new steps

Inserted after the existing headroom steps, following the same
`step`/`backup`/`ok`/`warn` helpers and idempotent style.

1. **Install litellm (uv tool).** `uv tool install --upgrade 'litellm[proxy]'`.
   Mirrors the headroom install step. (Proxy extras are required for
   `litellm --config ... --port`.)
2. **Install proxy config.** `mkdir -p ~/.config/litellm`; backup any existing
   `qwen-proxy.yaml`; copy from repo. No `__HOME__` rendering (loopback-only).
3. **Install + enable systemd unit.** Backup existing unit; copy; `systemctl
   --user daemon-reload`; `systemctl --user enable --now litellm-qwen.service`.
   Then verify `curl -fsS --max-time 4 http://127.0.0.1:4000/health/readiness`;
   warn (don't fail) if not yet ready. Guarded by `command -v systemctl`, like the
   headroom service step.
4. **Patch claude-mem `.env`.** Only if `~/.claude-mem` exists (else info-notice
   and skip). Backup `~/.claude-mem/.env` (create if absent). Upsert exactly:
   - `ANTHROPIC_BASE_URL=http://127.0.0.1:4000`
   - `CLAUDE_MEM_PROVIDER=claude`
   - `CLAUDE_MEM_CLAUDE_AUTH_METHOD=gateway`

   Upsert = replace the line if the key exists, else append. Never touch any other
   line. Idempotent: a second run produces an identical file.
5. **Prerequisite gate (non-fatal).** Detect `command -v ollama` and
   `ollama list | grep -q 'qwen3.6'`. If either is missing, print: install Ollama,
   then `ollama pull qwen3.6:latest` (~23 GB), and note the service will start
   serving once the model is present. Continue regardless.

## settings.local.json — sanitize & sync

Regenerate the repo allowlist from the live file (`~/.claude/settings.local.json`,
currently 285 entries) under the same "sanitized generic" contract as the existing
234.

**Keep** (generic, reusable): `ollama run/show/ps *`, `claude-mem --help/--version`,
`command -v <tool>` checks, loopback health curls to local services (e.g.
`:4000/health/readiness`, `:37700/health`), and similar tool-level allows.

**Drop:**
- Version-pinned plugin-cache absolute paths
  (`.../plugins/cache/.../13.3.0/...`).
- `/tmp/*` and other ephemeral/project-specific paths.
- PID- or `$!`-specific commands.
- Any entry embedding an `x-api-key:`/token string (two known curl commands).

The keep/drop list is surfaced to the user before the file is rewritten. Final
file must contain no `/home/`, `/tmp/`, or `api-key`/`token` substrings.

## README updates

Add a "Local-model claude-mem routing" subsection:
- The chain diagram (claude-mem → LiteLLM :4000 → Ollama qwen3.6).
- **Prerequisites:** Ollama installed + `ollama pull qwen3.6:latest` (~23 GB),
  hardware-dependent.
- What `init.sh` wires automatically (litellm tool, proxy config, systemd unit,
  claude-mem `.env` patch).
- Adjust the existing headroom-centric framing to mention litellm alongside it.

## Verification

- **`.env` upsert idempotency:** run the patch twice against a fixture `.env` that
  contains decoy secret lines; assert (a) secrets untouched, (b) the three keys set
  correctly, (c) second run yields a byte-identical file.
- **Config/unit parity:** rendered/copied files match the live originals (modulo
  the generalized comment).
- **Allowlist hygiene:** `grep -E '/home/|/tmp/|api-key|token'` over the new
  `settings.local.json` returns nothing; `jq` count recorded.
- **Service health:** after `enable --now`, `:4000/health/readiness` returns 200 on
  a machine where the model is present; the absent-model path prints the prereq
  notice without failing the script.
- **Full dry-run:** execute `init.sh` against a temp `$HOME` to confirm no step
  hard-fails and backups are created.

## Out of scope (YAGNI)

- Auto-installing Ollama or pulling the 23 GB model.
- Vendoring model weights.
- Reading or migrating claude-mem secret keys.
- Codex bootstrap.
