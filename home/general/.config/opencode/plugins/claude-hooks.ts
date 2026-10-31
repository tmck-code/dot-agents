/**
 * Claude Code hook bridge for OpenCode V2.
 *
 * The Python hooks under `$CLAUDE_CONFIG_DIR/hooks` are the single source of
 * truth. They still speak the Claude Code contract (JSON on stdin, JSON or
 * exit-2 on stdout/stderr). This plugin translates OpenCode V2's in-process
 * hooks and event stream into that contract, then applies the result:
 *
 *   Claude event        OpenCode surface
 *   UserPromptSubmit    ctx.session.hook("prompt")
 *   PreToolUse          ctx.tool.hook("execute.before")  (a throw rejects the call)
 *   PostToolUse         ctx.tool.hook("execute.after")
 *   PreCompact          ctx.session.hook("compaction")
 *   Stop                session.execution.succeeded (session.idle also works)
 *   SubagentStop        the same event for a session with parentID
 *   Notification        cli.json attention.* (not duplicated here)
 *
 * additionalContext is not a first-class OpenCode channel. It is queued and
 * appended as a system part on the session's next model call, which is the
 * closest equivalent to Claude's per-event injection.
 *
 * The plugin has no runtime dependencies. `@opencode/plugin` is imported only
 * for types; add it to the OpenCode config dir if you want to typecheck.
 */
