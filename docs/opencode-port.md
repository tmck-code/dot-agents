# OpenCode port — findings

Status: research snapshot, **2026-10-23**. Target: **OpenCode V2**
(`opencode v2.0.21` installed here). This is a portability study, not an
implementation; paths and API names below are V2.

Question: what would it take to run this Claude Code dotfiles tree on OpenCode as well as Claude Code, from one shared source of truth?

> **Doc version note.** `opencode.ai/docs` is V1. The installed product and the `opencode` skill both say V2 is the source of truth, so every claim below is against `https://opencode.ai/v2/docs/` plus the V2 source tree. V2 keeps most V1 file formats working, but the plugin API and the client/server API are intentionally incompatible with V1.

---

## 0. Executive summary

- **One path is free:** OpenCode V2 already discovers `~/.claude/skills` (and project `.claude/skills`) as a *global compatibility source*. Every `SKILL.md` in this repo loads without conversion, with the same `name`/`description`/`disable-model-invocation` semantics.
- **Everything else needs a thin adapter.** V2 does **not** read `.claude/agents`, `.claude/commands`, `.claude/settings.json`, `.claude/hooks`, or `CLAUDE.md`. Source: `packages/core/src/config/plugin/compatibility.ts` only scans `skills/`; `config/plugin/agent.ts` and `config/plugin/command.ts` load only from discovered OpenCode config entries.
- **Agents and commands are text formats that can be generated** from the existing Claude files. Do not symlink them: the frontmatter differs (`tools`, `effort`, bare `model: opus` are not valid OpenCode agent fields).
- **Hooks are bridged, not ported.** Claude hooks are stdin-JSON/exit-code subprocesses. OpenCode hooks are in-process TypeScript plugin registrations (`ctx.tool.hook`, `ctx.session.hook`, `ctx.shell.hook`) plus an async event stream. A single bridge plugin, `home/general/.config/opencode/plugins/claude-hooks.ts`, synthesises Claude-shaped stdin payloads, spawns the existing Python hooks, and applies their decisions. The Python files stay the single source of truth for both harnesses.
- **Statusline has no equivalent.** The YAS statusline is Claude/CLI-specific. OpenCode has a built-in TUI status area, and custom UI requires a TUI plugin (`@opencode/plugin/tui`), not a command that prints a line.
- **Notifications move from hooks to `cli.json`:** `attention.notifications`, `attention.sound`, `attention.sounds.{permission,done,error,subagent_done}`.
- **Recommended shape:** keep `home/general/.claude/` as the canonical source, add `home/general/.config/opencode/` for OpenCode-native files (`plugins/`, `opencode.jsonc`, `cli.json`), and **generate** agents/commands/`AGENTS.md` into a git-ignored build directory at deploy time. Symlink only the parts that are byte-identical (skills).

---

## 1. Directory layout and path mapping

### 1.1 Where OpenCode reads global config

| Scope | Path | Notes |
|---|---|---|
| Global config | `~/.config/opencode/opencode.json` or `opencode.jsonc` | `$XDG_CONFIG_HOME/opencode` when XDG is set |
| Global agents | `~/.config/opencode/agents/<name>.md` | ID is the path-derived name; nested dirs become `team/reviewer` |
| Global commands | `~/.config/opencode/commands/<name>.md` | singular `command/` also discovered |
| Global skills | `~/.config/opencode/skills/<id>/SKILL.md` | flat `<id>.md` also accepted |
| Global plugins | `~/.config/opencode/plugins/` | direct `.ts`/`.js` files and package dirs auto-loaded |
| Global themes | `~/.config/opencode/themes/*.json` | filename is the theme name |
| Global instructions | `~/.config/opencode/AGENTS.md` | loaded first |
| CLI/TUI settings | `~/.config/opencode/cli.json` | themes, keybinds, notifications, TUI plugins. **Never in `opencode.json`** |
| System-wide | `/etc/opencode/` (Linux), `/Library/Application Support/opencode` (macOS) | highest precedence; same `agents/ commands/ skills/ plugins/` layout |
| Project config | `<dir>/opencode.json(c)` **or** `<dir>/.opencode/opencode.json(c)` | searched cwd → filesystem root; `.opencode` beats direct at the same level |
| Project definitions | `<dir>/.opencode/{agents,commands,skills,plugins,themes}/` | nearest project wins |

Precedence for config: global → ancestor direct → nearer direct → **all `.opencode` configs** → system. Settings merge; later wins. Source: <https://opencode.ai/v2/docs/config#locations>.

Claude Code compatibility directories: only `~/.claude/skills`, `~/.claude/skills` per project, and `~/.agents/skills` are scanned. The compatibility plugin does not look at anything else under `.claude`. Source: <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/plugin/compatibility.ts>, docs table at <https://opencode.ai/v2/docs/skills#discovery>.

### 1.2 Mapping every path in this repo

