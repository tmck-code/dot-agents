## 1. Baseline and safety net

- [x] 1.1 Record the current image, `run.sh`, and mount/network behaviour in `docker/opencode/README.md` as the legacy baseline.
- [x] 1.2 Add `docker/opencode/test/legacy-smoke.sh` that builds the image, starts a shell, and verifies OpenCode, Python, Node, git, gh and git-lfs versions.
- [x] 1.3 Add a `--unsafe` path to the launcher before changing defaults, so the legacy behaviour remains available.
- [x] 1.4 Add `.dockerignore` entries for `.git`, `.scratch`, `.env*`, `*.kdbx`, `auth.json`, host state and `docs/`.
- [x] 1.5 Remove `docker/opencode/Dockerfile.new` and add a pre-commit/docs check that fails if it reappears.

## 2. Image hardening

- [x] 2.1 Pin `debian:bookworm-slim`, `node:*-bookworm-slim` and the uv image by digest in `docker/opencode/Dockerfile`.
- [x] 2.2 Replace the `curl | bash` OpenCode install with a download plus checksum/signature verification, or document why the official installer is the verified path.
- [x] 2.3 Add `/etc/opencode/opencode.jsonc` to the image, owned by root and read-only, with the system policy baseline.
- [x] 2.4 Add `/etc/opencode/plugins/` to the image and set it read-only.
- [x] 2.5 Replace `git config --system safe.directory '*'` with a scoped runtime `GIT_CONFIG_*` setting for the mounted repo.
- [x] 2.6 Add OCI labels and SBOM/provenance flags to `docker/opencode/Makefile`; keep multi-arch builds working.
- [x] 2.7 Add an image test that asserts non-root user, no `sudo`, no embedded secrets, no host SSH keys, and a read-only system policy.

## 3. Launcher and network boundary

- [x] 3.1 Update `docker/opencode/run.sh` to default to `--cap-drop=ALL --security-opt=no-new-privileges --init --pids-limit=2048 --memory=8g --cpus=4 --ulimit nofile=1024:4096`.
- [x] 3.2 Remove default `~/.ssh`, `~/.config/gh`, `host.docker.internal`, and SSH-agent forwarding; add `--with-ssh`, `--with-gh`, and `--unsafe` flags.
- [x] 3.3 Mount `~/.claude`, OpenCode config and plugin directories read-only; keep the repo read-write and state/cache in dedicated volumes.
- [x] 3.4 Create the `opencode-agent` internal network and `opencode-egress` bridge in a new `docker/opencode/stack/docker-compose.yml`; attach only the agent to the internal network.
- [x] 3.5 Set `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `BROKER_URL` and `LEASE_TOKEN` in the agent container; fail closed if the stack health checks fail.
- [x] 3.6 Add `--read-only` support with `--tmpfs /tmp`, `--tmpfs /run`, and named writable volumes for the agent home and caches; keep it opt-in.
- [x] 3.7 Preserve linked-worktree mounts and add a worktree smoke test.

## 4. Egress proxy

- [x] 4.1 Add `docker/opencode/stack/squid.conf` with default-deny rules and an allowlist for the selected providers, GitHub, npm and PyPI.
- [x] 4.2 Add the Squid service to the compose stack, dual-homed on `opencode-agent` and `opencode-egress`, with no published ports and a read-only config mount.
- [x] 4.3 Add a proxy log volume and ensure bodies and Authorization values are not logged.
- [x] 4.4 Add `docker/opencode/test/egress-bypass.sh` covering direct internet, host LAN, host.docker.internal, allowlisted domain, denied domain and metadata address.
- [x] 4.5 Document that Squid cannot enforce HTTP method/path and that LiteLLM/broker handle service auth.

## 5. Lease broker and GitHub App

- [x] 5.1 Scaffold `docker/opencode/broker/` as a small FastAPI service with SQLite state, a read-only rootfs in compose, and a dedicated state volume.
- [x] 5.2 Implement lease creation, listing, expiry and revocation with `lease_id`, session, service, resource, actions, expiry and status.
- [x] 5.3 Implement a host-only admin listener/port and a separate agent-facing token endpoint; never expose admin on the internal network.
- [x] 5.4 Implement GitHub App JWT signing and installation-token minting with repo and permission scoping; read the private key from a mounted host secret.
- [x] 5.5 Add token caching and refresh until the lease expires; return `403` after revocation and `401` for missing/invalid lease tokens.
- [x] 5.6 Add `docker/opencode/bin/lease` (approve/list/revoke) and a `git` credential-helper/`GIT_ASKPASS` wrapper that fetches tokens at call time.
- [x] 5.7 Add a `gh` wrapper that uses the lease token instead of `~/.config/gh`.
- [x] 5.8 Add pytest coverage for scope, expiry, revocation, missing token, malformed token, refresh and no-secret-in-logs.

## 6. LiteLLM provider proxy

- [x] 6.1 Add `docker/opencode/stack/litellm.yaml` with the selected providers and local model aliases.
- [x] 6.2 Add the LiteLLM service to the compose stack on the internal and egress networks, with no published port and provider keys from a read-only secret mount.
- [x] 6.3 Add broker-issued per-lease virtual keys with model allowlist, budget and duration.
- [x] 6.4 Point the OpenCode provider config at `http://litellm:4000` and remove provider root keys from the agent environment.
- [x] 6.5 Add a test that a revoked/expired virtual key is rejected and a provider key never appears in the agent.

