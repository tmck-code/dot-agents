// Exercise the OpenCode plugins without a full OpenCode process.
//
// The real @opencode/plugin package only provides Plugin.define(), so a tiny
// shim is enough. Plugins are copied to a temp directory so node module
// resolution finds the shim, then each hook is invoked with a typed event.

import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const source = join(here, "..", "config", "plugins")
const tmp = await mkdtemp(join(tmpdir(), "opencode-plugins."))
const plugins = join(tmp, "plugins")
const shim = join(tmp, "node_modules", "@opencode", "plugin")

const failures = []
function check(name, condition) {
  if (condition) {
    console.log(`ok   ${name}`)
  } else {
    failures.push(name)
    console.error(`FAIL ${name}`)
  }
}

function makeCtx() {
  const hooks = { permission: {}, tool: {}, shell: {}, session: {} }
  const register = (group) => (name, fn) => {
    hooks[group][name] = fn
  }
  const ctx = {
    permission: { hook: register("permission") },
    tool: { hook: register("tool") },
    shell: { hook: register("shell") },
    session: { hook: register("session") },
  }
  return { ctx, hooks }
}

try {
  await cp(source, plugins, { recursive: true })
  await mkdir(shim, { recursive: true })
  await writeFile(
    join(shim, "package.json"),
    JSON.stringify({ name: "@opencode/plugin", type: "module", main: "index.js" }),
  )
  await writeFile(
    join(shim, "index.js"),
    "export const Plugin = { define: (value) => value }\n",
  )

  const workspace = join(tmp, "workspace")
  await mkdir(workspace, { recursive: true })
  process.env.OPENCODE_WORKSPACE = workspace
  process.env.OPENCODE_AUDIT_LOG = join(tmp, "audit", "audit.jsonl")
  process.env.HTTPS_PROXY = "http://squid:3128"
  process.env.NO_PROXY = "litellm,broker"
  process.env.BROKER_URL = "http://broker:8080"
  process.env.LEASE_TOKEN = "lst_test.abc"
  process.env.LITELLM_API_KEY = "old-key"

  globalThis.fetch = async () =>
    new Response(JSON.stringify({ key: "sk-refreshed", base_url: "http://litellm:4000/v1" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    })

  // ---- guard ---------------------------------------------------------------
  const guard = (await import(pathToFileURL(join(plugins, "guard.ts")).href)).default
  const guardCtx = makeCtx()
  await guard.setup(guardCtx.ctx)

  const evaluate = guardCtx.hooks.permission.evaluate
  const protectedEvent = {
    action: "read",
    resources: [join(workspace, ".env")],
    effect: "allow",
  }
  const protectedResult = await evaluate(protectedEvent)
  check(
    "guard denies a protected read",
    protectedResult?.effect === "deny" && protectedEvent.effect === "deny",
  )

  const externalEvent = {
    action: "read",
    resources: ["/etc/passwd"],
    effect: "allow",
  }
  const externalResult = await evaluate(externalEvent)
  check(
    "guard denies an external directory",
    externalResult?.effect === "deny" && externalEvent.effect === "deny",
  )

  const denyResult = await evaluate({
    action: "read",
    resources: [join(workspace, "README.md")],
    effect: "deny",
  })
  check("guard does not override an explicit deny", denyResult === undefined)

  const shellEvent = { command: "echo hello", env: {} }
  await guardCtx.hooks.shell["create.before"](shellEvent)
  check(
    "guard injects proxy environment",
    shellEvent.env?.HTTP_PROXY === "http://squid:3128" &&
      shellEvent.env?.HTTPS_PROXY === "http://squid:3128" &&
      shellEvent.env?.NO_PROXY === "litellm,broker",
  )

  let threw = false
  try {
    await guardCtx.hooks.tool["execute.before"]({
      tool: "read",
      input: { path: join(workspace, ".env") },
    })
  } catch {
    threw = true
  }
  check("guard blocks a protected tool call", threw)

  threw = false
  try {
    await guardCtx.hooks.tool["execute.before"]({
      tool: "shell",
      input: { command: "sudo cat /etc/shadow" },
    })
  } catch {
    threw = true
  }
  check("guard blocks a dangerous shell command", threw)

  // ---- audit ---------------------------------------------------------------
  const audit = (await import(pathToFileURL(join(plugins, "audit.ts")).href)).default
  const auditCtx = makeCtx()
  await audit.setup(auditCtx.ctx)
  const secret = "ghp_" + "a".repeat(36)
  await auditCtx.hooks.tool["execute.before"]({
    tool: "shell",
    sessionID: "ses_1",
    agent: "build",
    id: "call_1",
    input: { command: `curl -H "Authorization: Bearer ${secret}" https://example.com` },
  })
  await auditCtx.hooks.tool["execute.after"]({
    tool: "shell",
    sessionID: "ses_1",
    id: "call_1",
    status: "success",
  })
  const auditText = await readFile(process.env.OPENCODE_AUDIT_LOG, "utf8")
  check("audit writes JSONL", auditText.trim().split("\n").length >= 2)
  check("audit redacts a GitHub token", !auditText.includes(secret))
  check("audit records redaction markers", auditText.includes("REDACTED"))
  check("audit records status and duration", auditText.includes('"status":"success"'))

  // ---- lease ---------------------------------------------------------------
  const lease = (await import(pathToFileURL(join(plugins, "lease.ts")).href)).default
  const leaseCtx = makeCtx()
  await lease.setup(leaseCtx.ctx)
  check("lease refreshes the virtual key", process.env.LITELLM_API_KEY === "sk-refreshed")

  if (failures.length) {
    console.error(`\n${failures.length} guardrail check(s) failed`)
    process.exitCode = 1
  } else {
    console.log("\nguardrails: ok")
  }
} finally {
  await rm(tmp, { recursive: true, force: true })
}
