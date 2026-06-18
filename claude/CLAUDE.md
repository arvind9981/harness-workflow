# Global instructions

Standing preferences across all projects. Project-level CLAUDE.md and explicit
requests in the moment take precedence over anything here.

## Scope & approval
- Do what's asked — no more. For anything **additive** (new tools, dependencies,
  features) or **hard to reverse** (deletes, overwrites, outward-facing actions),
  propose it and get explicit approval before implementing.
- When a request is ambiguous or could reasonably go several ways, ask one
  focused question before acting — don't guess at scope.
- **Never commit or push** unless I explicitly tell you to.
- Commit messages: write only the substantive message. **Never** add co-author,
  "Generated with", or any AI/tool attribution lines.

## Working style
- Be concise and decisive: give a recommendation, not an exhaustive survey.
- Once I've made a decision, don't re-litigate it or pile on caveats — move on.
- Lead with the answer; keep exploration to what the task needs.

## Verification
- Verify before claiming something works, passes, or is done — run the command
  and show the evidence. No success claims from assumption.
- Verify claims before relying on them — including your own earlier findings;
  don't treat a probe result or assumption as fact.

## Safety
- Never write secrets, tokens, API keys, or credentials into files, repos, or
  commits.
- Don't upload or transmit my code, files, or data to external/third-party
  services without asking. (Web research is fine.)

## Memory & tooling defaults
The local stack (claude-mem, headroom, LiteLLM-routed qwen) is installed to be
used — reach for the right tool without being asked:
- **Recall before re-deriving.** Before non-trivial work, or whenever I reference
  past work ("did we…", "how did we…", "the X fix", "last time"), run mem-search
  (search → timeline → get_observations) instead of reconstructing from scratch.
- A `UserPromptSubmit` hook surfaces candidate observations each turn. When those
  hits are relevant, fetch full detail with `get_observations([ids])` rather than
  re-investigating — but verify they still hold before relying on them.
- **Prefer the structural tools.** Use smart-explore (AST search) over reading
  whole files to understand code structure; use claude-mem knowledge-agent for
  synthesized answers across many observations.
- Save durable, non-obvious findings to memory as you go — don't wait to be told.