## 7. OpenCode policy and plugins

- [x] 7.1 Author `docker/opencode/config/opencode.jsonc` with system `policies` for providers, `tool.use` and `integration.use`.
- [x] 7.2 Add permission rules denying `.env*`, `.ssh`, key files, `auth.json`, vault files and external directories.
- [x] 7.3 Add `docker/opencode/config/plugins/guard.ts` using `permission.evaluate`, `tool.execute.before` and `shell.create.before`; inject proxy env and block protected paths.
- [x] 7.4 Add `docker/opencode/config/plugins/audit.ts` writing redacted JSONL to `/var/log/opencode/audit.jsonl`.
- [x] 7.5 Add `docker/opencode/config/plugins/lease.ts` for lease lookup and refresh on expiry.
- [x] 7.6 Wire the plugin directory and log volume into the image/compose and document that proxy/broker logs are authoritative.
- [x] 7.7 Add tests for protected-path denial, external-directory denial, explicit-deny finality, proxy env injection and audit redaction.

## 8. Local secret workflow

- [x] 8.1 Add `scripts/opencode-secrets.sh` supporting SOPS+age and a dedicated KeePassXC DB, resolving only named values into the host stack.
- [x] 8.2 Add an example `secrets.example.yaml` and document the age key location, permissions and offline backup.
- [x] 8.3 Document the KeePassXC `keepassxc-cli show` wrapper and the never-mount-the-KDBX rule.
- [x] 8.4 Add a pre-commit secret scan (`gitleaks protect --staged` or `detect-secrets`) and verify it blocks a fixture secret.

## 9. Tests and verification

- [x] 9.1 Extend `docker/opencode/test/` with image hardening, launcher default, network bypass, lease and guardrail suites.
- [x] 9.2 Add `docker/opencode/test/stack-smoke.sh` that starts the compose stack, waits for health, runs the agent, and tears down.
- [x] 9.3 Add a test that `docker inspect` and `/proc/<pid>/environ` contain no provider root key, App private key or long-lived PAT.
- [x] 9.4 Add a test that `--unsafe` warns and restores legacy mounts; safe mode remains the default.
- [x] 9.5 Run `openspec validate secure-opencode-runtime --strict` and fix any artifact issues.

## 10. Documentation and SPA

- [x] 10.1 Update `docker/opencode/README.md` with the new architecture, flags, secret workflow, lease model and rollback.
- [x] 10.2 Create `docs/opencode-secure-stack.html` as a single-file SPA using the existing design language.
- [x] 10.3 Add transparent Excalidraw diagrams for topology, request paths, lease lifecycle, defence layers and rollout under `docs/diagrams/`.
- [x] 10.4 Embed the rendered SVGs in the SPA with captions, lightbox and links to `.excalidraw` sources.
- [x] 10.5 Link the existing audit SPA and the new implementation SPA in both directions.
- [x] 10.6 Document the trusted-repo scope, the kernel-isolation limitation and the `--unsafe` trade-off.