| Repo path | OpenCode destination | Mechanism |
|---|---|---|
| `home/general/.claude/CLAUDE.md` | `~/.config/opencode/AGENTS.md` | **Generated** (or `instructions` entry). Not read from `CLAUDE.md` |
| `home/general/.claude/agents/*.md` | `~/.config/opencode/agents/*.md` | **Generated** with rewritten frontmatter (filename becomes ID) |
| `home/general/.claude/commands/*.md` | `~/.config/opencode/commands/*.md` | **Generated**; body is identical, frontmatter trimmed |
| `home/general/.claude/skills/**` | `~/.config/opencode/skills/**` | **Symlink or rely on `~/.claude/skills` compatibility** |
| `home/general/.claude/hooks/*.py` | `~/.config/opencode/plugins/*.ts` | **Rewritten** as one plugin (or a bridge plugin) |
| `home/general/.claude/settings.json` (none) + `home/{linux,osx}/.claude/settings.json` | `~/.config/opencode/opencode.jsonc` + `~/.config/opencode/cli.json` | **Generated/merged** per OS |
| `home/general/.claude/delegate-routing.json` | data file read by the ported nudge plugin | No native equivalent; keep as JSON, point plugin at it |
| `home/general/.claude/skill-routing.json` | data file read by the ported skill-nudge plugin | No native equivalent |
| `home/general/.claude/skill-nudge-system.md` | docs only | No equivalent |
| `home/general/.claude/scripts/gate.sh` | unchanged | Invoked from agent prompts/commands by absolute path |
| `home/general/.claude/scripts/yas.sh` | no equivalent | YAS is a Claude statusline helper |
| `home/linux/.claude/hooks/agent-notify.py` | `cli.json` `attention` config, or a plugin | No command hook for notifications |
| `home/linux/.claude/scripts/agent-watch.sh` | no equivalent | Claude-specific watcher |
| YAS `statusLine` in `settings.json` | **no equivalent** | Built-in TUI status; custom needs a TUI plugin |
| `enabledPlugins` / marketplaces | `~/.config/opencode/plugins` + `opencode plugin add` | Different registry; no marketplace concept |
| `.mcp.json` (not present) | `mcp.servers` in `opencode.jsonc` | Native MCP client |
| `.claude/settings.local.json` `skillOverrides` | none | OpenCode has no lease/disable-by-project mechanism; use `permissions` per skill |

Sources: <https://opencode.ai/v2/docs/config#locations>, <https://opencode.ai/v2/docs/agents#locations>, <https://opencode.ai/v2/docs/commands#markdown>, <https://opencode.ai/v2/docs/skills#discovery>, <https://opencode.ai/v2/docs/plugins#discover>, <https://opencode.ai/v2/docs/themes#adding-a-theme>.

---

## 2. Instruction files: `CLAUDE.md` vs `AGENTS.md`

- OpenCode V2 recognises **`AGENTS.md` only**. Explicit doc wording: “OpenCode V2 recognizes `AGENTS.md` only. It does not use `CLAUDE.md` as a fallback.” <https://opencode.ai/v2/docs/instructions>
- Discovery: global `~/.config/opencode/AGENTS.md`, then every `AGENTS.md` from the workspace directory **up toward home** (nearest-first at load time), plus nested files discovered below the workspace as the agent reads there. For workspaces outside `$HOME`, discovery stops at the project root.
- Ordering: agent system prompt → Code Mode guidance → MCP/reference/skill guidance → global+project `AGENTS.md` and configured `instructions` → built-in date/env. Files are **combined, not overridden**. There is no “project wins on conflict” rule like Claude Code's.
- `instructions: [...]` accepts files, globs, `~/`, absolute paths, and HTTP(S) URLs. Relative entries resolve from the workspace up to the project root. <https://opencode.ai/v2/docs/config#instructions>
- Nested `AGENTS.md` are loaded lazily when the agent reads that area. Editing a loaded nested file does not retrigger; start a new session.
- Claude `@path` imports inside `CLAUDE.md` are **not** expanded by OpenCode. Anything imported must become its own `instructions` entry or be inlined by the generator.

**Consequence for this repo.** `CLAUDE.md` says “Project `CLAUDE.md` files layer on top and win on conflict”, which is false in OpenCode. Either accept OpenCode's combine-all behaviour or generate an OpenCode-specific `AGENTS.md` whose header says so. Cheapest correct approach:

```jsonc
// ~/.config/opencode/opencode.jsonc
{ "instructions": ["~/.claude/CLAUDE.md"] }
```

This works, but reads the *deployed* Claude file, not the repo source, and inherits the false precedence sentence. For one source of truth, instead generate `AGENTS.md` from `home/general/.claude/CLAUDE.md` during deploy and replace that one sentence for the OpenCode target.

---

## 3. Agents: Claude frontmatter vs OpenCode agents

### 3.1 Where they live and how they are identified

- OpenCode: `~/.config/opencode/agents/<name>.md` or `.opencode/agents/<name>.md`. Nested path becomes the ID (`team/reviewer`). `mode` defaults to `primary` for a new custom agent. Claude subagents therefore need **`mode: subagent`**.
- Delegation is the `subagent` tool; a parent's `permissions` with action `subagent` controls which agents it can launch. Built-ins are `build`, `plan`, `general`, `explore` (V2 has no `scout`).
- Sources: <https://opencode.ai/v2/docs/agents#locations>, <https://opencode.ai/v2/docs/agents#modes>.

### 3.2 Field-by-field

| Claude Code frontmatter | OpenCode V2 | Verdict |
|---|---|---|
| `name: worker` | No `name` field. ID comes from the filename (`worker.md` → `worker`). | **Drop**; V2 logs it as unsupported |
| `description:` | `description:` | **Maps 1:1** |
| `tools: Read, Edit, Write, Bash, ...` | No `tools` field. Express as ordered `permissions` (`read`, `edit`, `shell`, `glob`, `grep`, `skill`, `subagent`, `webfetch`, `websearch`) | **Rewrite** |
| `model: opus` / `sonnet` / `haiku` | `model: provider/model` or `provider/model#variant`, e.g. `anthropic/claude-opus-4-8`, `anthropic/claude-sonnet-5-5#high` | **Rewrite**; aliases are not resolved |
| `effort: low` | No `effort`. Use a model **variant** (`#low`/`#high`) or provider/model `variants` in config | **Rewrite** |
| (implicit subagent) | `mode: subagent` | **Add** |
| `isolation: worktree` | Worktree creation is per-session/CLI; no agent frontmatter field | **No equivalent**; encode in the brief |
| `color`, `hidden`, `steps` (not used here) | `color`, `hidden`, `steps` | Supported |
| `permission`/`tools` V1 map | `permissions: [{action, resource, effect}]` | Rewrite |

Sources: <https://opencode.ai/v2/docs/agents#options>, <https://opencode.ai/v2/docs/permissions#actions>, <https://opencode.ai/v2/docs/migrate-v1#agent-files>.

### 3.3 What actually happens to this repo's agent files

