# Codex Bootstrap

The Codex bootstrap mirrors the repo-maintained parts of the Claude workflow:

- `AGENTS.md` installs standing Codex instructions.
- `hooks.json` wires memory recall, graphify-first search nudges, graph refresh,
  session recap, and headroom initialization.
- `../workflow/skills` installs the shared `$consult`, `$brainstorming`,
  `karpathy-guidelines`, and other on-demand workflow skills.
- `fast.config.toml` installs as the supported standalone
  `~/.codex/fast.config.toml` profile: `codex --profile fast`.
- `../tools/codex/install-codex.sh` copies the shared hook scripts into
  `~/.codex/hooks` and `~/.codex/skills`, renders `__HOME__` placeholders, and upserts Codex shell
  environment values so `~/.local/bin` tools resolve inside Codex and terminal
  checks see `TERM=xterm-256color`. It also sets Codex's native
  `openai_base_url` so OpenAI-compatible model traffic routes through headroom
  while leaving ChatGPT auth/backend routing untouched. Existing machine-owned
  plugins, credentials, MCP commands/profiles, project trust, command rules,
  `danger-full-access`, and shell inheritance remain unchanged. When an existing
  `[mcp_servers.MCP_DOCKER]` table is present, the installer keeps its configured
  profile, sets `startup_timeout_sec = 60`, and narrows the exposed catalog to the
  small dynamic-management surface containing `mcp-exec`. Other MCP servers
  remain unchanged.

Run it directly:

```bash
./tools/codex/install-codex.sh
```

Or run it as part of the full bootstrap:

```bash
./init.sh --codex
```

Without `--codex`, `init.sh` auto-detects Codex on `PATH` or in the ChatGPT/Codex
macOS app bundles and skips the step when absent. `--codex` uses the same
detection but makes absence an error.

## Fast sessions

Use `codex --profile fast` for short, self-contained work. It lowers reasoning effort
and skips automatic memory recall, recap, and Graphify maintenance. The normal
profile remains the default for multi-step repository work.