import type { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
import { appendFileSync, existsSync } from "node:fs"
import { homedir } from "node:os"
import { basename, join } from "node:path"

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude")
const HOOK_DIR = join(CLAUDE_DIR, "hooks")

type SessionInfo = {
  id: string
  parentID?: string
  directory?: string
  agent?: string
  title?: string
}

type HookRun = { code: number; stdout: string; stderr: string }
type HookDecision = { deny?: string; context?: string }

type HookSpec = {
  file: string
  tools: string[]
  timeout?: number
}

/** OpenCode tool name -> the name the Python hooks were written against. */
const CLAUDE_TOOL: Record<string, string> = {
  shell: "Bash",
  bash: "Bash",
  read: "Read",
  edit: "Edit",
  write: "Write",
  patch: "Edit",
  grep: "Grep",
  glob: "Glob",
  subagent: "Agent",
  task: "Agent",
}

const IN_CONTAINER = existsSync("/.dockerenv") || process.env.OPENCODE_CONTAINER === "1"

const PRE_TOOL: HookSpec[] = [
  // Host npm is not a risk inside the agent container, and there is no Docker
  // socket there to redirect into; skip this host-only guard.
  ...(IN_CONTAINER ? [] : [{ file: "ban-host-npm.py", tools: ["Bash"], timeout: 15 * 60_000 }]),
  { file: "no-long-sleep.py", tools: ["Bash"] },
  { file: "subagent-git-tree-guard.py", tools: ["Bash"] },
  { file: "nudge-delegate.py", tools: ["Bash", "Read", "Edit", "Write", "Grep", "Glob"] },
  { file: "subagent-file-handoff.py", tools: ["Agent"] },
]

const SESSION_TTL_MS = 30_000
const sessionCache = new Map<string, { at: number; info: SessionInfo }>()
const pendingContext = new Map<string, string[]>()
const lastIdle = new Map<string, number>()
const lastCaptured = new Map<string, string>()

function script(name: string): string {
  return join(HOOK_DIR, name)
}

function hookEnv(cwd: string): Record<string, string | undefined> {
  return {
    ...process.env,
    CLAUDE_CONFIG_DIR: CLAUDE_DIR,
    CLAUDE_PROJECT_DIR: cwd,
  }
}

function runPython(
  name: string,
  args: string[],
  payload: unknown,
  cwd: string,
  timeout: number,
): Promise<HookRun> {
  const file = script(name)
  if (!existsSync(file)) return Promise.resolve({ code: 0, stdout: "", stderr: "" })

  return new Promise((resolve) => {
    let settled = false
    let stdout = ""
    let stderr = ""
    const finish = (result: HookRun) => {
      if (settled) return
      settled = true
      resolve(result)
    }

    const child = spawn("python3", [file, ...args], {
      cwd,
      env: hookEnv(cwd),
      stdio: ["pipe", "pipe", "pipe"],
      signal: AbortSignal.timeout(timeout),
    })

    child.stdout.on("data", (chunk) => (stdout += String(chunk)))
    child.stderr.on("data", (chunk) => (stderr += String(chunk)))
    child.on("error", () => finish({ code: 0, stdout, stderr }))
    child.on("close", (code) => finish({ code: code ?? 0, stdout, stderr }))
    child.stdin.on("error", () => {})
    child.stdin.end(payload === undefined ? "" : JSON.stringify(payload))
  })
}

function runHook(name: string, payload: unknown, cwd: string, timeout = 120_000): Promise<HookRun> {
  if (process.env.OPENCODE_HOOKS_DEBUG) {
    try {
      appendFileSync("/tmp/claude-hooks.log", `${new Date().toISOString()} ${name}\n`)
    } catch {
      // Debug logging must never break a hook invocation.
    }
    console.log(`[claude-hooks] run ${name}`)
  }
  return runPython(name, [], payload, cwd, timeout)
}

function decide(result: HookRun): HookDecision {
  // Claude's blocking contract: exit 2, reason on stderr.
  if (result.code === 2) {
    return { deny: result.stderr.trim() || "Blocked by a Claude Code hook" }
  }
  if (result.code !== 0 || !result.stdout.trim()) return {}

  try {
    const output = JSON.parse(result.stdout)?.hookSpecificOutput
    if (!output || typeof output !== "object") return {}
    if (output.permissionDecision === "deny") {
      return {
        deny: String(output.permissionDecisionReason || result.stderr || "Blocked by a Claude Code hook"),
      }
    }
    if (typeof output.additionalContext === "string" && output.additionalContext.trim()) {
      return { context: output.additionalContext }
    }
  } catch {
    // Hooks are fail-open by design; a malformed payload must never wedge a call.
  }
  return {}
}

function enqueue(sessionID: string, text: string): void {
  const queue = pendingContext.get(sessionID)
  if (queue) queue.push(text)
  else pendingContext.set(sessionID, [text])
}

function drain(sessionID: string): string[] {
  const queue = pendingContext.get(sessionID)
  if (!queue) return []
  pendingContext.delete(sessionID)
  return queue
}

async function getSession(ctx: any, sessionID: string): Promise<SessionInfo> {
  const cached = sessionCache.get(sessionID)
  if (cached && Date.now() - cached.at < SESSION_TTL_MS) return cached.info
  try {
    const info = (await ctx.session.get({ sessionID })) as SessionInfo
    sessionCache.set(sessionID, { at: Date.now(), info })
    return info
  } catch {
    const fallback: SessionInfo = { id: sessionID, directory: ctx.location?.directory }
    return fallback
  }
}

function cwdOf(ctx: any, session: SessionInfo): string {
  return session.directory || ctx.location?.directory || process.cwd()
}

function claudeToolName(tool: string): string | undefined {
  return CLAUDE_TOOL[tool]
}

function claudeInput(tool: string, input: any): Record<string, unknown> {
  const value = (input ?? {}) as Record<string, any>
  if (tool === "shell" || tool === "bash") {
    return {
      command: value.command ?? "",
      run_in_background: value.background ?? value.run_in_background ?? false,
    }
  }
  if (tool === "read") {
    return {
      file_path: value.path ?? value.file_path ?? "",
      offset: value.offset,
      limit: value.limit,
    }
  }
  if (tool === "edit" || tool === "write" || tool === "patch") {
    return { file_path: value.path ?? value.file_path ?? "" }
  }
  if (tool === "grep" || tool === "glob") {
    return { ...value, file_path: value.path ?? value.file_path }
  }
  if (tool === "subagent" || tool === "task") {
    return {
      description: value.description,
      prompt: value.prompt,
      subagent_type: value.agent ?? value.subagent_type,
    }
  }
  return value
}

function basePayload(session: SessionInfo, cwd: string, event: string): Record<string, unknown> {
  const child = Boolean(session.parentID)
  return {
    hook_event_name: event,
    session_id: session.id,
    cwd,
    // Claude sets agent_id/agent_type only on subagent-originated calls.
    agent_id: child ? session.id : undefined,
    agent_type: child ? session.agent || undefined : undefined,
    permission_mode: "default",
  }
}

function toolPayload(
  session: SessionInfo,
  cwd: string,
  event: string,
  tool: string,
  input: unknown,
  id?: string,
): Record<string, unknown> {
  const claudeTool = claudeToolName(tool)
  return {
    ...basePayload(session, cwd, event),
    tool_name: claudeTool ?? tool,
    tool_input: claudeTool ? claudeInput(tool, input) : input,
    tool_use_id: id,
  }
}

function appendResult(result: any, text: string): void {
  if (!result || typeof result !== "object") return
  if (typeof result.content === "string") {
    result.content = `${result.content}\n\n${text}`
  } else if (Array.isArray(result.content)) {
    result.content = [...result.content, { type: "text", text }]
  } else {
    result.content = text
  }
}

async function lastAssistant(ctx: any, sessionID: string): Promise<{ id: string; text: string } | undefined> {
  try {
    const messages = (await ctx.session.context({ sessionID })) as any[]
    for (let i = messages.length - 1; i >= 0; i--) {
      const message = messages[i]
      if (message?.type !== "assistant") continue
      const text = (Array.isArray(message.content) ? message.content : [])
        .filter((part: any) => part?.type === "text" && typeof part.text === "string")
        .map((part: any) => part.text)
        .join("\n")
      if (text.trim()) return { id: String(message.id), text }
    }
  } catch {
    // A missing transcript must never break completion handling.
  }
  return undefined
}

function summarise(text: string | undefined): string {
  if (!text) return ""
  for (const line of text.split("\n")) {
    const trimmed = line.trim().replace(/^[#>*\-\s]+/, "").trim()
    if (trimmed) return trimmed.length > 200 ? `${trimmed.slice(0, 199)}…` : trimmed
  }
  return ""
}

async function notify(
  ctx: any,
  session: SessionInfo,
  cwd: string,
  title: string,
  body: string,
  urgency = "normal",
): Promise<void> {
  const project = basename(cwd) || "project"
  await runPython(
    "agent-notify.py",
    ["send", "OpenCode", `opencode:${session.id}`, `${project} · ${title}`, body, urgency],
    undefined,
    cwd,
    10_000,
  )
}

export default {
  id: "claude-hooks",
  async setup(ctx: any) {
    if (process.env.OPENCODE_HOOKS_DEBUG) {
      console.log(`[claude-hooks] loaded; hooks=${HOOK_DIR}; cwd=${ctx.location?.directory}`)
    }
    // ---- UserPromptSubmit -------------------------------------------------
    await ctx.session.hook("prompt", async (event: any) => {
      const session = await getSession(ctx, event.sessionID)
      const cwd = cwdOf(ctx, session)
      const result = decide(
        await runHook(
          "skill-nudge.py",
          {
            ...basePayload(session, cwd, "UserPromptSubmit"),
            prompt: event.prompt.text,
          },
          cwd,
          30_000,
        ),
      )
      if (result.context) {
        event.prompt.text = `${event.prompt.text}\n\n${result.context}`
      }
    })

    // ---- PreToolUse -------------------------------------------------------
    await ctx.tool.hook("execute.before", async (event: any) => {
      const claudeTool = claudeToolName(event.tool)
      if (!claudeTool) return

      const session = await getSession(ctx, event.sessionID)
      const cwd = cwdOf(ctx, session)
      const payload = toolPayload(session, cwd, "PreToolUse", event.tool, event.input, event.id)

      const contexts: string[] = []
      for (const spec of PRE_TOOL) {
        if (!spec.tools.includes(claudeTool)) continue
        const result = decide(await runHook(spec.file, payload, cwd, spec.timeout))
        if (result.deny) {
          // execute.before is the one hook whose rejection cancels the call;
          // the promise adapter wraps this into a Tool.Error the model sees.
          throw new Error(result.deny)
        }
        if (result.context) contexts.push(result.context)
      }
      for (const text of contexts) enqueue(event.sessionID, text)
    })

    // ---- PostToolUse ------------------------------------------------------
    await ctx.tool.hook("execute.after", async (event: any) => {
      if (event.status !== "completed") return
      const claudeTool = claudeToolName(event.tool)
      if (!claudeTool) return

      const session = await getSession(ctx, event.sessionID)
      const cwd = cwdOf(ctx, session)

      if (claudeTool === "Edit" || claudeTool === "Write") {
        const result = decide(
          await runHook(
            "same-file-write-audit.py",
            toolPayload(session, cwd, "PostToolUse", event.tool, event.input, event.id),
            cwd,
            30_000,
          ),
        )
        if (result.context) {
          try {
            appendResult(event.result, result.context)
          } catch {
            enqueue(event.sessionID, result.context)
          }
        }
      }

      if (claudeTool === "Agent") {
        const announce = decide(
          await runHook(
            "subagent-report-announce.py",
            {
              hook_event_name: "PostToolUse",
              tool_name: "TaskOutput",
              session_id: event.sessionID,
              cwd,
            },
            cwd,
            30_000,
          ),
        )
        if (announce.context) {
          try {
            appendResult(event.result, announce.context)
          } catch {
            enqueue(event.sessionID, announce.context)
          }
        }
      }
    })

    // ---- PreCompact -------------------------------------------------------
    await ctx.session.hook("compaction", async (event: any) => {
      const session = await getSession(ctx, event.sessionID)
      const cwd = cwdOf(ctx, session)
      await runHook(
        "precompact-probe.py",
        {
          ...basePayload(session, cwd, "PreCompact"),
          trigger: "auto",
        },
        cwd,
        10_000,
      )
    })

    // ---- additionalContext delivery --------------------------------------
    await ctx.session.hook("context", (event: any) => {
      const notes = drain(event.sessionID)
      for (const text of notes) event.system.push({ type: "text", text })
    })

    // ---- Stop / SubagentStop / StopFailure -------------------------------
    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (process.env.OPENCODE_HOOKS_DEBUG) {
          appendFileSync("/tmp/opencode/claude-events.log", `${event.type} ${JSON.stringify(event.data ?? {})}\n`)
        }
        if (event.type === "session.idle" || event.type === "session.execution.succeeded") {
          await onIdle(ctx, String(event.data.sessionID))
        } else if (event.type === "session.execution.failed") {
          const session = await getSession(ctx, String(event.data.sessionID))
          const cwd = cwdOf(ctx, session)
          const message = String(event.data.error?.message || "Turn failed")
          await notify(ctx, session, cwd, "Error", summarise(message) || message, "critical")
        }
      }
    })().catch(() => {
      // The event stream closing is not a plugin failure.
    })

    return () => controller.abort()
  },
} satisfies Plugin

