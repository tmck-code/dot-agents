# OpenCode dev image

A Debian bookworm image for running [OpenCode](https://opencode.ai) v2 against
a bind-mounted repo, with the tooling agents expect: git, a full C toolchain,
Node.js/npm, and Python managed by uv.

| Component | Version |
|---|---|
| OpenCode | 2.1.4 (official v2 installer) |
| Node.js / npm | 24.22.1 / 11.19.1 (bundled) |
| Python | 3.13 (uv-managed, no system Python) |
| uv | 0.13.5 |
| git / gh / git-lfs | 2.39 / 2.103 / 3.3 (Debian + GitHub apt repo) |
| Base | `debian:bookworm-slim` |

It runs as a non-root `agent` user built with your host UID/GID.

## Safe mode is the default

`run.sh` now starts the agent on an internal-only Docker network with a local
security stack around it:

- **Image**: non-root `agent`, digest-pinned bases, no `sudo`, no embedded
  secrets, read-only system policy at `/etc/opencode/opencode.jsonc`.
- **Launcher**: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, PID,
  memory, CPU and file-descriptor limits. Host config is mounted read-only;
  state and caches use dedicated volumes. No `~/.ssh`, no `~/.config/gh`, no
  `host.docker.internal`, no provider root keys.
- **Network**: only `opencode-agent` (`internal: true`). Squid is the only
  generic egress path, with a default-deny allowlist. LiteLLM is the only model
  path; the lease broker is the only GitHub credential path.
- **Credentials**: approve a scoped, expiring lease on the host. The agent gets
  a random lease token, short-lived GitHub App installation tokens and a
  per-lease LiteLLM virtual key.
- **Guardrails**: system policy outranks project config; guard and audit plugins
  block protected paths, dangerous commands and external directories, and write
  redacted JSONL.

See [Secure stack](#secure-stack) for setup and [Legacy baseline](#legacy-baseline)
for the behaviour `--unsafe` restores.

## Why not the official image?

`ghcr.io/anomalyco/opencode:2.1.4` is Alpine, runs as root, and ships only the
OpenCode binary — no git, Node.js, Python, or shell toolchain. That is fine for
running OpenCode itself, but not for a development environment where agents run
builds, tests, and package installs. This image starts from Debian slim instead
and adds the toolchain, while still installing OpenCode from the official v2
installer (not npm, which would pull ~916 MB of every platform's binary).

## Build and run

From this directory:

```
make build          # native build for this host, loaded locally
make test           # toolchain + uv venv smoke test
make run            # OpenCode TUI
make shell          # bash
make build-multi PUSH_IMAGE=registry.example.com/you/opencode-dev:2.1.4
```

`run.sh` is the real entry point and can be used from any repo:

```
cd ~/dev/some-project
/path/to/dot-agents/docker/opencode/run.sh
/path/to/dot-agents/docker/opencode/run.sh --shell
/path/to/dot-agents/docker/opencode/run.sh run "summarise the test layout"
/path/to/dot-agents/docker/opencode/run.sh --continue
```

Any argument other than `--shell` is passed to the `opencode` entrypoint, so
`run`, `auth`, `debug paths`, `--continue`, etc. behave as normal. With no
arguments it opens the TUI.

`make run` targets the git repo containing this directory (via
`git rev-parse --show-toplevel`). `run.sh` targets the git root of the caller's
`$PWD` (or `$PWD` itself outside git), so running it from a subdirectory still
mounts the whole repo. Override either with `REPO_ROOT=/path`.

### First run

1. `make build` with your host UID/GID.
2. Authenticate on the **host** with `opencode auth login`. The bind mount
   shares `~/.local/share/opencode/auth.json`, so the container is logged in.
3. `make run`, or `run.sh` from the repo you want to work on.

## Mounts

The table below is the **legacy** mount set used by `--unsafe` (and partly by
`--with-ssh` / `--with-gh`). Safe mode is described under
[Secure stack](#secure-stack): config is read-only, state/cache are named
volumes, and host credential directories are absent by default.

| Host | Container | Notes |
|---|---|---|
| repo root (git root of `$PWD`) | same absolute path | read-write; also the workdir |
| `git rev-parse --git-common-dir` (worktrees) | same absolute path | read-write; only when outside the repo |
| main working tree (linked worktrees) | same absolute path | read-only; keeps `~/.claude` symlinks resolving |
| `${CLAUDE_CONFIG_DIR:-~/.claude}` | `/home/agent/.claude` | read-write; skills, commands |
| `~/.agents` (if present) | `/home/agent/.agents` | read-write; OpenCode skills |
| `${XDG_CONFIG_HOME:-~/.config}/opencode` | `/home/agent/.config/opencode` | read-write; config, including `cli.json` |
| local plugin dirs listed in `cli.json` | same absolute path | read-only; keeps absolute `plugins` entries resolvable |
| `${XDG_DATA_HOME:-~/.local/share}/opencode` | `/home/agent/.local/share/opencode` | read-write; auth, sessions, db |
| `${XDG_STATE_HOME:-~/.local/state}/opencode` | `/home/agent/.local/state/opencode` | read-write |
| `${XDG_CACHE_HOME:-~/.cache}/opencode` | `/home/agent/.cache/opencode` | read-write |
| `~/.gitconfig` (if present) | `/home/agent/.gitconfig` | read-only |
| `~/.config/gh` (if present) | `/home/agent/.config/gh` | read-only; host `gh auth login` |
| `~/.ssh` (if present) | `/home/agent/.ssh` | read-only; keys, `config`, `known_hosts` |
| `$SSH_AUTH_SOCK` (Linux, when running) | `/ssh-agent` | socket, for git over SSH |

`CLAUDE_CONFIG_DIR` is set to `/home/agent/.claude` inside the container. A host
`OPENCODE_CONFIG_DIR` is deliberately not forwarded, so OpenCode uses its
default container config dir. Host dirs are created before Docker starts, so
they keep your ownership rather than becoming root-owned. Mounting the repo at
its host path also keeps the absolute symlinks `deploy.sh` creates under
`~/.claude` resolving inside the container.

In a linked worktree, git keeps metadata under the main repo's
`.git/worktrees/<name>`, outside the worktree root. `run.sh` resolves
`git rev-parse --git-common-dir` and mounts it read-write when it is outside the
repo mount, so `git status`, commits, and hooks work in the container. It also
mounts the main working tree read-only, so absolute `~/.claude` symlinks into
the main checkout resolve while writes to it stay blocked.

## Git and GitHub

Git is preconfigured for bind-mounted repos (`safe.directory=*`), and
`~/.gitconfig` is mounted read-only so your name, email, aliases and colour
settings apply inside the container. `git-lfs` is installed and registered
system-wide, so repos that use LFS (and the `filter.lfs.*` config in the
mounted `~/.gitconfig`) clone and check out normally.

SSH remotes work in two ways, and you get both when they are available:

- `~/.ssh` is mounted read-only at `/home/agent/.ssh`, so `IdentityFile`
  paths in `~/.ssh/config` and git's default `id_*` lookup resolve. This works
  even when no agent is running on the host.
- `$SSH_AUTH_SOCK` is forwarded on Linux when an agent is running, which covers
  passphrase-protected keys already unlocked in the agent. On macOS the agent
  socket lives in the host session and is not visible to Docker Desktop without
  a separate socket forwarder; key-file auth via the mount still works.

`known_hosts` is read-only, so a host that is not already known must be trusted
on the host first, e.g. `ssh-keyscan github.com >> ~/.ssh/known_hosts`.

For HTTPS remotes, `gh` is git's credential helper (injected as command-scope
config via `GIT_CONFIG_*`, not written to the read-only `~/.gitconfig`), so
`git fetch`/`push` reuse the host login:

```
./run.sh --shell -lc 'git push'
```

That helper also overrides any host credential helper (`osxkeychain`,
`libsecret`, `store`) that does not exist in the image.

`~/.config/gh` is bind-mounted read-only, so `gh auth status`, `gh pr`, `gh
issue`, `gh api` and `gh repo` behave as they do on the host — no login step
inside the container. Mutating commands (`gh auth switch`, `gh auth refresh`,
`gh auth logout`, `gh config set`) have to be run on the host, since the mount
cannot be written. gh stores the OAuth token in `hosts.yml`; if a host keeps it
in a system keyring instead, export `GITHUB_TOKEN` (or `GH_TOKEN`) in the shell
that runs `run.sh` and `gh`/git will use that instead.

## Statusline (local TUI plugins)

OpenCode v2 has no `statusLine` command like Claude Code. A custom statusline is
a TUI plugin registered by path in `~/.config/opencode/cli.json`:

```jsonc
{
  "plugins": [
    "/home/you/dev/yet-another-statusline/.scratch/feat-opencode-statusline/yas-lite"
  ]
}
```

That path is absolute, so it does not exist in the container by default.
`run.sh` reads `cli.json` (or `cli.jsonc`) and, for every absolute entry that is
a host directory, bind-mounts it read-only at the same path. Bare package names
(`"some-plugin"`) are left to OpenCode's in-container install. Entries already
covered by the repo, `~/.claude` or the config mount are skipped. Parsing needs
`jq` on the host; without it `run.sh` prints a warning and skips local plugin
mounts.

A local plugin keeps its own `node_modules` (OpenCode transpiles the TSX and
resolves the host's peer dependencies), so mount the checkout directory, not
just `tui.tsx`. To confirm the container resolves it:

```
./run.sh --shell -lc 'opencode plugin list'
```

The image must run the same OpenCode major version the plugin targets (the
default is v2.1.4). A plugin that writes into its own directory will fail
because the mount is read-only.

## Auth and networking (legacy)

This section describes `--unsafe`. In safe mode no provider root key or
long-lived GitHub token is forwarded; model calls use a LiteLLM virtual key and
git/gh use a lease token.

- API keys set on the host are forwarded: `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`,
  `GEMINI_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`,
  `DEEPSEEK_API_KEY`, `GITHUB_TOKEN`, `GH_TOKEN`, `GH_HOST`. Add more exported
  names with `OPENCODE_ENV_PASSTHROUGH="MY_KEY OTHER_KEY"`.
- Prefer `opencode auth login` on the host. An OAuth login started *inside*
  the container opens a host browser but the callback listener lives in the
  container, so the redirect will not complete; API keys avoid this.
- Host MCP servers are reachable at `host.docker.internal`; `run.sh` adds the
  Linux `host-gateway` mapping and Docker Desktop provides it on macOS.
- See [Git and GitHub](#git-and-github) for SSH keys, the SSH agent and token
  auth for `git`/`gh`.

## Multi-arch

The Dockerfile is architecture-neutral: the OpenCode installer selects
`linux-x64` or `linux-arm64`, and Node, uv, and the Debian base are multi-arch.

- Apple Silicon runs `linux/arm64`. `make build` detects the host architecture;
  a native build on the target machine is the recommended path and needs no
  emulation.
- One manifest for both:

  ```
  make build-multi PUSH_IMAGE=registry.example.com/you/opencode-dev:2.1.4
  ```

  This pushes `linux/amd64` and `linux/arm64`. A multi-arch manifest cannot be
  `--load`ed into the local image store, which is why it pushes. Use a registry
  the target machines can pull from.
- Published images use UID/GID `1000:1000` regardless of the build host, so the
  manifest is reproducible. Override with `PUBLISH_UID=` / `PUBLISH_GID=`.
- A cross-arch build needs QEMU/binfmt; without it the foreign stage fails at
  its first `RUN`. Building natively on each architecture avoids that.

## UID/GID

The image runs as `agent` with the UID/GID passed at build time. `run.sh` warns
when they differ from the host. Rebuild after a UID change:

```
make clean && make build
```

`GID=20` (macOS `staff`) is handled: Debian already uses 20 for `dialout`, so
the build reuses that group name instead of failing. A UID that already exists
in the image is a build error; pass another free `UID=`.

Published multi-arch images deliberately use `1000:1000` (`PUBLISH_UID` /
`PUBLISH_GID`), not the builder's ID. Build locally to match any other host UID.

## Build args

| Arg | Default | Purpose |
|---|---|---|
| `OPENCODE_VERSION` | `2.1.4` | OpenCode release |
| `OPENCODE_SHA256` | empty | Optional SHA-256 of the OpenCode binary; set it in CI/releases for a fully verified download |
| `PYTHON_VERSION` | `3.13` | uv-managed CPython |
| `UID` / `GID` | host `id -u` / `id -g` | local container user |
| `PUBLISH_UID` / `PUBLISH_GID` | `1000` / `1000` | user baked into published multi-arch images |
| `IMAGE` | `opencode-dev:local` | local tag (`make`) |

```
make build OPENCODE_VERSION=2.1.5 PYTHON_VERSION=3.12
```

## Secure stack

### Topology

```
host ── 127.0.0.1:8081 ── broker-admin (no internal network)
                              │   shared SQLite state
host ── docker compose ── broker (opencode-agent + opencode-egress)
                              │
                         opencode-agent (internal: true)
                         ├── agent        (this launcher)
                         ├── squid        (dual-homed)
                         ├── litellm      (dual-homed)
                         └── broker       (dual-homed)
                              │
                         opencode-egress (bridge, outbound only)

                         opencode-data (internal: true)
                         ├── postgres     (LiteLLM key/spend state)
                         ├── llama        (optional profile; only LiteLLM reaches it)
                         └── litellm
```

Only Squid, LiteLLM and the broker join `opencode-egress`. The agent has no
default route, no host gateway and no default bridge. Postgres and the optional
llama.cpp runtime are on a separate internal network reachable only by LiteLLM.
Squid sees destinations, not bodies or headers. It does not terminate TLS, so
no custom CA is installed in the agent.

### First run

```bash
# 1. Build the image (digest-pinned bases; no secrets in the context).
make build

# 2. Resolve host-side secrets (SOPS+age or KeePassXC; see below).
./scripts/opencode-secrets.sh --source sops --file secrets.enc.yaml \
    --keys GITHUB_APP_ID,LITELLM_MASTER_KEY,BROKER_ADMIN_TOKEN,ANTHROPIC_API_KEY

# 3. Start the stack.
docker compose -f stack/docker-compose.yml \
    --env-file stack/secrets/stack.env up -d

# 4. Approve a scoped lease (writes ~/.local/state/opencode/lease-token, 0600).
./bin/lease approve --session "$USER" --service all \
    --repo owner/repo --model claude-sonnet --ttl 8h

# 5. Run the agent. It fails closed if the stack or lease is missing.
./run.sh
```

`./bin/lease list` shows active leases with scope and expiry. `./bin/lease
revoke <lease_id>` stops new GitHub token mints and deletes the LiteLLM virtual
key; an already-issued installation token remains valid until GitHub expires it.

### Launcher flags

| Flag | Effect |
|---|---|
| (none) | Safe mode: internal network, dropped capabilities, resource limits, read-only host config, scoped git config, lease credentials |
| `--shell` | bash in the same hardened container |
| `--read-only` | Read-only rootfs plus tmpfs `/tmp`, `/run` and named writable volumes for home/caches |
| `--with-ssh` | Mount `~/.ssh` read-only and forward `SSH_AUTH_SOCK` on Linux (warns) |
| `--with-gh` | Mount `~/.config/gh` read-only (warns) |
| `--unsafe` | Legacy behaviour: default bridge, host gateway, SSH/gh mounts, token passthrough, no capability/resource defaults (warns) |

Safe mode fails closed when `opencode-squid`, `opencode-broker` or
`opencode-litellm` is not healthy, or when no lease token exists. `--unsafe`
skips those checks by design; it is for one trusted debugging session, not a
daily default.

### Resource limits

Override with environment variables when a build legitimately needs more:
`OPENCODE_PIDS_LIMIT` (2048), `OPENCODE_MEMORY` (`8g`), `OPENCODE_CPUS` (`4`).
The file-descriptor limit is `1024:4096`.

### Git, gh and leases

In safe mode git uses `git-credential-lease` (installed in the image) through
`GIT_CONFIG_*` scoped config, and `gh` is a wrapper that fetches a lease token
and execs the real binary. Both fail closed when the broker is unavailable. No
host `~/.ssh` or `~/.config/gh` is mounted.

The broker mints GitHub App installation tokens scoped to the lease's
repositories and actions, caches them in SQLite, and refreshes them while the
lease is active. The App private key stays in the broker container's read-only
secret mount. A leaked installation token expires on GitHub's schedule; after
revocation the broker refuses to mint a replacement.

### Model providers

OpenCode provider config points at `http://litellm:4000/v1` and uses
`LITELLM_API_KEY`, a per-lease virtual key. Provider root keys are read at
LiteLLM startup from the read-only mount `/run/secrets/litellm.env` (written by
`scripts/opencode-secrets.sh`, mode 0600) and live only in that container's
environment. Add
providers in `stack/litellm.yaml` and keep the aliases in
`config/opencode.jsonc` in sync. A revoked lease deletes the virtual key, so
LiteLLM rejects further calls with it.

### Local model (llama.cpp)

The stack can serve a local Qwen3.5 4B through llama.cpp without giving the
agent another route. The `llama` service is profile-gated and attached only to
`opencode-data`; only LiteLLM can reach `http://llama:8080/v1`.

The model is off by default, so the base stack continues to start without a
GGUF or a GPU. The quickest path is one command:

```bash
cd ~/dev/dot-agents/docker/opencode
make llama-up
```

`make llama-up` resolves the existing Ollama `qwen3.5:4b` blob, auto-detects an
NVIDIA GPU (use `LLAMA_GPU=0 make llama-up` for CPU), starts the profile, waits
for health, and approves a `qwen-local` lease using the admin token from
`stack/secrets/stack.env` or `LEASE_ADMIN_TOKEN`.

On first use it creates `stack/secrets/stack.env` (mode 0600) with a generated
`BROKER_ADMIN_TOKEN` and `LITELLM_MASTER_KEY` when they are missing. This is why
`make llama-up` works without a separate secrets setup; LiteLLM refuses an
empty master key by design. Reuse the same file for subsequent starts, or run
`scripts/opencode-secrets.sh` if you keep secrets in SOPS/KeePassXC.

Useful lifecycle commands:

```bash
make llama-status      # container, health, context and GPU memory
make llama-logs        # follow llama.cpp logs
make llama-lease       # approve another qwen-local lease
make llama-down        # stop only llama; leave the rest of the stack running
```

The same workflow is available directly:

```bash
./stack/llama.sh up                 # start + approve a lease
./stack/llama.sh up --no-lease      # start only
./stack/llama.sh lease              # approve another lease
./stack/llama.sh status
./stack/llama.sh logs
./stack/llama.sh down
```

Manual alternatives, if you want to control the compose invocation:

```bash
eval "$(./stack/llama-model.sh --export)"     # qwen3.5:4b model.gguf blob
./stack/llama-model.sh --projector            # optional, vision follow-up

# GPU host (RTX 3070 Ti; ~5.2 GB at 64K):
docker compose -f stack/docker-compose.yml \
  -f stack/docker-compose.llama-gpu.yml \
  --profile llama up -d --wait

# CPU-only host:
docker compose -f stack/docker-compose.yml --profile llama up -d --wait
```

A standalone GGUF works the same way:

```bash
export LLAMA_MODEL_PATH=/path/to/qwen3.5-4b.Q4_K_M.gguf
make llama-up
```

`stack/models/` and `*.gguf` are git-ignored. The default path is
`stack/models/model.gguf`; it is only read when the `llama` profile is enabled.

| Variable | Default | Meaning |
|---|---|---|
| `LLAMA_MODEL_PATH` | `./models/model.gguf` | Read-only GGUF mount |
| `LLAMA_CTX_SIZE` | `65536` | Context per slot; set `32768` for the old Ollama-sized fallback |
| `LLAMA_N_GPU_LAYERS` | `0` base, `99` GPU override | Layers offloaded to the GPU |
| `LLAMA_UID` / `LLAMA_GID` | `1000` / `1000` | Container user; must be able to read the GGUF |
| `LLAMA_MEMORY` | `6g` | Container memory limit |
| `LLAMA_PIDS_LIMIT` | `512` | Container PID limit |
| `LLAMA_API_KEY` | `sk-llama-local` | Shared key between llama.cpp and LiteLLM; never given to the agent |

The runtime uses one slot (`--parallel 1`), flash attention, `q8_0` KV cache and
the model's Jinja template, which keeps tool calls working. Thinking stays on by
default; a request can pass `chat_template_kwargs: {enable_thinking: false}` to
suppress it for that call.

`make llama-up` already approves a model-only lease. To approve another one
manually:

```bash
./bin/lease approve --session "$USER-local" --service litellm \
  --model qwen-local --ttl 1h

# inside OpenCode
/model litellm/qwen-local
```

`litellm/claude-sonnet` remains the default. The local model is opt-in.

**Rollback:** select `/model litellm/claude-sonnet`, revoke the `qwen-local`
lease, then stop the optional service:

```bash
./bin/lease revoke <lease_id>
make llama-down
```

Cloud aliases keep working without restarting LiteLLM. The profile can be left
stopped indefinitely.

### Squid limitations

Squid is a destination allowlist, not an authorisation system:

- It cannot enforce HTTP methods or paths.
- It cannot inject headers; that is why LiteLLM and the broker exist.
- It does not terminate TLS, so it sees `CONNECT host:443` only.
- An allowed domain can still be an exfiltration channel. Scope the allowlist
  to what the project needs.

Provider authentication is handled by LiteLLM; git and cloud token injection is
handled by the lease broker or credential helper. Do not add a TLS-intercepting
proxy unless a concrete method/path rule requires it.

### System policy and plugins

`/etc/opencode/opencode.jsonc` is baked into the image, owned by root, mode
0444, and loaded at the highest precedence. It denies every provider except the
local LiteLLM proxy, denies `sudo`/`su`/mount/docker/namespace escape commands,
denies unapproved project plugins and MCP servers, and denies reads of `.env*`,
`.ssh`, key files, `auth.json`, vault files and paths outside the workspace.

The guard plugin (`ctx.permission.hook("evaluate")`,
`ctx.tool.hook("execute.before")`, `ctx.shell.hook("create.before")`) enforces
the same rules at tool level, injects proxy variables and refuses to upgrade an
explicit deny. The audit plugin writes redacted JSONL to
`/var/log/opencode/audit.jsonl` (named volume). The lease plugin refreshes the
LiteLLM virtual key while the lease is active.

The agent can write to its audit volume, so plugin audit is a convenience. The
Squid access log (`opencode-squid-logs` volume) and the broker's issuance events
are the authoritative records. Neither logs request bodies, headers or token
values.

### Secrets

Use SOPS+age as the primary store or a dedicated KeePassXC database as an
alternative. `scripts/opencode-secrets.sh` decrypts only the named values:

```bash
# SOPS+age
./scripts/opencode-secrets.sh --source sops --file secrets.enc.yaml \
    --keys GITHUB_APP_ID,GITHUB_INSTALLATION_ID,BROKER_ADMIN_TOKEN,LITELLM_MASTER_KEY,ANTHROPIC_API_KEY

# KeePassXC: map env names to entry paths; the password is read from
# KEEPASSXC_PASSWORD or prompted on the terminal.
KEEPASSXC_PASSWORD=... ./scripts/opencode-secrets.sh --source keepassxc \
    --db ~/vaults/opencode.kdbx \
    --entry GITHUB_APP_ID=github/app-id \
    --entry ANTHROPIC_API_KEY=providers/anthropic
```

It writes `stack/secrets/stack.env` and `stack/secrets/litellm.env` (directory
0700, files 0600, git-ignored). Keep the age key at
`~/.config/sops/age/keys.txt` (mode 0600) and keep an offline backup: without it
the encrypted file cannot be recovered.

For KeePassXC, the wrapper uses `keepassxc-cli show -q -a password <db>
<entry>`. The KDBX file and its password never go into the image or the agent
container, and only the resolved values land in the host-side env files. Never
mount the KDBX, the age key or the decrypted files into the agent.

A pre-commit scan (`.githooks/pre-commit` → `scripts/secret-scan.sh`) runs
`gitleaks protect --staged` when available and otherwise a built-in staged-file
scanner. Bypass a reviewed false positive with `SKIP_SECRET_SCAN=1`.

### Rollback

The stack is additive. To return to the legacy runtime:

```bash
./run.sh --unsafe
```

To use the previous image tag, set `IMAGE=<old-tag>` and run with `--unsafe`.
`docker compose -f stack/docker-compose.yml down` stops the stack; named volumes
(`opencode-broker-state`, `opencode-squid-logs`, `opencode-litellm-db` and the optional model volumes) are
left intact. The host `~/.config/opencode` and `~/.claude` are never modified by
the secure stack.

### Scope and limits

- **Trusted repositories.** This is a boundary for a capable agent that may make
  mistakes, not a sandbox for hostile code. Project plugins, skills and
  `AGENTS.md` can still influence the agent; system policy denies project
  plugins and MCP by default, but review what you approve.
- **Shared kernel.** Docker containers share the host kernel. A kernel exploit
  or a Docker escape defeats this design. Keep Docker patched, prefer rootless
  Docker, and use a microVM or cloud sandbox for untrusted repos or unattended
  autonomy.
- **`--unsafe` trade-off.** It restores host credential mounts, the host gateway
  and token passthrough, and drops capability/resource defaults. It prints a
  warning for a reason: treat it as a one-off debugging tool.
- **Host browser relays.** A relay bound to host loopback is unreachable from
  the internal agent network. If browser automation is required, expose only
  that relay through a narrow proxy route or run it inside the stack; do not
  restore general host access.
- **Auto mode.** `--auto` only suppresses prompts. It does not relax a system
  deny, and is only appropriate inside the hardened container.

## Legacy baseline

The pre-hardening image and launcher (restored by `--unsafe`, except where a
flag narrows it) behaved as follows:

- Single `opencode-dev` target, `debian:bookworm-slim`, OpenCode 2.1.4 from the
  official installer, Node 24.22.1, uv-managed Python 3.13, git, gh, git-lfs.
- Non-root `agent` user, but `git config --system safe.directory '*'`, no
  capability drop, no resource limits, no `no-new-privileges`.
- `run.sh` used the default Docker bridge, optionally added
  `host.docker.internal:host-gateway` on Linux, and forwarded an SSH agent.
- `~/.claude`, `~/.config/opencode`, data/state/cache, `~/.gitconfig`,
  `~/.config/gh` and `~/.ssh` were bind-mounted; config/state were read-write.
- Provider API keys, `GITHUB_TOKEN` and `GH_TOKEN` were passed with `--env`.
- Git used `gh auth git-credential`; `gh` read the mounted host config.
- Egress was unrestricted; the agent could reach the host LAN and the open
  internet.

`docker/opencode/test/legacy-smoke.sh` pins the toolchain contract for that
baseline. `docker/opencode/Dockerfile.new` was removed; the pre-commit hook
fails if it reappears.
