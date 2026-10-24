# dot-agents

Agentic dotfiles: skills, hooks, agents, commands, routing tables and settings
for Claude Code, with OpenCode portability studied in
[docs/opencode-port.md](docs/opencode-port.md).

Everything that used to live under `.claude/` in
[tmck-code/dotfiles](https://github.com/tmck-code/dotfiles) now lives here.

## Layout

```
home/general/.claude/   shared on every machine: CLAUDE.md, agents, commands,
                        hooks, scripts, skills, routing tables, hook docs
home/linux/.claude/     Linux-only: settings.json, hooks/agent-notify.py,
                        scripts/agent-watch.sh
home/osx/.claude/       macOS-only: settings.json
docker/opencode/        OpenCode v2 dev image: Node, uv/Python, git
```

**Rule:** if both machines can use it, it belongs in `home/general/`. Only
genuinely OS- or machine-specific files belong in `home/linux/` or
`home/osx/`. The pre-commit hook rejects shared files that reappear per OS.

`home/<os>/.claude/<path>` is symlinked to `$CLAUDE_CONFIG_DIR/<path>`
(default `~/.claude/<path>`).

## Install

```
./deploy.sh linux
./deploy.sh osx
CLAUDE_CONFIG_DIR=~/.claude.personal ./deploy.sh osx
```

`deploy.sh` installs `home/general` first, then the selected OS. It skips
`__pycache__`, `.pytest_cache`, `.ruff_cache` and `.scratch`, and removes stale
symlinks that point into this repo but no longer resolve. If a managed directory
(`agents`, `commands`, `hooks`, `scripts`, `skills`) is itself a symlink into
this repo, it replaces it with a real directory before linking the files. It
also sets `core.hooksPath` to `.githooks`.

## Docker (OpenCode)

`docker/opencode/` builds a Debian bookworm image for running OpenCode v2
against a bind-mounted repo. It includes Node.js/npm, a uv-managed Python, git
and a C toolchain, and runs as a non-root user built with your host UID/GID.

The official `ghcr.io/anomalyco/opencode` image is multi-arch, but it is Alpine
and ships only the OpenCode binary — no git, Node.js or Python. This image keeps
the official v2 installer (rather than npm, which pulls every platform's
binary) and adds the development toolchain around it.

```
cd docker/opencode
make build          # native build for this host, loaded locally
make test           # toolchain + uv venv smoke test
make run            # OpenCode TUI in this repo
make shell          # bash with the same mounts
```

From any repo:

```
/path/to/dot-agents/docker/opencode/run.sh
/path/to/dot-agents/docker/opencode/run.sh --shell
/path/to/dot-agents/docker/opencode/run.sh run "summarise this repo"
```

It bind-mounts the repo at the same absolute path, plus `~/.claude` (or
`$CLAUDE_CONFIG_DIR`), the OpenCode config/data/state/cache dirs, and
`~/.agents`. Authenticate on the host first (`opencode auth login`) so the
mounted `auth.json` is reused, or pass provider API keys. `make build` builds
for the host architecture; `make build-multi PUSH_IMAGE=...` pushes an
amd64+arm64 manifest. See [docker/opencode/README.md](docker/opencode/README.md)
for the mount table, worktree handling, auth caveats and UID/GID details.

## Hooks

All paths are under `$CLAUDE_CONFIG_DIR`.

| Event | Script | What it does |
|---|---|---|
| `UserPromptSubmit` | `hooks/skill-nudge.py` | Matches the prompt against the global + project `skill-routing.json` and nudges the matching skills. |
| `UserPromptSubmit` | `scripts/yas.sh prompt` | Runs the newest installed yet-another-statusline prompt hook. |
| `PreToolUse` (Bash) | `hooks/ban-host-npm.py` | Blocks host `npm`; dependency mutations are run in Docker via `npm-in-docker.py`. |
| `PreToolUse` (Bash) | `hooks/no-long-sleep.py` | Blocks a foreground `sleep` of 30s or more. |
| `PreToolUse` (Bash) | `hooks/subagent-git-tree-guard.py` | Blocks tree-global git subcommands from subagents in the primary worktree. |
| `PreToolUse` (Bash/Edit/Write/Read/Grep/Glob) | `hooks/nudge-delegate.py` | Applies `delegate-routing.json`: nudges or denies heavy inline work. |
| `PreToolUse` (Agent/Task) | `hooks/subagent-file-handoff.py` | Reminds the parent to create the subagent's report file and to enforce sole-writer. |
| `PostToolUse` (Edit/Write) | `hooks/same-file-write-audit.py` | Warns when the same file is written repeatedly by different agents. |
| `PostToolUse` (Agent/Task/TaskOutput/SendMessage) | `hooks/subagent-report-announce.py` | Announces the path of a captured subagent report. |
| `SubagentStop` | `hooks/subagent-report-capture.py` | Fallback: saves a subagent's final message when it wrote no report file. |
| `SubagentStop` | `hooks/handoff-nudge.py` | Reminds the coordinator that the follow-on work is delegable. |
| `Notification`, `Stop`, `StopFailure` | `hooks/agent-notify.py` (Linux) / `osascript` (macOS) | Desktop notifications. |

`hooks/precompact-probe.py` is tracked but not registered. It is a diagnostic
that logs every `PreCompact` payload to `hooks/state/precompact-log.jsonl`; add
it to `PreCompact` when that data is wanted.

### Report files

The parent creates one file per subagent on its scratch shelf
(`.scratch/<shelf>/<agent>-<task>-<slug>.md`), puts the path in the brief, and
the subagent writes its findings there. The `SubagentStop` capture hook is only
a fallback for a child that writes nothing.

### Routing tables

- `delegate-routing.json` drives `nudge-delegate.py` (`PreToolUse`). It is about
  **tool use**: warn or deny a heavy Bash/Read/Write call. The first table found
  wins, so a project table **replaces** the global one.
- `skill-routing.json` drives `skill-nudge.py` (`UserPromptSubmit`). It is about
  **prompt shape**: match text and name skills to invoke. The global and project
  tables are **unioned**, so generic rules fire everywhere and project rules add
  to them.

Both live in `home/general/`; a repo can add its own `.claude/skill-routing.json`
for project-only skills.

## Tests

```
python3 -m pytest
```

The hook tests live in `test/` and run `nudge-delegate.py` as a subprocess
against a throwaway config/project tree.

## Pre-commit

The hook at `.githooks/pre-commit` fails a commit when:

- `home/linux/.claude/settings.json` and `home/osx/.claude/settings.json` have
  drifted, ignoring per-machine and OS-specific keys; or
- a file that belongs in `home/general/` reappears under `home/linux/` or
  `home/osx/`.

Bypass with `SKIP_SETTINGS_DRIFT=1 git commit ...`.

## Docs

- [OpenCode port](docs/opencode-port.md): what maps, what needs an adapter, and
  what has no equivalent. Short version: skills work unchanged because OpenCode
  reads `~/.claude/skills`; instructions, agents and commands need generated
  adapters; the Python hooks need a TypeScript plugin bridge, with deny rules
  rewritten as OpenCode permission rules.
- [Skill nudge system](home/general/.claude/skill-nudge-system.md)
- [Hook canvas](docs/hooks-canvas.png) ([source](docs/hooks-canvas.excalidraw),
  [Mermaid source](docs/hooks-canvas.mmd)): the registered hooks by lifecycle
  event, and the report-handoff convention