The repo's five agents all use `name`, `description`, `tools: <comma string>`, `model: <alias>`, and some use `effort: low`. OpenCode reads a file as **V1** unless it contains one of `permissions`, `request`, `system`, or `disabled`. V1 decoding accepts `tools` only as a permission-entries map, not as Claude's comma-separated string; a decode failure drops the whole agent silently (`Option.none`). Even when V1 decoding succeeds:

- `name` is ignored (ID is the filename).
- `model: opus` has no `/`, so `modelSelection()` returns `undefined` — the agent inherits the parent model.
- `effort` is an unknown key, folded into `request.body`, and V2 does not send `request` values to the model.
- the `tools` restriction is either rejected or converted through V1 permission mapping; it is not a Claude-style allowlist.

Verified in source: `packages/core/src/config/plugin/agent.ts` (`legacySources`, `nativeKeys`, `decode`), `packages/core/src/v1/config/agent.ts` (`tools` schema, `normalize`), `packages/core/src/v1/config/migrate.ts` (`modelSelection`). With the five files copied into a scratch `.opencode/agents/`, `opencode debug agents` returned no custom agents — treat “loads as-is” as false.

**Required rewrite, per file:**

```yaml
---
description: Implements one well-scoped piece of work from a brief.
mode: subagent
model: anthropic/claude-sonnet-5-5
permissions:
  - { action: read,  resource: "*", effect: allow }
  - { action: edit,  resource: "*", effect: allow }
  - { action: shell, resource: "*", effect: allow }
  - { action: glob,  resource: "*", effect: allow }
  - { action: grep,  resource: "*", effect: allow }
  - { action: skill, resource: "*", effect: allow }
---
```

For `Explore`, deny `edit` and `shell` except the narrow `.scratch` write you actually want; OpenCode's built-in `explore` already does read-only plus shell. For `orchestrator`/`spec-author`, deny `edit` to reproduce the “plans, does not edit” rule. OpenCode also has built-in `plan` (denies edits outside `~/.opencode/plan`) and `explore`, so `Explore.md` may be redundant.

**Model ID choice:** map `opus`→`anthropic/claude-opus-4-8` (or the current models.dev Opus), `sonnet`→`anthropic/claude-sonnet-5-5`, `haiku`→`anthropic/claude-haiku-4-5`. Use `#low`/`#high` for effort only if that variant exists for the model. Keep the mapping in the generator, not in prose.

---

## 4. Commands

### 4.1 Format

- Global `~/.config/opencode/commands/<name>.md`; project `.opencode/commands/<name>.md`. Nested dirs become `/team/review`. Only `.md`.
- Frontmatter: `description`, `agent`, `model` (`provider/model[#variant]`), `subagent` (bool; `subtask` deprecated alias). Body is the template.
- `$ARGUMENTS` = full argument string. `$1`, `$2`, … = quoted-argument positions; the highest position consumes the rest. With no placeholder, non-empty arguments are appended after a blank line.
- Shell interpolation uses `` !`cmd` `` (same syntax as Claude Code), runs in the active project directory with the configured shell, **before** the prompt is submitted and **outside** tool permissions. Argument placeholders expand inside the shell block.
- Unknown frontmatter keys are ignored by the schema (`Config.Command` is a closed `Schema.Class`; decoding strips extras), so `allowed-tools`, `argument-hint`, `disable-model-invocation` are harmless but inert.

Sources: <https://opencode.ai/v2/docs/commands>, <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/plugin/command.ts>.

### 4.2 `handoff-write` / `handoff-resume` compatibility

Both files are **syntactically compatible** with OpenCode: same `$ARGUMENTS`, same `` !`...` `` blocks, same plain-Markdown body.

Real incompatibilities:

| Issue | Effect in OpenCode | Fix |
|---|---|---|
| `allowed-tools: Bash("...")` | Ignored. No per-command tool allowlist. | Put rules in `permissions` (global or agent) if you actually need the restriction |
| `disable-model-invocation: true` | Ignored; OpenCode commands are user-invoked only, so behaviour is effectively the same | None |
| `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` in shell blocks | OpenCode does not set `CLAUDE_CONFIG_DIR`; falls back to `$HOME/.claude`, which is where this repo deploys, so it happens to work | Generate the OpenCode copy with `${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}` or export `CLAUDE_CONFIG_DIR` |
| `awk ... ${CLAUDE_CONFIG_DIR}/skills/handoff/SKILL.md` | Local skill path, unrelated to OpenCode | Already fixed; keep |
| `argument-hint` | Ignored | Drop in generated copy |
| `!` blocks run outside permissions | Same risk as Claude, but OpenCode explicitly warns about it | Only run trusted commands; do not interpolate `$ARGUMENTS` into shell |

**Verdict:** both commands should be *executed* successfully after generation. The shell interpolation is the part to test first, especially `shelf.sh handoff` and the `overseer.py enable dewey-decimal` call, because those scripts resolve paths from `$CLAUDE_CONFIG_DIR`.

---

## 5. Skills

**Yes — discovered, with identical layout and almost identical frontmatter.**

- Global compatibility source: `~/.claude/skills`. Project: `.claude/skills` at every level up to the project root. Also `~/.agents/skills`, `.agents/skills`.
- Precedence (low→high): built-ins → `.claude/skills` → `.agents/skills` → `~/.config/opencode/skills` → project `.opencode/skills` → explicit `skills` config entries.
- Form: `skills/<id>/SKILL.md`, or flat `skills/<id>.md`. ID is the **path-derived, case-sensitive** name; frontmatter `name` is only a display label.
- Frontmatter: `name` (display), `description` (required to advertise), `metadata.opencode/autoinvoke: false` or `disable-model-invocation: true` (hide from the model list), `license`/`compatibility` accepted but not interpreted. `allowed-tools` is ignored.
- Loading is via the `skill` tool with the exact ID, or `@skill-id` in a prompt. Supporting files are sampled (up to ten paths), not auto-loaded.
- Permissions: action `skill`, resource is the skill ID.

Sources: <https://opencode.ai/v2/docs/skills>, <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/plugin/compatibility.ts>.

**Repo impact:** zero changes needed for content. Caveats:

