# Codex Bootstrap

The Codex bootstrap mirrors the repo-maintained parts of the Claude workflow:

- `AGENTS.md` installs standing Codex instructions.
- `hooks.json` wires memory recall, graphify-first search nudges, graph refresh,
  session recap, and headroom initialization.
- `../tools/codex/install-codex.sh` copies the shared hook scripts into
  `~/.codex/hooks`, renders `__HOME__` placeholders, and upserts Codex shell
  environment values so `~/.local/bin` tools resolve inside Codex and terminal
  checks see `TERM=xterm-256color`. It also sets Codex's native
  `openai_base_url` so OpenAI-compatible model traffic routes through headroom
  while leaving ChatGPT auth/backend routing untouched. Existing Supacode-managed
  hook entries are preserved when regenerating `hooks.json`.

Run it directly:

```bash
./tools/codex/install-codex.sh
```

Or run it as part of the full bootstrap:

```bash
./init.sh --codex
```
