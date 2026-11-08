## Why

The current OpenCode Docker image is a capable development environment but not a security boundary: it shares the host kernel, mounts host credentials and config, and has unrestricted egress. For trusted repos we still want the convenience of Docker, but we want the agent to receive only scoped, revocable capabilities and to have no direct route to the host or the open internet.

## What Changes

- Harden the single `opencode-dev` image and its launcher: non-root, dropped capabilities, no-new-privileges, resource limits, read-only system config, no SSH/gh mounts by default, no host gateway, and an explicit `--unsafe` escape hatch.
- Put the agent container on an internal-only Docker network. A separate proxy/broker stack is the only egress path.
- Add a local egress proxy container with a default-deny domain allowlist, request logging, and bypass tests.
- Add a local lease broker that issues scoped, expiring leases and mints GitHub App installation tokens; a long-running job may reuse a lease while the underlying token refreshes.
- Add a local LiteLLM container as the model-provider reverse proxy. OpenCode receives a per-lease virtual key, never the provider root key.
- Bake OpenCode system policy at `/etc/opencode/opencode.jsonc` so a project cannot re-enable denied providers or tools.
- Add OpenCode plugins for audit and guardrails (`permission.evaluate`, `tool.execute.before`, `shell.create.before`, `session.prompt`, `session.http.request`), plus tests.
- Add a local secrets workflow based on SOPS + age and/or a dedicated KeePassXC agent database. No paid or cloud secret manager is required.
- Add a new SPA (`docs/opencode-secure-stack.html`) and transparent Excalidraw diagrams describing the target architecture, request paths, lease lifecycle, defence layers and rollout.
- **BREAKING**: `run.sh` no longer mounts `~/.ssh`, `~/.config/gh`, or `host.docker.internal` by default. Use `--with-ssh` or `--unsafe` to restore individual behaviours.

## Capabilities

### New Capabilities

- `opencode-runtime-hardening`: hardened image and launcher defaults, including user, capabilities, mounts, resource limits, network attachment and escape hatches.
- `credential-broker`: scoped leases, approval, expiry, revocation, GitHub App installation tokens and LiteLLM virtual keys.
- `egress-control`: internal agent network, default-deny proxy allowlist, logging, and direct-egress bypass prevention.
- `opencode-guardrails`: system policy, permission rules, plugin hooks, protected paths and audit behaviour.

### Modified Capabilities

<!-- No existing specs. -->

## Impact

- `docker/opencode/Dockerfile`, `Makefile`, `.dockerignore`, `run.sh`; remove `Dockerfile.new`.
- New `docker/opencode/stack/` for compose, Squid, LiteLLM and the lease broker.
- New `docker/opencode/config/` for system `opencode.jsonc` and plugins.
- New host-side lease CLI and SOPS/age wrapper.
- New tests for network bypass, broker leases, token refresh/revocation, image hardening and plugin guardrails.
- New docs and diagrams; existing `docs/opencode-sandboxing.html` remains the audit/options page and links to the implementation SPA.
- Host browser-control relays are no longer reachable from the agent by default; a narrow proxy route or in-stack relay is a follow-up decision.
- `deploy.sh` continues to install OpenCode config and agents; no change to Claude Code dotfiles.
- Local-only and free: no hosted secret manager, paid sandbox or cloud broker is introduced.