1. If you deploy to a non-default `CLAUDE_CONFIG_DIR` (e.g. `~/.claude.personal`), OpenCode will not see `~/.claude/skills`. Add `"skills": ["{env:CLAUDE_CONFIG_DIR}/skills"]` or symlink `~/.config/opencode/skills`.
2. `skill-overseer` relies on `settings.local.json` `skillOverrides` to mark skills disabled. OpenCode does not read that file, so the nudge hook's “currently DISABLED” logic will be wrong under OpenCode until the plugin is taught OpenCode's equivalent (disable via `permissions: [{action:"skill", resource:"<id>", effect:"deny"}]`).
3. OpenCode already advertises every skill with a description. The “keep the skill set lean” design has no direct equivalent; use deny permissions or `opencode/autoinvoke: false`.

---

## 6. Hooks and plugins

### 6.1 The two models are not interchangeable

| Claude Code | OpenCode V2 |
|---|---|
| External command per event | In-process TypeScript/JS plugin module (`.opencode/plugins/<name>/index.ts` or `~/.config/opencode/plugins/...`) |
| Payload JSON on **stdin** (`hook_event_name`, `session_id`, `transcript_path`, `cwd`, `tool_name`, `tool_input`, `tool_use_id`, `agent_id`, `agent_type`, `last_assistant_message`, `stop_hook_active`) | Typed event object passed to a callback (`ctx.tool.hook("execute.before", event)`) |
| Response JSON on **stdout** (`hookSpecificOutput.permissionDecision`, `additionalContext`, …) or **exit 2** + stderr to block | Mutate the event object or replace tool input; deny/ask through `ctx.permission.hook("evaluate")` (or static rules). No exit codes, no stdin/stdout. `execute.before` is documented for inspect/replace, not as a deny contract |
| One process per event; can be Python/bash | One long-lived plugin; async iterators for the event bus |
| Hooks configured in `settings.json` `hooks.{Event}` with `matcher` | Registrations in `setup(ctx)`; filtering by tool/agent is code |

Sources: <https://opencode.ai/v2/docs/build/plugins#hooks>, <https://opencode.ai/v2/docs/build/plugins#tools>, <https://opencode.ai/v2/docs/build/plugins#sessions>.

### 6.2 Event mapping

| Claude hook | OpenCode equivalent | Fidelity |
|---|---|---|
| `UserPromptSubmit` | `ctx.session.hook("prompt", e)` — mutate `e.prompt.text`, add `e.prompt.files`; or `ctx.session.hook("context", e)` to append system text on every model call | Good, but there is no “additionalContext” channel; inject by appending text or system parts |
| `PreToolUse` | `ctx.tool.hook("execute.before", e)` (`e.tool`, `e.agent`, `e.sessionID`, `e.input`); `ctx.permission.hook("evaluate", e)` (`e.action`, `e.resources`, `e.effect`) | Good. Mutate input in `execute.before`; deny/ask in `permission.evaluate`. Do not rely on throwing from `execute.before` as the deny path |
| `PostToolUse` | `ctx.tool.hook("execute.after", e)` (`e.status`, `e.result.content`, `e.error`) | Good for warnings/audit; append a text part to `e.result.content` if the model must see it |
| `SubagentStop` | No hook. Subscribe to events: `session.created` (`parentID`), `session.execution.succeeded/failed`, `session.synthetic` (`metadata.source = "subagent"`, `metadata.childID`, `text`), or `session.status` `idle`. Fetch the final message with the session API | **Adapter**, not a drop-in. `last_assistant_message` has no field; use the synthetic delivery or read the child session |
| `Stop` | `session.status` `{status:"idle"}` or `session.execution.succeeded` | Good for notifications |
| `StopFailure` | `session.execution.failed` with `error` | Good |
| `PreCompact` | `ctx.session.hook("compaction", e)` — runs before the summary, can supply `e.result`; events `session.compaction.started/ended/failed` | Good |
| `Notification` | No hook. `cli.json` `attention.notifications` + `attention.sounds.{permission,done,error,subagent_done}`; permission events available on the event bus | **No equivalent** for a custom command |
| `SessionStart` | Plugin `setup()` / `session.created` | Different lifecycle, workable |
| `SessionEnd` | `session.deleted` / service shutdown cleanup | Partial |

Event names verified in `packages/schema/src/session-event.ts` and `session-status-event.ts`; tool hook fields verified in `packages/core/src/tool.ts` (`tool`, `sessionID`, `agent`, `messageID`, `id`, `input`).

Docs check (2026-10-23): the V2 plugin docs describe `execute.before` as
“Inspect or replace tool input before execution”, and `permission.evaluate` as
the hook that can change `effect` to `allow`, `ask` or `deny`; an explicit
configured `deny` is final and does not invoke the hook. The instructions docs
confirm that `AGENTS.md` discovery covers both the ancestor walk and nested files
below the workspace as the agent explores. `cli.json` `attention.notifications`
and `attention.sounds` are the notification surface.

### 6.3 Per-script verdict

