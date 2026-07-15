// harness-workflow: managed opencode lifecycle adapter

import { chmod, mkdir, writeFile } from "node:fs/promises"

const HOME = process.env.HOME ?? ""
const CONFIG_DIR = process.env.OPENCODE_CONFIG_DIR ?? `${HOME}/.config/opencode`
const HOOK_DIR = `${CONFIG_DIR}/harness-workflow/hooks`
const RECAP_DIR = `${HOME}/.mempalace/recaps`
const PRIMARY_AGENTS = new Set(["build", "plan"])
const started = new Set()
const sessionAgents = new Map()
const recalls = new Map()
const prompts = new Map()

const slug = (directory) =>
  directory.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "") || "root"

const primary = (sessionID) => PRIMARY_AGENTS.has(sessionAgents.get(sessionID) ?? "")

const additionalContext = (raw) => {
  try {
    return JSON.parse(raw)?.hookSpecificOutput?.additionalContext ?? ""
  } catch {
    return ""
  }
}

const runHook = async (name, payload, cwd) => {
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

const sessionRecap = async (directory) => {
  try {
    return await Bun.file(`${RECAP_DIR}/opencode-${slug(directory)}.json`).json()
  } catch {
    return undefined
  }
}

const writeRecap = async (directory, sessionID) => {
  const recent = prompts.get(sessionID) ?? []
  if (recent.length === 0) return
  const path = `${RECAP_DIR}/opencode-${slug(directory)}.json`
  await mkdir(RECAP_DIR, { recursive: true, mode: 0o700 })
  await chmod(RECAP_DIR, 0o700)
  await writeFile(
    path,
    JSON.stringify({ epoch: Date.now() / 1000, session_id: sessionID, prompts: recent.slice(-5) }),
    { encoding: "utf8", mode: 0o600 },
  )
  await chmod(path, 0o600)
}

export const WorkflowPlugin = async ({ directory }) => ({
  "chat.message": async (
    input,
    output,
  ) => {
    if (input.agent) sessionAgents.set(input.sessionID, input.agent)
    if (!primary(input.sessionID)) return

    const prompt = output.parts
      .filter((part) => part.type === "text" && typeof part.text === "string")
      .map((part) => part.text.trim())
      .filter(Boolean)
      .join("\n")
    if (!prompt) return

    const history = prompts.get(input.sessionID) ?? []
    history.push(prompt.slice(0, 500))
    prompts.set(input.sessionID, history.slice(-8))
    const recall = await runHook("mempalace-recall.sh", { prompt }, directory)
    if (recall) recalls.set(input.sessionID, recall)
  },

  "chat.params": async (input) => {
    sessionAgents.set(input.sessionID, input.agent)
  },

  "experimental.chat.system.transform": async (
    input,
    output,
  ) => {
    const sessionID = input.sessionID ?? ""
    if (!sessionID || !primary(sessionID)) return
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
            recap.prompts.map((prompt) => `- ${prompt}`).join("\n"),
        )
      }
    }

    const recall = recalls.get(sessionID)
    if (recall) {
      recalls.delete(sessionID)
      output.system.push(recall)
    }
  },

  "tool.execute.after": async (input) => {
    if (primary(input.sessionID) && ["edit", "write", "apply_patch"].includes(input.tool)) {
      await runHook("graphify-autoupdate.sh", { cwd: directory }, directory)
    }
  },

  event: async ({ event }) => {
    const sessionID = event.properties?.sessionID ?? ""
    if (event.type === "session.idle" && sessionID) {
      try {
        if (primary(sessionID)) await writeRecap(directory, sessionID)
      } finally {
        started.delete(sessionID)
        sessionAgents.delete(sessionID)
        recalls.delete(sessionID)
        prompts.delete(sessionID)
      }
    }
  },
})
