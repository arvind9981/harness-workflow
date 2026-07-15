#!/usr/bin/env node

import assert from "node:assert/strict"
import { mkdtemp, readFile, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const pluginPath = process.argv[2]
if (!pluginPath) throw new Error("usage: test-plugin.mjs <workflow.ts>")
const home = await mkdtemp(join(tmpdir(), "opencode-workflow-plugin-"))
process.env.HOME = home

const hookContext = {
  "mempalace-context.sh": "MEMORY_CONTEXT",
  "mempalace-recall.sh": "MEMORY_RECALL",
  "graphify-reseed-session.sh": "GRAPH_RESEED",
  "graphify-autoupdate.sh": "",
}
const hookCalls = []

globalThis.Bun = {
  spawn(command, options) {
    const hook = command.at(-1).split("/").at(-1)
    hookCalls.push({ hook, cwd: options.cwd })
    const additionalContext = hookContext[hook] ?? ""
    return {
      stdout: JSON.stringify({ hookSpecificOutput: { additionalContext } }),
      exited: Promise.resolve(0),
    }
  },
  file() {
    return { json: async () => ({ prompts: ["PREVIOUS_PROMPT"] }) }
  },
}

const { WorkflowPlugin } = await import(`${pathToFileURL(pluginPath).href}?event-test=1`)
const hooks = await WorkflowPlugin({ directory: "/tmp/opencode-plugin-test" })

await hooks["chat.params"]({ sessionID: "primary", agent: "build" })
await hooks["chat.message"](
  { sessionID: "primary" },
  { parts: [{ type: "text", text: "remember this" }] },
)

const firstSystem = { system: [] }
await hooks["experimental.chat.system.transform"]({ sessionID: "primary" }, firstSystem)
assert.deepEqual(firstSystem.system, [
  "MEMORY_CONTEXT",
  "GRAPH_RESEED",
  "Previous OpenCode session for tmp_opencode_plugin_test:\n- PREVIOUS_PROMPT",
  "MEMORY_RECALL",
])
assert.deepEqual(
  hookCalls.map(({ hook }) => hook),
  ["mempalace-recall.sh", "mempalace-context.sh", "graphify-reseed-session.sh"],
)

const secondSystem = { system: [] }
await hooks["experimental.chat.system.transform"]({ sessionID: "primary" }, secondSystem)
assert.deepEqual(secondSystem.system, [])

await hooks["tool.execute.after"]({ tool: "edit", sessionID: "primary" })
assert.equal(hookCalls.at(-1).hook, "graphify-autoupdate.sh")

await hooks["chat.params"]({ sessionID: "child", agent: "explore" })
const callsBeforeChild = hookCalls.length
await hooks["chat.message"](
  { sessionID: "child" },
  { parts: [{ type: "text", text: "do not inject this" }] },
)
await hooks["experimental.chat.system.transform"]({ sessionID: "child" }, { system: [] })
await hooks["tool.execute.after"]({ tool: "edit", sessionID: "child" })
assert.equal(hookCalls.length, callsBeforeChild)

await hooks.event({ event: { type: "session.idle", properties: { sessionID: "primary" } } })
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "child" } } })
const recapPath = join(home, ".mempalace", "recaps", "opencode-tmp_opencode_plugin_test.json")
const recap = JSON.parse(await readFile(recapPath, "utf8"))
assert.deepEqual(recap.prompts, ["remember this"])
assert.equal((await stat(recapPath)).mode & 0o777, 0o600)

const callsAfterIdle = hookCalls.length
await hooks["chat.message"](
  { sessionID: "primary" },
  { parts: [{ type: "text", text: "idle sessions must be released" }] },
)
assert.equal(hookCalls.length, callsAfterIdle)

console.log("OpenCode lifecycle event test: PASS")
await rm(home, { recursive: true, force: true })