| Script | Claude event / role | OpenCode verdict | Notes |
|---|---|---|---|
| `ban-host-npm.py` | PreToolUse(Bash), deny with reason | **Adapter** | Port to `permission.hook("evaluate")` for action `shell` + `tool.hook("execute.before")`. Needs `shlex`-equivalent command parsing; JS has no stdlib equivalent, so either port the regex or shell out. `npm-in-docker.py` stays unchanged as a CLI |
| `npm-in-docker.py` | called by ban-host-npm | **Runs unchanged** | Standalone CLI; no hook contract |
| `nudge-delegate.py` | PreToolUse on Bash/Edit/Write/Read/Grep/Glob/Agent | **Adapter (largest)** | Tool names change: `Bash`→`shell`, `Read`→`read`, `Edit|Write`→`edit`, `Grep`→`grep`, `Glob`→`glob`, `Agent/Task`→`subagent`. `agent_id`/`agent_type`→`event.agent`. Deny through `ctx.permission.hook("evaluate")` (and/or a static permission rule); `execute.before` is documented for inspecting/replacing input, not as the deny path. Nudge through `ctx.session.hook("context", e => e.system.push(...))` or by mutating the tool result. Routing JSON can be read at plugin setup |
| `no-long-sleep.py` | PreToolUse(Bash) sleep guard | **Adapter** | `execute.before` with `event.tool === "shell"`; regex port is direct |
| `subagent-git-tree-guard.py` | PreToolUse(Bash) for subagents | **Adapter** | `event.agent` identifies the caller; `event.input.command`; throw to block. Same git logic |
| `skill-nudge.py` | UserPromptSubmit, reads `skill-routing.json` | **Adapter** | `session.hook("prompt")` can append the nudge text to `e.prompt.text`, or `context` hook can add it as a system part. Reads `$CLAUDE_PROJECT_DIR`; replace with `ctx.location.directory` |
| `subagent-file-handoff.py` | PreToolUse(Agent/Task) | **Adapter** | Hook `subagent`/`task` tool before execution; no `agent_type` at spawn time, so use `event.agent` (parent) and the tool input |
| `same-file-write-audit.py` | PostToolUse(Edit/Write) | **Adapter** | `execute.after` on `edit`; `event.agent` is the writer. Append warning to `e.result.content`; keep ledger in plugin storage or `$CLAUDE_CONFIG_DIR/hooks/state` |
| `subagent-report-capture.py` | SubagentStop | **Adapter (hard)** | No `last_assistant_message`. Subscribe to `session.synthetic` where `metadata.source === "subagent"`; `text` is the child's final message, `metadata.childID`/`agent` identify it. Or call the session API for the child's last assistant message. The deterministic scratch path can be preserved |
| `subagent-report-announce.py` | PostToolUse(Agent/Task/TaskOutput/SendMessage) | **Adapter** | Same synthetic event; on the parent's next `ctx.session.hook("context")`, append the report paths as system text. The breadcrumb directory can be reused unchanged |
| `handoff-nudge.py` | SubagentStop nudge | **Adapter / probably drop** | Same synthetic event; it is registered in this repo, but V2 has no child-stop injection point, so the reminder has to be re-timed or dropped |
| `precompact-probe.py` | PreCompact logging | **Adapter (trivial)** | `session.hook("compaction")` or subscribe `session.compaction.started`; write JSONL as today |
| `yas-prompt-hook.py` | UserPromptSubmit, writes timestamps for statusline | **No equivalent** | Only useful to YAS; drop with the statusline |
| `agent-notify.py` (linux only) | Notification + Stop + StopFailure | **No equivalent** | Replace with `cli.json` `attention.notifications`/`sound`; optionally a plugin that calls `notify-send` from `session.execution.*` |

### 6.4 Implemented bridge (2026-10-30)

`home/general/.config/opencode/plugins/claude-hooks.ts` is a dependency-free
OpenCode V2 plugin. It is a single `.ts` file (not a plugin directory) because
OpenCode 2.1 rejects a plugin directory whose entry file is a symlink pointing
outside that directory. Deploy symlinks the file into
`~/.config/opencode/plugins/`, where OpenCode's global plugin discovery picks it
up.

| Claude event | Bridge surface | Behaviour |
|---|---|---|
| `UserPromptSubmit` | `session.hook("prompt")` | Runs `skill-nudge.py`; appends `additionalContext` to the prompt text. |
| `PreToolUse` | `tool.hook("execute.before")` | Runs the guards; a deny throws, which OpenCode turns into a rejected tool call. `additionalContext` is queued for the next model call. |
| `PostToolUse` | `tool.hook("execute.after")` | Runs `same-file-write-audit.py` and appends its warning to the tool result. Also drains subagent report breadcrumbs for `subagent`. |
| `PreCompact` | `session.hook("compaction")` | Runs `precompact-probe.py`. |
| `Stop` | `session.execution.succeeded` | Sends a `Done` notification through `agent-notify.py` on Linux. |
| `SubagentStop` | `session.execution.succeeded` with `parentID` | Runs `subagent-report-capture.py`, `handoff-nudge.py`, and the parent-side report announce; queues parent context for the next model call. |
| `StopFailure` | `session.execution.failed` | Sends an `Error` notification. |
| `Notification` | `cli.json` `attention.*` | Left to OpenCode's native attention system. |
| YAS statusline | — | Claude-specific; OpenCode uses its own TUI status/plugin. |

Payload translation is the only harness-specific code: OpenCode tool names map
to Claude names (`shell`→`Bash`, `edit`/`write`→`Edit`/`Write`, `subagent`→`Agent`),
`path` maps to `file_path`, and `agent_id`/`agent_type` are populated only for
child sessions (the same rule Claude uses). Environment variables
`CLAUDE_CONFIG_DIR` and `CLAUDE_PROJECT_DIR` are set so the Python hooks resolve
their scripts and project routing tables unchanged.

Set `OPENCODE_HOOKS_DEBUG=1` to log plugin setup, hook invocations
(`/tmp/opencode/claude-hooks.log`), and the raw event stream
(`/tmp/opencode/claude-events.log`).

**Payload differences worth restating:** Claude gives you `agent_id` *only* for subagent-originated calls; OpenCode gives `event.agent` for every tool event (main agent and subagent). Claude gives `transcript_path`; OpenCode gives `sessionID` plus a message API. Claude reports a subagent's final text as `last_assistant_message`; OpenCode delivers it as a synthetic parent message. Claude `cwd` is a field; OpenCode gives `ctx.location.directory` / `event`-less session context.

---

## 7. Permissions, models, statusline, notifications, MCP

### 7.1 Permissions

OpenCode V2 replaces Claude's deny list with ordered rules:

```jsonc
{
  "permissions": [
    { "action": "*", "resource": "*", "effect": "allow" },
    { "action": "external_directory", "resource": "*", "effect": "ask" },
    { "action": "shell", "resource": "git push *", "effect": "deny" },
    { "action": "read", "resource": "*.env", "effect": "ask" }
  ]
}
```

