// Lease plugin: refresh the LiteLLM virtual key while the lease is active.
//
// The launcher resolves the first key before starting OpenCode. This plugin
// handles a long-running session whose lease outlives the key, and fails
// closed when the broker says the lease is revoked or expired.
import { Plugin } from "@opencode/plugin"

const BROKER_URL = (process.env.BROKER_URL ?? "").replace(/\/$/, "")
const LEASE_TOKEN = process.env.LEASE_TOKEN ?? ""
const INTERVAL_MS = Number(process.env.LEASE_REFRESH_INTERVAL_MS ?? "60000")

let lastRefresh = 0

async function refresh(force = false): Promise<void> {
  if (!BROKER_URL || !LEASE_TOKEN) return
  if (!force && Date.now() - lastRefresh < INTERVAL_MS) return
  try {
    const response = await fetch(`${BROKER_URL}/v1/token/litellm`, {
      headers: { Authorization: `Bearer ${LEASE_TOKEN}` },
      signal: AbortSignal.timeout(5000),
    })
    if (response.status === 401 || response.status === 403) {
      throw new Error(`lease is no longer valid (${response.status})`)
    }
    if (!response.ok) {
      // Transient broker/LiteLLM problem: keep the current key and retry.
      return
    }
    const body = (await response.json()) as { key?: string; base_url?: string }
    if (body.key) {
      process.env.LITELLM_API_KEY = body.key
      process.env.LITELLM_BASE_URL = body.base_url ?? process.env.LITELLM_BASE_URL
      lastRefresh = Date.now()
    }
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("lease is no longer valid")) {
      throw error
    }
    // Network errors are retried on the next tool call.
  }
}

export default Plugin.define({
  id: "opencode-lease",
  async setup(ctx) {
    await refresh(true)

    ctx.tool.hook("execute.before", async () => {
      await refresh()
      return undefined
    })

    try {
      ctx.session.hook("context", async () => {
        await refresh()
        return undefined
      })
    } catch {
      // Tool refresh still covers long sessions.
    }
  },
})