async function onIdle(ctx: any, sessionID: string): Promise<void> {
  const now = Date.now()
  if (now - (lastIdle.get(sessionID) ?? 0) < 1_500) return
  lastIdle.set(sessionID, now)

  const session = await getSession(ctx, sessionID)
  const cwd = cwdOf(ctx, session)
  const last = await lastAssistant(ctx, sessionID)

  if (!session.parentID) {
    await notify(ctx, session, cwd, "Done", summarise(last?.text) || "Finished")
    return
  }

  // ---- SubagentStop ------------------------------------------------------
  if (!last || lastCaptured.get(sessionID) === last.id) return
  lastCaptured.set(sessionID, last.id)

  const parentID = session.parentID
  const payload = {
    hook_event_name: "SubagentStop",
    session_id: parentID,
    cwd,
    agent_id: sessionID,
    agent_type: session.agent || "agent",
    last_assistant_message: last.text,
    stop_hook_active: false,
    background_tasks: [{ id: sessionID, description: session.title || "" }],
  }

  await runHook("subagent-report-capture.py", payload, cwd, 60_000)

  const handoff = decide(await runHook("handoff-nudge.py", payload, cwd, 30_000))
  if (handoff.context) enqueue(parentID, handoff.context)

  const announce = decide(
    await runHook(
      "subagent-report-announce.py",
      {
        hook_event_name: "PostToolUse",
        tool_name: "TaskOutput",
        session_id: parentID,
        cwd,
      },
      cwd,
      30_000,
    ),
  )
  if (announce.context) enqueue(parentID, announce.context)

  await notify(ctx, session, cwd, "Subagent done", summarise(last.text) || "Finished")
}