- Actions: `read`, `edit`, `glob`, `grep`, `shell`, `subagent`, `skill`, `question`, `webfetch`, `websearch`, `external_directory`, `execute`, `<server>_<tool>`.
- **Last matching rule wins.** Default base policy is allow-all plus `.env` ask.
- V2 default for `external_directory` is **allow**, unlike V1; add an `ask`/`deny` if you want the old safety.
- `deny` is absolute; a permission hook cannot override it.

Claude settings mapping:

| Claude `settings.json` | OpenCode |
|---|---|
| `permissions.deny: ["Artifact", "AskUserQuestion", "EnterPlanMode", ...]` | No tool-name deny list. Most of these tools do not exist in OpenCode. To hide a capability, deny the action (`edit`, `subagent`, `question`, …) or disable an agent with `agents.<id>.disabled: true` |
| `permissions.allow/ask` (not used) | `permissions` array |
| `disableBundledSkills` | No equivalent; deny `skill` per ID |
| `disableClaudeAiConnectors`, `disableWorkflows`, `disableArtifact`, `disableRemoteControl` | No equivalents (features do not exist) |
| `effortLevel: "low"` | Model variant `#low`, or `providers.<id>.models.<model>.variants` |
| `env` | No top-level env map. Set variables in the shell profile, or `shell` for the shell tool |
| `model: "opus"` | `model: "anthropic/claude-opus-4-8"` |
| `enabledPlugins` | `plugins` array / `opencode plugin add` |

Sources: <https://opencode.ai/v2/docs/permissions>, <https://opencode.ai/v2/docs/migrate-v1#permissions-and-tools>.

### 7.2 Models

- Root `model: "provider/model"`; no `#variant` at root (root currently drops it).
- Agent/command `model` accepts `provider/model#variant`.
- No aliases (`opus`, `sonnet`, `haiku`). Resolve via `opencode models` or models.dev.
- `effort`/reasoning maps to a variant ID; variants are declared under `providers.<id>.models.<model>.variants` with `settings` or `body`.
- Local/other providers use `providers`, with `package`, `settings`, `headers`, `body`. `{env:VAR}` and `{file:path}` substitution is supported in JSON strings.

Sources: <https://opencode.ai/v2/docs/models>, <https://opencode.ai/v2/docs/config#model>.

### 7.3 Statusline

No command-based statusline. `settings.json` `statusLine` has **no equivalent**. Options:

1. Accept the built-in TUI status bar (branch, model, tokens, cost).
2. Write a TUI plugin under `~/.config/opencode/plugins/status/tui.ts` using `@opencode/plugin/tui` and `usePlugin()`/`context.theme`; register it in `cli.json` `plugins` if it is CLI-only.
3. Drop YAS. The YAS prompt hook and `yas.sh` become dead weight.

Source: <https://opencode.ai/v2/docs/cli/plugins>, <https://opencode.ai/v2/docs/cli/config#plugins>.

### 7.4 Notifications

`cli.json`:

```json
{
  "attention": {
    "notifications": true,
    "sound": true,
    "volume": 0.4,
    "sounds": { "permission": "/path/permission.wav", "done": "/path/done.wav", "error": "/path/error.wav", "subagent_done": "/path/subagent.wav" }
  }
}
```

This is event-driven by OpenCode (permission needed, done, error, subagent done), not a user command. Linux `notify-send`/macOS `osascript` customisation would need a plugin subscribing to `session.execution.*` / permission events. Source: <https://opencode.ai/v2/docs/cli/config#alerts>.

### 7.5 MCP

- V2 shape is `mcp.servers.<name>` (V1 had names directly under `mcp`).
- Local: `{ type: "local", command: [...], cwd, environment: { KEY: "{env:KEY}" }, disabled, codemode, timeout }`.
- Remote: `{ type: "remote", url, headers, oauth, client_id, ... }`; OAuth is the default.
- No `.mcp.json` compatibility is documented. There is no MCP config in this repo today, so nothing to port.

Source: <https://opencode.ai/v2/docs/mcp-servers>.

---

## 8. Recommended repo layout for dual support

### 8.1 Principle

**One canonical source, generated adapters, no duplicated bodies.**

- **Canonical:** keep `home/general/.claude/{CLAUDE.md,agents,commands,skills}` exactly as today (Claude Code is the primary tool and its format is the richer one for this repo).
- **OpenCode-native (hand-written):** `home/general/.config/opencode/{opencode.jsonc,cli.json,plugins/}` — things with no Claude equivalent.
- **Generated (not checked in):** `home/general/.config/opencode/_generated/{AGENTS.md,agents/,commands/}` — rebuilt by `deploy.sh` from the `.claude` source.
- **Symlinked:** skills (`~/.config/opencode/skills -> ~/.claude/skills`) or rely on OpenCode's `~/.claude/skills` compatibility.

Why not symlink agents/commands directly: symlinks cannot change frontmatter, and OpenCode must not see `tools:`/`effort`/bare `model:`.

### 8.2 Proposed tree

```text
home/
  general/
    .claude/                     # unchanged canonical Claude tree
      CLAUDE.md
      agents/*.md
      commands/*.md
      skills/**
      hooks/*.py
      scripts/gate.sh
    opencode/
      opencode.jsonc             # hand-written: permissions, model, skills, plugins, mcp
      cli.json                   # hand-written: theme, attention, TUI plugins
      plugins/
        discipline/              # ported nudge-delegate + no-long-sleep + git guard
          index.ts
        reports/                 # ported report capture/announce
          index.ts
        skill-nudge/             # ported skill-nudge + routing JSON
          index.ts
        notify/                  # optional replacement for agent-notify.py
          index.ts
      overrides/
        CLAUDE.md.opencode.md    # replaces the false precedence paragraph (optional)
  linux/
    opencode/
      opencode.overlay.jsonc     # OS-only model/permissions/env
      cli.json.overlay           # OS notifications (notify-send vs osascript)
  osx/
    opencode/
      opencode.overlay.jsonc
      cli.json.overlay
```

Deployed layout:

