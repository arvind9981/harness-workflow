// claude-workflow: managed OpenCode lifecycle adapter
//
// OpenCode loads this file automatically from ~/.config/opencode/plugins. The
// repository's shell helpers retain their existing guardrails; this adapter
// converts their Codex hook JSON into OpenCode system context.

const HOME = process.env.HOME ?? ""
const HOOK_DIR = `${HOME}/.config/opencode/workflow/hooks`
const RECAP_DIR = `${HOME}/.mempalace/recaps`
const started = new Set<string>()
const recalls = new Map<string, string>()
const prompts = new Map<string, string[]>()

const slug = (directory: string) => {
  const value = directory.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "")
  return value || "root"
}

const additionalContext = (raw: string) => {
  try {
    const parsed = JSON.parse(raw)
    return parsed?.hookSpecificOutput?.additionalContext ?? ""
  } catch {
    return ""
  }
}

const runHook = async (name: string, payload: Record<string, unknown>, cwd: string) => {
  const proc = Bun.spawn(["bash", `${HOOK_DIR}/${name}`], {
    cwd,
    stdin: new Blob([JSON.stringify(payload)]),
    stdout: "pipe",
    stderr: "ignore",
  })
  const output = await new Response(proc.stdout).text()
  await proc.exited
  return additionalContext(output)
}

const sessionRecap = async (directory: string) => {
  try {
    return await Bun.file(`${RECAP_DIR}/opencode-${slug(directory)}.json`).json()
  } catch {
    return undefined
  }
}

const writeRecap = async (directory: string, sessionID: string) => {
  const recent = prompts.get(sessionID) ?? []
  if (recent.length === 0) return
  await Bun.write(
    `${RECAP_DIR}/opencode-${slug(directory)}.json`,
    JSON.stringify({ epoch: Date.now() / 1000, session_id: sessionID, prompts: recent.slice(-5) }),
  )
}

export const WorkflowPlugin = async ({ directory }: { directory: string }) => ({
  "chat.message": async (
    input: { sessionID: string },
    output: { parts: Array<{ type: string; text?: string }> },
  ) => {
    const prompt = output.parts
      .filter((part) => part.type === "text" && typeof part.text === "string")
      .map((part) => part.text!.trim())
      .filter(Boolean)
      .join("\n")
    if (!prompt) return

    const history = prompts.get(input.sessionID) ?? []
    history.push(prompt.slice(0, 500))
    prompts.set(input.sessionID, history.slice(-8))

    const recall = await runHook("mempalace-recall.sh", { prompt }, directory)
    if (recall) recalls.set(input.sessionID, recall)
  },

  "experimental.chat.system.transform": async (
    input: { sessionID?: string },
    output: { system: string[] },
  ) => {
    const sessionID = input.sessionID ?? ""
    if (!started.has(sessionID)) {
      started.add(sessionID)
      const [memory, graph, recap] = await Promise.all([
        runHook("mempalace-context.sh", { cwd: directory, session_id: sessionID }, directory),
        runHook("graphify-reseed-session.sh", { cwd: directory, session_id: sessionID }, directory),
        sessionRecap(directory),
      ])
      if (memory) output.system.push(memory)
      if (graph) output.system.push(graph)
      if (Array.isArray(recap?.prompts) && recap.prompts.length > 0) {
        output.system.push(
          `Previous OpenCode session for ${slug(directory)}:\n` +
            recap.prompts.map((prompt: string) => `- ${prompt}`).join("\n"),
        )
      }
    }

    const recall = recalls.get(sessionID)
    if (recall) {
      recalls.delete(sessionID)
      output.system.push(recall)
    }
  },

  "tool.execute.after": async (input: { tool: string }) => {
    if (["edit", "write", "apply_patch"].includes(input.tool)) {
      await runHook("graphify-autoupdate.sh", { cwd: directory }, directory)
    }
  },

  event: async ({ event }: { event: { type: string; properties?: { sessionID?: string } } }) => {
    if (event.type === "session.idle" && event.properties?.sessionID) {
      await writeRecap(directory, event.properties.sessionID)
    }
  },
})
