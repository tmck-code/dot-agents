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
| Base | `debian:bookworm-slim` |

It runs as a non-root `agent` user built with your host UID/GID.

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

| Host | Container | Notes |
|---|---|---|
| repo root (git root of `$PWD`) | same absolute path | read-write; also the workdir |
| `git rev-parse --git-common-dir` (worktrees) | same absolute path | read-write; only when outside the repo |
| main working tree (linked worktrees) | same absolute path | read-only; keeps `~/.claude` symlinks resolving |
| `${CLAUDE_CONFIG_DIR:-~/.claude}` | `/home/agent/.claude` | read-write; skills, commands |
| `~/.agents` (if present) | `/home/agent/.agents` | read-write; OpenCode skills |
| `${XDG_CONFIG_HOME:-~/.config}/opencode` | `/home/agent/.config/opencode` | read-write; config |
| `${XDG_DATA_HOME:-~/.local/share}/opencode` | `/home/agent/.local/share/opencode` | read-write; auth, sessions, db |
| `${XDG_STATE_HOME:-~/.local/state}/opencode` | `/home/agent/.local/state/opencode` | read-write |
| `${XDG_CACHE_HOME:-~/.cache}/opencode` | `/home/agent/.cache/opencode` | read-write |
| `~/.gitconfig` (if present) | `/home/agent/.gitconfig` | read-only |
| `$SSH_AUTH_SOCK` (Linux) | `/ssh-agent` | socket, for git over SSH |

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

## Auth and networking

- API keys set on the host are forwarded: `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`,
  `GEMINI_API_KEY`, `GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`,
  `DEEPSEEK_API_KEY`, `GITHUB_TOKEN`. Add more exported names with
  `OPENCODE_ENV_PASSTHROUGH="MY_KEY OTHER_KEY"`.
- Prefer `opencode auth login` on the host. An OAuth login started *inside*
  the container opens a host browser but the callback listener lives in the
  container, so the redirect will not complete; API keys avoid this.
- Host MCP servers are reachable at `host.docker.internal`; `run.sh` adds the
  Linux `host-gateway` mapping and Docker Desktop provides it on macOS.
- The SSH agent is forwarded on Linux only. On macOS the agent socket lives in
  the host session and is not visible to Docker Desktop without a separate
  socket forwarder (for example ssh-agent over TCP).

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
| `PYTHON_VERSION` | `3.13` | uv-managed CPython |
| `UID` / `GID` | host `id -u` / `id -g` | local container user |
| `PUBLISH_UID` / `PUBLISH_GID` | `1000` / `1000` | user baked into published multi-arch images |
| `IMAGE` | `opencode-dev:local` | local tag (`make`) |

```
make build OPENCODE_VERSION=2.1.5 PYTHON_VERSION=3.12
```

## Security

- The repo is mounted **read-write** and the agent can run arbitrary commands
  in it.
- Your Claude/OpenCode config, credentials (`auth.json`), sessions, and
  `~/.gitconfig` are mounted. Do not run this on untrusted repos unless you
  accept that exposure.
- Provider keys passed with `--env` are visible to the container process and
  to anything it runs. Prefer host-side `opencode auth login`.
