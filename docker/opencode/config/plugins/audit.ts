// Audit plugin: redacted JSONL of tool calls, shell commands and permission
// decisions.
//
// The agent can write to this volume, so treat the audit as a convenience.
// The Squid proxy log and the broker's issuance events are authoritative.
import { appendFile, mkdir } from "node:fs/promises"
import { dirname } from "node:path"
import { Plugin } from "@opencode/plugin"

const AUDIT = process.env.OPENCODE_AUDIT_LOG ?? "/var/log/opencode/audit.jsonl"

const SECRET_PATTERNS: Array<[RegExp, string]> = [
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, "[REDACTED PRIVATE KEY]"],
  [/\bsk-[A-Za-z0-9_-]{16,}\b/g, "[REDACTED PROVIDER KEY]"],
  [/\bgh[pousr]_[A-Za-z0-9]{16,}\b/g, "[REDACTED GITHUB TOKEN]"],
  [/\bgithub_pat_[A-Za-z0-9_]{16,}\b/g, "[REDACTED GITHUB TOKEN]"],
  [/\bAKIA[0-9A-Z]{16}\b/g, "[REDACTED AWS KEY]"],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g, "[REDACTED SLACK TOKEN]"],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{10,}\b/gi, "Bearer [REDACTED]"],
  [
    /\b(password|passwd|token|secret|api[_-]?key|authorization)\s*[=:]\s*("[^"]*"|'[^']*'|\S+)/gi,
    "$1=[REDACTED]",
  ],
]

function redactString(value: string): string {
  let output = value
  for (const [pattern, replacement] of SECRET_PATTERNS) {
    output = output.replace(pattern, replacement)
  }
  return output
}

function redact(value: unknown, depth = 0): unknown {
  if (depth > 6) return "[TRUNCATED]"
  if (typeof value === "string") return redactString(value)
  if (Array.isArray(value)) return value.slice(0, 50).map((item) => redact(item, depth + 1))
  if (value && typeof value === "object") {
    const output: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      if (/token|secret|password|authorization|api[_-]?key/i.test(key)) {
        output[key] = "[REDACTED]"
      } else {
        output[key] = redact(item, depth + 1)
      }
    }
    return output
  }
  return value
}

async function record(entry: Record<string, unknown>): Promise<void> {
  try {
    await mkdir(dirname(AUDIT), { recursive: true })
    const safe = redact(entry) as Record<string, unknown>
    await appendFile(
      AUDIT,
      JSON.stringify({ ts: new Date().toISOString(), ...safe }) + "\n",
      { mode: 0o600 },
    )
  } catch {
    // Audit failures must not break the session; the proxy/broker logs remain.
  }
}

export default Plugin.define({
  id: "opencode-audit",
  async setup(ctx) {
    const started = new Map<string, number>()

    ctx.permission.hook("evaluate", async (event) => {
      await record({
        kind: "permission",
        action: event.action,
        resources: event.resources ?? [],
        effect: event.effect,
      })
      return undefined
    })

    ctx.shell.hook("create.before", async (event) => {
      const shellEvent = event as { command?: string; cwd?: string; agent?: string }
      await record({
        kind: "shell.create",
        agent: shellEvent.agent ?? null,
        cwd: shellEvent.cwd ?? null,
        command: shellEvent.command ?? null,
      })
      return undefined
    })

    ctx.tool.hook("execute.before", async (event) => {
      started.set(event.id ?? event.sessionID, Date.now())
      await record({
        kind: "tool.execute.before",
        tool: event.tool,
        session: event.sessionID,
        agent: event.agent,
        input: event.input,
      })
      return undefined
    })

    ctx.tool.hook("execute.after", async (event) => {
      const start = started.get(event.id ?? event.sessionID)
      started.delete(event.id ?? event.sessionID)
      await record({
        kind: "tool.execute.after",
        tool: event.tool,
        session: event.sessionID,
        agent: event.agent,
        status: event.status,
        duration_ms: start ? Date.now() - start : null,
      })
      return undefined
    })

    // Session prompt metadata is recorded when a context hook fires. Register
    // defensively so a future hook rename cannot stop the plugin loading.
    try {
      ctx.session.hook("context", async (event) => {
        await record({
          kind: "session.context",
          session: (event as { sessionID?: string }).sessionID ?? null,
          agent: (event as { agent?: string }).agent ?? null,
        })
        return undefined
      })
    } catch {
      // The other audit hooks still work.
    }
  },
})
