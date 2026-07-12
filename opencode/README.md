# OpenCode adapter

This is an optional, model-neutral companion to the Codex workflow. It installs
only the workflow-owned OpenCode files under `~/.config/opencode`:

- `/consult` — a read-only architecture and troubleshooting advisor.
- `consult` agent — the command's read-only execution mode.
- Shared skills — `consult`, `brainstorming`, and `karpathy-guidelines` are
  installed from the same repo source as Codex, including brainstorming's
  supporting scripts.
- `workflow` plugin — injects Mempalace project context at session start,
  prompt-specific recall on new messages, graph-refresh maintenance after edits,
  and a compact local session handoff when OpenCode becomes idle.
- `mempalace` and `headroom` MCPs — the same local memory and usage-monitoring
  services used by the workflow.

It leaves providers, models, credentials, and project configuration alone. The
installer adds the local Mempalace and Headroom MCPs through OpenCode's own CLI.

## Install

Install OpenCode itself, if needed:

```bash
npm install -g opencode-ai
```

Then install this adapter:

```bash
./tools/opencode/install-opencode.sh
./tools/opencode/doctor-workflow.sh
```

Restart OpenCode after the install. Status will show the workflow plugin and
both MCPs. Type `/consult <question>` in the command palette. The command may
inspect the project, but it cannot edit files or run shell commands.

The installer refuses to replace an existing non-workflow `consult` file. Move
or rename that file first if you want this adapter to own `/consult`.
