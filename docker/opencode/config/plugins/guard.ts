// Guard plugin: protected paths, dangerous commands, external directories and
// proxy environment injection.
//
// This is a guardrail inside the container boundary, not the boundary itself.
// The internal network, dropped capabilities and read-only mounts are what
// make the agent unable to reach the host or the open internet.
import { Plugin } from "@opencode/plugin"
import { isAbsolute } from "node:path"

const PROXY = process.env.HTTPS_PROXY ?? "http://squid:3128"
const NO_PROXY =
  process.env.NO_PROXY ?? "litellm,broker,squid,excalidraw,localhost,127.0.0.1,::1"

const PROXY_ENV: Record<string, string> = {
  HTTP_PROXY: process.env.HTTP_PROXY ?? PROXY,
  HTTPS_PROXY: PROXY,
  http_proxy: process.env.http_proxy ?? PROXY,
  https_proxy: PROXY,
  NO_PROXY,
  no_proxy: NO_PROXY,
}

const PROTECTED = [
  /(^|\/)\.env(\.|$)/,
  /(^|\/)\.envrc(?:$|\/)/,
  /(^|\/)\.ssh(?:\/|$)/,
  /(^|\/)(?:id_rsa|id_ed25519|id_ecdsa|id_dsa)(?:\.|$)/,
  /\.(?:pem|key|p12|pfx|kdbx)$/i,
  /(^|\/)(?:auth\.json|age\.key|age-key\.txt|secrets\.ya?ml|credentials)$/i,
  /(^|\/)\.gnupg(?:\/|$)/,
]

const DANGEROUS =
  /(^|[;&|]\s*|\s)(?:sudo|su|doas|mount|umount|nsenter|unshare|chroot|docker|podman|kexec|insmod|modprobe|setcap|iptables|nft)\b/

const ALLOWED_ROOTS = [
  process.env.OPENCODE_WORKSPACE ?? "",
  "/tmp",
  "/home/agent/.claude",
  "/home/agent/.agents",
  "/home/agent/.config/opencode",
  "/etc/opencode",
  "/var/log/opencode",
].filter(Boolean)

function isProtected(path: string): boolean {
  return PROTECTED.some((pattern) => pattern.test(path))
}

function isWithin(path: string, root: string): boolean {
  if (path === root) return true
  return path.startsWith(root.endsWith("/") ? root : `${root}/`)
}

function isExternal(path: string): boolean {
  if (!isAbsolute(path)) return false
  return !ALLOWED_ROOTS.some((root) => isWithin(path, root))
}

function deny(event: { effect?: string; message?: string }, message: string) {
  // The documented contract is mutation; return the decision too so a future
  // OpenCode release that accepts a returned result keeps working.
  event.effect = "deny"
  event.message = message
  return { effect: "deny" as const, message }
}

function strings(value: unknown): string[] {
  if (typeof value === "string") return [value]
  if (Array.isArray(value)) return value.filter((item): item is string => typeof item === "string")
  return []
}

function pathsFrom(input: Record<string, unknown>): string[] {
  const paths: string[] = []
  for (const key of ["path", "file", "filePath", "target", "resource", "resources"]) {
    paths.push(...strings(input[key]))
  }
  return paths
}

export default Plugin.define({
  id: "opencode-guard",
  async setup(ctx) {
    // A configured deny is final: the permission hook is not called for it,
    // and if it is, this hook never upgrades deny to allow.
    ctx.permission.hook("evaluate", async (event) => {
      if (event.effect === "deny") return undefined

      const resources = event.resources ?? []
      const filesystem = event.action === "read" || event.action === "edit"

      if (filesystem) {
        for (const resource of resources) {
          if (isProtected(resource)) {
            return deny(event, `Blocked by opencode-guard: protected path ${resource}`)
          }
          if (isExternal(resource)) {
            return deny(event, `Blocked by opencode-guard: path outside the workspace: ${resource}`)
          }
        }
      }

      if (event.action === "shell") {
        for (const resource of resources) {
          if (DANGEROUS.test(resource)) {
            return deny(event, "Blocked by opencode-guard: dangerous shell command")
          }
        }
      }

      return undefined
    })

    ctx.tool.hook("execute.before", async (event) => {
      const input = (event.input ?? {}) as Record<string, unknown>
      for (const path of pathsFrom(input)) {
        if (isProtected(path)) {
          throw new Error(`Blocked by opencode-guard: protected path ${path}`)
        }
        if (isExternal(path)) {
          throw new Error(
            `Blocked by opencode-guard: path outside the workspace: ${path}`,
          )
        }
      }
      const command = typeof input.command === "string" ? input.command : ""
      if (DANGEROUS.test(command)) {
        throw new Error("Blocked by opencode-guard: dangerous shell command")
      }
      return undefined
    })

    ctx.shell.hook("create.before", async (event) => {
      const command = (event as { command?: string }).command ?? ""
      if (DANGEROUS.test(command)) {
        throw new Error("Blocked by opencode-guard: dangerous shell command")
      }
      // Tools that ignore the image-level proxy env still lose direct egress:
      // the internal network has no default route. This keeps the common case
      // working without weakening the boundary.
      const target = event as { env?: Record<string, string> }
      target.env = { ...(target.env ?? {}), ...PROXY_ENV }
      return undefined
    })
  },
})