```text
$CLAUDE_CONFIG_DIR/                  # ~/.claude
  CLAUDE.md
  agents/ commands/ skills/ hooks/ scripts/

$OPENCODE_CONFIG_DIR/                # ~/.config/opencode
  opencode.jsonc                     # generated merge of general + OS overlay
  cli.json                           # generated merge
  AGENTS.md                          # generated from CLAUDE.md
  agents/*.md                        # generated
  commands/*.md                      # generated
  skills -> $CLAUDE_CONFIG_DIR/skills
  plugins/                           # symlinked from home/general/.config/opencode/plugins
  _generated/                        # build output (gitignored)
```

### 8.3 `deploy.sh` changes

Current script only knows `.claude`. Concrete changes:

1. Add `OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"`.
2. Change the CLI to `./deploy.sh [--tool claude|opencode|both] linux|osx`, defaulting to `both` once stable.
3. Keep `install_homedir` for the Claude tree. Add `install_opencode`:
   - symlink `home/general/.config/opencode/{plugins,overlay}` into `$OPENCODE_CONFIG_DIR`;
   - run `python3 tools/render_opencode.py --repo "$REPO_ROOT" --os "$1" --out "$OPENCODE_CONFIG_DIR/_generated"`;
   - symlink or copy generated files into `$OPENCODE_CONFIG_DIR`;
   - merge `opencode.jsonc` + OS overlay into `$OPENCODE_CONFIG_DIR/opencode.jsonc` (use JSON, not JSONC, for generated output);
   - symlink `skills`.
4. Do **not** symlink `opencode.jsonc`/`cli.json` directly if you need an OS merge; generate them.
5. Add a `--check` mode that renders into a temp dir and diffs, so CI can fail when the generated adapters drift from the Claude source.
6. Keep the existing `core.hooksPath` call.

The generator is a small Python script with one mapping table:

| Input | Output transformation |
|---|---|
| `CLAUDE.md` | prepend a V2-specific header; replace the precedence sentence; write `AGENTS.md` |
| `agents/<name>.md` | parse YAML frontmatter; `description` stays; add `mode: subagent`; rewrite `model` through an alias map; convert `tools: A, B` to `permissions`; drop `name`/`effort`/`isolation`; body unchanged |
| `commands/<name>.md` | keep `description`; drop `allowed-tools`, `argument-hint`, `disable-model-invocation`; optionally rewrite `CLAUDE_CONFIG_DIR` to `OPENCODE_CONFIG_DIR`; body unchanged |
| `skills/**` | no transformation |
| `settings.json` + OS overlay | emit `opencode.jsonc` permissions/model/plugins; emit `cli.json` theme/attention |

### 8.4 Symlinks vs generated files

| Thing | Symlink? | Why |
|---|---|---|
| skills | **Yes** (or compatibility path) | Byte-identical, OpenCode reads `~/.claude/skills` natively |
| plugins | **Yes** | Hand-written OpenCode-native TS; no transformation |
| agents, commands, AGENTS.md | **No — generate** | Frontmatter differs |
| `opencode.jsonc`, `cli.json` | **No — generate** | Need per-OS merge and JSONC→JSON normalisation |
| hooks `.py` | **No** | Not a plugin format; either port to TS or run through a bridge plugin |

A bridge plugin is a valid intermediate step: one `hooks-bridge/index.ts` that maps OpenCode events to the existing scripts' stdin JSON, spawns `python3`, parses `hookSpecificOutput`, and applies `permissionDecision`/`additionalContext`. This preserves the Python logic for a staged migration at the cost of per-event process spawns and a translation layer that must fake `agent_type`, `session_id`, `tool_input`, `last_assistant_message`.

---

## 9. Staged migration plan

**Stage 0 — verify the target (half a day).**
- Install/lock OpenCode V2 (`v2.0.21` here). Confirm `opencode debug paths`, `opencode models`, `opencode mcp list`.
- Create a throwaway `$OPENCODE_CONFIG_DIR`, deploy only skills, confirm every skill appears and loads.

**Stage 1 — skills (no code).**
- Point OpenCode at the deployed `~/.claude/skills` (automatic) or symlink `~/.config/opencode/skills`.
- Confirm `skill-overseer`/`dewey-decimal` scripts still resolve `$CLAUDE_CONFIG_DIR`.
- Known gap: `skillOverrides` leasing is invisible to OpenCode; decide whether to accept “all skills always advertised” or add deny permissions.

**Stage 2 — instructions.**
- Generate `AGENTS.md` from `CLAUDE.md`; fix the precedence paragraph.
- Decide the per-project story: OpenCode combines all `AGENTS.md`; this repo's CLAUDE.md claims project wins. Update the source text if OpenCode is a first-class target.

**Stage 3 — commands.**
- Generate the two handoff commands; test `$ARGUMENTS`, `!` blocks, and `shelf.sh` paths under both `CLAUDE_CONFIG_DIR` set and unset.
- Confirm `allowed-tools` removal does not widen anything you care about (shell blocks already bypass permissions).

**Stage 4 — agents.**
- Generate the five agents; rewrite `tools`→`permissions`, `model` aliases, `effort`→variant, add `mode: subagent`.
- Test with `opencode debug agents` and one real subagent spawn per agent. Start with `worker` and `Explore`.
- Reproduce the orchestrator's “no edits” rule with an `edit` deny; reproduce Explore's read-only rule with `edit`/`shell` denies.

**Stage 5 — permissions, model, MCP, notifications.**
- Generate `opencode.jsonc` and `cli.json` from the two `settings.json` files plus OS overlays.
- Map the deny list to actions; add `external_directory: ask` if you want V1-like safety.
- Turn on `attention.notifications` and per-OS sounds; accept that the custom `agent-notify.py` message is lost.

**Stage 6 — hooks/plugins (the bulk).**
- Port in order of value/risk: `no-long-sleep` → `subagent-git-tree-guard` → `ban-host-npm` → `same-file-write-audit` → `skill-nudge` → `nudge-delegate` → report capture/announce.
- Keep a `hooks-bridge` plugin as a fallback for anything not yet ported.
- Port `nudge-delegate` last: it is 549 lines and its routing table uses Claude tool names and caller identity.
- For reports, prototype the `session.synthetic` subscription early; it is the only parity risk for the SubagentStop pair.

