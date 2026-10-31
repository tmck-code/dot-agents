# dot-agents

Agentic dotfiles: skills, hooks, agents, commands, routing tables and settings
for Claude Code and OpenCode. The Python hooks are shared; an OpenCode bridge
plugin translates events to their Claude Code contract. See
[docs/opencode-port.md](docs/opencode-port.md).

Everything that used to live under `.claude/` in
[tmck-code/dotfiles](https://github.com/tmck-code/dotfiles) now lives here.

## Layout

```
home/general/.claude/   shared on every machine: CLAUDE.md, agents, commands,
                        hooks, scripts, skills, routing tables, hook docs
home/general/.config/   shared OpenCode config: opencode.jsonc, cli.json,
  opencode/             plugins/claude-hooks.ts (Claude hook bridge)
home/general/bin/       ~/bin helpers: opencode-docker (run the container
                        against the current repo)
home/linux/.claude/     Linux-only: settings.json, hooks/agent-notify.py,
                        scripts/agent-watch.sh
home/osx/.claude/       macOS-only: settings.json
docker/opencode/        OpenCode v2 dev image: Node, uv/Python, git
```

**Rule:** if both machines can use it, it belongs in `home/general/`. Only
genuinely OS- or machine-specific files belong in `home/linux/` or
`home/osx/`. The pre-commit hook rejects shared files that reappear per OS.

`home/<os>/.claude/<path>` is symlinked to `$CLAUDE_CONFIG_DIR/<path>`
(default `~/.claude/<path>`), and `home/<os>/.config/opencode/<path>` to
`$HOME/.config/opencode/<path>`.

Local OpenCode secrets (`service.json`, `auth.json`) and `node_modules/` stay
out of the repo; they are listed in `.gitignore`.

## Install

```
./deploy.sh linux
./deploy.sh osx
CLAUDE_CONFIG_DIR=~/.claude.personal ./deploy.sh osx
```

`deploy.sh` installs `home/general` first, then the selected OS. It skips
`__pycache__`, `.pytest_cache`, `.ruff_cache`, `.scratch` and `node_modules`,
and removes stale symlinks that point into this repo but no longer resolve. If a managed directory
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

Or, after `./deploy.sh linux|osx`, the same launcher is on `~/bin`:

```
cd ~/dev/some-project
opencode-docker --stack          # first run: start the safe stack + lease
opencode-docker
opencode-docker --shell
opencode-docker run "summarise this repo"
opencode-docker --status         # show the safe-stack containers
opencode-docker --down           # stop the safe stack (--down --volumes wipes state)
```

It mounts the git root of `$PWD` at the same absolute path inside the
container. `--stack` starts the documented safe stack and approves a lease, then
launches. `REPO_ROOT=/path` overrides the mount; `--unsafe` is for trusted
debugging only.

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

### OpenCode

`home/general/.config/opencode/plugins/claude-hooks.ts` bridges OpenCode V2's
in-process hooks and event stream to the same Python scripts. The scripts still
see Claude-shaped stdin, so there is one hook implementation, not two:

| Claude event | OpenCode surface |
|---|---|
| `UserPromptSubmit` | `session.hook("prompt")` |
| `PreToolUse` | `tool.hook("execute.before")` (deny throws) |
| `PostToolUse` | `tool.hook("execute.after")` |
| `PreCompact` | `session.hook("compaction")` |
| `Stop` / `SubagentStop` | `session.execution.succeeded` |
| `StopFailure` | `session.execution.failed` |

`additionalContext` is queued and injected as a system part on the session's
next model call. Set `OPENCODE_HOOKS_DEBUG=1` to log setup, hook invocations and
the raw event stream under `/tmp/opencode/`.

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
- [Hook canvas](docs/hooks-canvas.png) ([Mermaid source](docs/hooks-canvas.mmd)): the registered hooks by lifecycle
  event, and the report-handoff convention

All diagrams below share one colour legend.

### Component canvas

Shows every hook (grouped by event, unregistered ones dashed), skill, agent, command, routing and config file, script and data store, with the deployment model on top.

![Component canvas](docs/component-canvas.png)

### Architecture

Shows the main-thread steps numbered 1 to 8. Side regions cover subagents, the shelf, routing tables and deploy. It also shows failure cases.

![Architecture](docs/architecture.png)

### Session sequence

Shows the messages for one prompt that spawns a subagent and runs a gate.

![Session sequence](docs/session-sequence.png)

### Session gantt

Shows the order in which hooks and scripts run during a session, on a relative time axis.

![Session gantt](docs/session-gantt.png)

### Interaction flowchart

Shows which files register, read, name or write which other files. It has one decision, for nudge-delegate.

![Interaction flowchart](docs/interaction-flowchart.png)

### Data flow

Shows processes (hooks, scripts, skills), data stores with their paths, and external entities (User, Claude Code runtime, git, GitHub, Excalidraw+).

![Data flow](docs/data-flow.png)
