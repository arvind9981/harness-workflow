# Codex Bootstrap

The Codex bootstrap mirrors the repo-maintained parts of the Claude workflow:

- `AGENTS.md` installs standing Codex instructions.
- `hooks.json` wires memory recall, graphify-first search nudges, graph refresh,
  session recap, and headroom initialization.
- `../tools/codex/install-codex.sh` copies the shared hook scripts into
  `~/.codex/hooks`, renders `__HOME__` placeholders, and upserts Codex shell
  environment values so `~/.local/bin` tools resolve inside Codex and both
  Anthropic/OpenAI-compatible traffic can route through headroom. Existing
  Supacode-managed hook entries are preserved when regenerating `hooks.json`.

Run it directly:

```bash
./tools/codex/install-codex.sh
```

Or run it as part of the full bootstrap:

```bash
./init.sh --codex
```