**Stage 7 — remove/retire.**
- Drop `yas-prompt-hook.py`, `yas.sh`, and the `statusLine` block for OpenCode (keep for Claude).
- Decide whether `handoff-nudge.py` is still wanted at all.
- Add a CI check that regenerates the adapters and diffs them.

---

## 10. Risks and unknowns

| Risk | Severity | Mitigation |
|---|---|---|
| **V2 is a moving target.** Installed `2.0.21`; docs are V2-only; plugin API is new and may change | High | Pin the OpenCode version; keep plugins small; re-run the port test on upgrade |
| **Only skills have a `.claude` compatibility path.** Agents/commands/hooks/settings do not | High | Generate adapters; do not assume Claude layout works |
| **Existing Python hooks cannot run unchanged** (stdin/stdout/exit-code contract) | High | Port to TS or use a bridge plugin; budget the nudge engine separately |
| **SubagentStop has no direct hook.** Final text is delivered as a synthetic parent message | High | Prototype `session.synthetic` + `metadata.source === "subagent"` and the session message API before committing to report capture |
| **Agent frontmatter silently drops agents** on decode failure (`Option.none`) | Medium | Generate valid frontmatter; test each agent with `opencode debug agents`; fail the generator if an agent does not appear |
| **`tools:` parsed as a comma string can fail V1 decode** and drop the whole agent | Medium | Never emit `tools`; emit `permissions` and `mode` |
| **Model aliases are not resolved.** `opus`/`sonnet` silently become “inherit parent” | Medium | Central alias map in the generator; assert every generated agent has a `provider/model` |
| **`CLAUDE_CONFIG_DIR` is not set by OpenCode.** Commands/hooks that use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` work only on the default path | Medium | Generate OpenCode copies with `OPENCODE_CONFIG_DIR`, or export the variable in the shell profile |
| **`skillOverrides` leasing is invisible.** `skill-nudge` will mislabel enabled/disabled skills | Medium | Teach the ported plugin OpenCode `permissions` or drop the disabled branch for OpenCode |
| **Statusline is lost.** No command-based statusline | Low/Medium | Accept built-in status or write a TUI plugin; do not port YAS |
| **Tool names differ.** `Bash`/`Edit`/`Write`/`Task`/`Agent` vs `shell`/`edit`/`subagent` | Medium | One mapping table; test every hook rule against the OpenCode tool names |
| **`external_directory` defaults to allow in V2** | Medium | Add an explicit `ask`/`deny` rule if you rely on Claude's boundary |
| **Config merge is JSONC and per-OS.** Naive `cat`/`jq` loses comments or breaks | Low | Keep comments in source, generate plain JSON; merge general + OS overlay in Python |
| **`opencode debug agents` returned `[]` for a copied `.claude` agent set** | Info | Treat as evidence that Claude agent files are not discovered/converted; re-test with generated files in a real project root |
| **OpenCode TUI/server split.** Some settings are `cli.json`, not `opencode.jsonc` | Low | Generate both; never put theme/keybinds/attention in `opencode.jsonc` |
| **MCP parity** | Low today | No MCP config in this repo; when added, use `mcp.servers` and `{env:}` |
| **Doc drift** | Medium | Re-read `https://opencode.ai/v2/docs/` at each stage; V1 docs at `/docs` will mislead |

---

## 11. Sources

**Official V2 docs**
- Intro/index: <https://opencode.ai/v2/docs/>
- Config, locations, instructions, permissions: <https://opencode.ai/v2/docs/config>, <https://opencode.ai/v2/docs/instructions>, <https://opencode.ai/v2/docs/permissions>
- Agents: <https://opencode.ai/v2/docs/agents>
- Commands: <https://opencode.ai/v2/docs/commands>
- Skills: <https://opencode.ai/v2/docs/skills>
- Plugins (loading): <https://opencode.ai/v2/docs/plugins>
- Plugin API, hooks, events: <https://opencode.ai/v2/docs/build/plugins>
- MCP: <https://opencode.ai/v2/docs/mcp-servers>
- Models: <https://opencode.ai/v2/docs/models>
- Migration from V1: <https://opencode.ai/v2/docs/migrate-v1>
- CLI settings: <https://opencode.ai/v2/docs/cli/config>
- Themes: <https://opencode.ai/v2/docs/cli/theme>
- CLI plugins: <https://opencode.ai/v2/docs/cli/plugins>
- Machine-readable index: <https://opencode.ai/v2/llms.txt>

**OpenCode source (V2, `dev`)**
- Config discovery and `.claude` roots: `packages/core/src/config/discovery.ts` — <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/discovery.ts>
- Only-skills compatibility plugin: `packages/core/src/config/plugin/compatibility.ts` — <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/plugin/compatibility.ts>
- Agent loader / V1 fallback: `packages/core/src/config/plugin/agent.ts` — <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/plugin/agent.ts>
- Command loader / template expansion: `packages/core/src/config/plugin/command.ts` — <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/config/plugin/command.ts>
- V1→V2 agent migration: `packages/core/src/v1/config/migrate.ts` — <https://github.com/anomalyco/opencode/blob/dev/packages/core/src/v1/config/migrate.ts>
- Command schema: `packages/schema/src/config/command.ts` — <https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/config/command.ts>
- Session and status event names: `packages/schema/src/session-event.ts`, `packages/schema/src/session-status-event.ts`
- Tool hook fields: `packages/core/src/tool.ts`

**Local environment**
- `opencode --version` → `2.0.21`
- Installed `opencode` skill: `/builtin` (V2 policy; V1 docs explicitly excluded)
- Repo: `deploy.sh`, `home/general/.claude/{CLAUDE.md,agents,commands,hooks,scripts,skills}`, `home/{linux,osx}/.claude/settings.json`
