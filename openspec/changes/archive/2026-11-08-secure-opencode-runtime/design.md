## Context

`docker/opencode/run.sh` currently bind-mounts the repo at its host path, the host `~/.claude` and OpenCode config/state, `~/.ssh`, `~/.config/gh` and `~/.gitconfig`, forwards an SSH agent, passes provider tokens as environment variables, and uses the default Docker bridge with `host.docker.internal`. That is convenient for trusted repos but gives the agent a broad view of host credentials and unrestricted egress.

The target is a local-only, free Docker setup for trusted repositories. The existing image remains a single `opencode-dev` target; the runtime is hardened in the launcher and surrounded by a local security stack. No paid vault, hosted sandbox or cloud broker is introduced.

## Goals / Non-Goals

**Goals:**

- Keep the current developer toolchain and repo-at-same-path workflow.
- Make the container a meaningful network boundary: internal-only agent network, proxy-only egress.
- Keep root secrets on the host; give the agent scoped lease tokens or short-lived credentials.
- Support long-running jobs by refreshing GitHub App installation tokens while a lease is active.
- Make OpenCode policy and guardrails independent of the repository being edited.
- Keep every phase shippable and retain an explicit `--unsafe` escape hatch.
- Provide a transparent, local secret source (SOPS+age and/or a dedicated KeePassXC DB).

**Non-Goals:**

- Protecting against a malicious agent that can exploit the host kernel. This is container isolation, not a microVM.
- Supporting paid or hosted secret managers, sandboxes or cloud brokers.
- Replacing the existing audit/options SPA; this change adds an implementation SPA and links the two.
- Porting the Python Claude hooks to OpenCode in this change.
- Implementing cloud provider credential leasing beyond the broker interface in phase 3.

## Decisions

### One image target, hardened at runtime

Keep a single `opencode-dev` image target, because agents need the compiler, Node, uv/Python, git, gh and git-lfs. Do not split a runtime-only target now: it would double the build matrix and diverge from the toolchain agents actually use. Harden the image itself (non-root, digest-pinned bases, checksum-verified installer, read-only `/etc/opencode`, no secrets) and enforce network and capability restrictions in the launcher.

Alternative considered: a separate `opencode-runtime` target without build tools. Rejected for now because it would break native-wheel and build tasks; can be added later if a read-only runtime becomes useful.

### Agent on an internal-only Docker network

Create `opencode-agent` with `internal: true` and attach only the agent. The proxy, broker and LiteLLM join both `opencode-agent` and a normal `opencode-egress` bridge. The agent has no default route, no host gateway and no default bridge. `HTTP_PROXY`/`HTTPS_PROXY` are set for convenience, but the route is the real enforcement.

Alternative considered: host proxy reached through `host.docker.internal`. Rejected because the same route exposes other host services and requires firewall work on the host; a dedicated internal Docker network is more portable and testable.

### Squid for generic egress, LiteLLM for provider auth

Use Squid as a default-deny forward proxy with a domain allowlist for registries, GitHub and other project destinations. Use LiteLLM as an explicit reverse proxy for model APIs, so provider keys never enter the agent and no TLS interception is required. Squid sees only `CONNECT host:443`; it cannot inject headers. That is acceptable because service-specific auth goes through LiteLLM or the lease broker.

Alternative considered: mitmproxy with a custom addon and local CA. Rejected as the default because TLS interception adds a CA, a private key and a large parser attack surface for little benefit when a reverse proxy can handle model auth. It remains a later option for sites that need header injection and cannot use a reverse proxy.

### Local lease broker with GitHub App tokens

Build a small FastAPI service with SQLite for leases. It stores lease ID, session, service, resource, actions, expiry and status. GitHub auth uses a GitHub App: the broker signs an App JWT with a private key held on the host, exchanges it for an installation token scoped to one repo/org and least permissions, and refreshes the token while the lease is active. The agent gets a lease token and a short-lived installation token, never the App private key.

Alternative considered: cache a fine-grained PAT for the job. Rejected as the default because a leaked PAT is valid until revoked and is not scoped to the job; it remains a documented fallback.

### Provider virtual keys through LiteLLM

LiteLLM holds the provider root keys and exposes an OpenAI-compatible endpoint. The broker issues a per-lease LiteLLM virtual key with model allowlist, budget and duration. OpenCode provider base URLs point at LiteLLM. This avoids storing provider keys in the agent and avoids MITM.

Alternative considered: a custom provider proxy. Rejected because LiteLLM already supports the provider matrix and usage/budget controls, and local LiteLLM is free.

### System policy, then permissions, then plugins

Bake `/etc/opencode/opencode.jsonc` with hard `policies` and read-only permissions. It outranks project config, so a repository cannot re-enable a denied provider or tool. Add OpenCode-native plugins for audit and guardrails using `permission.evaluate`, `tool.execute.before`, `shell.create.before` and session hooks. The plugins are guardrails inside the boundary, not a substitute for it.

Alternatives considered: only user-level config (a repo can override it), and only Python hook bridging (more moving parts for this change). Rejected for the security baseline; a bridge can be added later.

### Project plugins allowed for trusted repos, but audited

Because the target is trusted repos, project plugins, skills and MCP servers are allowed by default when they pass system policy. The audit plugin records their tool calls. For untrusted work, the same system policy can deny `integration.use` for project plugins and MCP servers without changing the image.

### Local secret source, not a vault service

Use SOPS+age as the primary host store and a dedicated KeePassXC agent DB as an alternative. The wrapper decrypts only the named values into the host-side stack. The agent never mounts the `.kdbx`, age key, decrypted file or provider root key. No 1Password, Vault server or hosted manager is required.

### Read-only rootfs is opt-in

Add `--read-only` support with tmpfs and named writable volumes, but keep it opt-in until the toolchain and OpenCode caches are verified. Capability dropping, no-new-privileges and resource limits are on by default.

### Explicit unsafe mode

`--unsafe` restores legacy mounts, host gateway and token forwarding for debugging. It prints a warning listing what is exposed. Per-service `--with-ssh` and `--with-gh` flags cover narrower needs. Safe defaults never silently degrade.

## Risks / Trade-offs

- **Proxy is not a full data-loss boundary** → Allowlist only what the project needs; use LiteLLM/broker scoping for credentials; accept that an allowed domain can still be an exfiltration channel.
- **Container isolation still shares the kernel** → Keep Docker updated; support rootless Docker; document that a microVM is required for hostile code.
- **Squid cannot enforce HTTP paths** → Use LiteLLM for model APIs and the broker for GitHub; add mitmproxy later only if a concrete path/method rule is required.
- **Broker is custom code** → Keep it small, typed where practical, with unit tests for lease scope, expiry, revocation and token minting; run it non-root with a read-only rootfs and a dedicated state volume.
- **LiteLLM is another dependency** → Pin the image digest, run it non-root, expose only the internal port, and keep provider keys in a read-only secret mount.
- **GitHub App setup is more work than a PAT** → Document a PAT fallback for a single job; keep the lease path as the default.
- **Long-running token refresh can fail** → Return a clear `401`/`409` to the helper; the agent retries; the lease remains valid; the operator can inspect broker logs.
- **Agent can tamper with its own audit log** → Treat proxy and broker logs as authoritative; keep the plugin audit as a convenience and redact secrets.
- **`--unsafe` becomes the default in practice** → Print a warning, log its use, and test that safe mode is the default in CI.
- **Project plugins are code execution** → Trusted-repo assumption; audit plugin calls; system policy can deny `integration.use` for untrusted work.
- **Host browser-control relay becomes unreachable** → A relay bound to host loopback cannot be reached from the internal-only agent network. If browser automation is required, expose only that relay through a narrow proxy route or run the relay inside the stack; do not restore general host access.

## Migration Plan

1. Land the hardened image and launcher defaults behind `--unsafe` for rollback. Keep existing repo/worktree behaviour.
2. Add the internal network and Squid proxy; add the bypass test suite; keep host-gateway use opt-in.
3. Add the lease broker, LiteLLM and GitHub App token refresh; migrate git/gh and model providers to lease/virtual keys.
4. Add system policy, guard plugins and audit; then add the SPA and diagram docs.
5. Roll back by running with `--unsafe` and the previous image tag; the host-side stack is additive.

## Open Questions

- Which model providers must LiteLLM support on day one (Anthropic only, or OpenAI-compatible as well)?
- Should the broker be Python/FastAPI or Go for a smaller runtime image?
- Does the agent need to push to GitHub, or is read-only git/gh sufficient for the first iteration?
- Should `--read-only` become the default after the toolchain smoke tests pass?
- Do we want a bridge for the existing Python hooks in a later change?
- Does the workflow need host browser automation? If so, should the relay be proxied narrowly or moved into the stack?
