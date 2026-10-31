## Context

`home/general/.config/opencode/plugins/claude-hooks.ts` is a dependency-free
OpenCode V2 plugin. It registers `ctx.session.hook("prompt")`,
`ctx.tool.hook("execute.before")`, `ctx.tool.hook("execute.after")`,
`ctx.session.hook("compaction")` and `ctx.session.hook("context")`, and consumes
`ctx.event.subscribe()` for terminal session events. It synthesises Claude Code
payloads, spawns Python hooks from `$CLAUDE_CONFIG_DIR/hooks`, and applies the
result.

Today the mapping is hard-coded:

- `PRE_TOOL` is a `HookSpec[]` with `ban-host-npm.py`, `no-long-sleep.py`,
  `subagent-git-tree-guard.py`, `nudge-delegate.py` and
  `subagent-file-handoff.py`;
- PostToolUse calls `same-file-write-audit.py` and
  `subagent-report-announce.py` by name;
- `onIdle` calls `subagent-report-capture.py`, `handoff-nudge.py` and
  `subagent-report-announce.py` directly;
- `notify()` invokes `agent-notify.py send` with explicit CLI arguments.

The real source of truth is `home/linux/.claude/settings.json` (and the macOS
equivalent), which already declares matcher groups for `PreToolUse`,
`PostToolUse`, `UserPromptSubmit`, `SubagentStop`, `Notification`, `Stop` and
`StopFailure`. Claude Code merges hooks across settings levels rather than
replacing them, runs an identical handler once even when several files declare
it, treats `timeout` as seconds, and distinguishes exact matchers
(`Bash|Edit`, `Edit, Write`) from unanchored JavaScript regex matchers.

The Docker image pins `OPENCODE_VERSION=2.1.4` (`docker/opencode/Dockerfile:21`,
`docker/opencode/Makefile:2`). In 2.1.4, `ctx.session.synthetic(...)` exists but
`session.hook("idle")` does not: the experimental `idle` Session hook landed in
OpenCode v2.2.1 (release notes, PR #59437, 2026-10-29). The bridge must therefore
keep Stop best-effort on the pinned version and only promise continuation when
the running plugin API actually exposes the idle hook.

## Goals / Non-Goals

**Goals:**

- One source of truth: adding or reordering a hook in Claude settings changes
  OpenCode behaviour with no TypeScript edit.
- Match Claude's settings and matcher semantics closely enough that the same
  hook list runs in both harnesses.
- Preserve every current bridge behaviour, including the extra lifecycle
  handling that has no settings entry (`SubagentStop`, direct notifications).
- Fail open on malformed settings, missing scripts and timeouts.
- Keep the plugin self-contained so the Docker `integration.use` allow-list
  remains a single exact path.
- Make the behaviour testable without a full OpenCode process.

**Non-Goals:**

- Adopting `opencode-claude-code-hooks` as a dependency. Only its settings
  parsing semantics are borrowed.
- Supporting `type: "http"`, `type: "mcp_tool"`, `type: "prompt"`,
  `type: "agent"`, or the `if` handler filter. They are detected and skipped.
- Guaranteeing Stop continuation on OpenCode 2.1.4.
- Reproducing Claude's parallel hook execution. The bridge runs handlers
  sequentially so it can aggregate a single decision.
- Persisting bridge state across container restarts; `~/.claude` stays
  read-only in safe mode.
- Changing hook scripts, agent definitions or the Docker launcher.

## Decisions

### Read settings at runtime, keep one plugin file

Add `loadClaudeSettings(projectDir)` and `hookHandlers(event, toolName, settings)`
inside `claude-hooks.ts`. Read, in order:

1. `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude/settings.json`)
2. `$CLAUDE_CONFIG_DIR/settings.local.json`
3. `<project>/.claude/settings.json`
4. `<project>/.claude/settings.local.json`

`<project>` is `git -C <cwd> rev-parse --show-toplevel` when that succeeds,
otherwise the session cwd (`cwdOf(ctx, session)`); this matches
`CLAUDE_PROJECT_DIR` and keeps worktrees on their own checkout. A file is read
once per `(path, mtimeMs, size)` and cached; a changed mtime invalidates it, so
editing settings takes effect on the next event without an OpenCode restart.
Missing files and `JSON.parse` failures are skipped and logged when
`OPENCODE_HOOKS_DEBUG` is set.

Keeping the logic in the existing file is deliberate: the Docker policy allows
`plugin:/home/agent/.config/opencode/plugins/claude-hooks.ts` and the repo-target
path only (`docker/opencode/config/opencode.jsonc:45-48`). Extracting a
`claude-hooks/` module would require widening `integration.use`, which is a
security-policy change for no user-visible benefit.

Alternative considered: a separate package with unit tests. Rejected because
the plugin has no runtime dependencies today and the policy allow-list is
per-file.

### Merge levels by appending and de-duplicate identical handlers

Claude Code merges hooks across settings levels and runs a handler declared in
several files once. Model that literally:

- flatten each level's `hooks.<Event>[].hooks[]` into `{ event, matcher, handler, source }`;
- concatenate user → user-local → project → project-local;
- drop a later entry when an earlier entry has the same `type` and the same
  `command` plus `args` (the handler identity), keeping the first matcher group
  and timeout;
- within one event, run survivors in that order.

This is "append with dedupe", not "project replaces user". A project that
copies the user's `ban-host-npm.py` entry does not run it twice, while a project
that adds a new script gets it appended.

Alternative considered: project settings replace user hooks per event.
Rejected because Claude Code documents additive merge and a project override
would silently disable the user's guards.

### Mirror Claude's three-way matcher rule

`matchesMatcher(matcher, value)`:

- `undefined`, `""` or `"*"` → match everything;
- a string made only of `[A-Za-z0-9_\- ,|]` → split on `|` or `,`, trim, and
  match any exact value;
- anything else → `new RegExp(matcher).test(value)` (unanchored), compiled once
  per settings load and skipped with a debug line if invalid.

Events without matcher support in Claude (`UserPromptSubmit`, `Stop`,
`StopFailure`) ignore the matcher. For `PreToolUse`/`PostToolUse` the value is
the mapped Claude tool name (`Bash`, `Edit`, `Write`, `Read`, `Grep`, `Glob`,
`Agent`); for `Notification` it is the synthesised notification type; for
`SubagentStop` it is `agent_type`.

### Only `type: "command"` runs, through a shell

`runCommandHandler(handler, payload, cwd)`:

- shell form (no `args`): `spawn("/bin/sh", ["-c", handler.command], …)` so
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/...`, `$CLAUDE_PROJECT_DIR` and
  `~/` expand exactly as they do in Claude Code;
- exec form (`args` present): `spawn(handler.command, handler.args, …)` with no
  shell;
- env: `process.env`, `CLAUDE_CONFIG_DIR`, `CLAUDE_PROJECT_DIR`, and
  `CLAUDE_CODE_ENTRYPOINT=opencode` for diagnostics;
- stdin: `JSON.stringify(payload)`;
- `timeout`: `handler.timeout` seconds × 1000, default 600 s, capped at 900 s;
  on expiry the child is killed and the result is treated as no decision;
- `async: true`: spawn detached, do not await, never contribute a decision;
- `type` other than `command`, missing `command`, or a spawn error: log once and
  skip.

Shell form is the important change. The current `runPython()` builds
`["python3", file]` itself, which cannot express `yas.sh prompt` or the
`"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/yas.sh" prompt` entry already in
`home/linux/.claude/settings.json`.

### Keep host-only hooks as one explicit exception

`HOST_ONLY_SCRIPTS = new Set(["ban-host-npm.py"])`. Before running a handler,
skip it when `IN_CONTAINER` and the command or any `args` element contains that
basename. `OPENCODE_HOOKS_SKIP` may add comma-separated basenames. Everything
else is selected from settings; there is no second hard-coded list.

This is the smallest honest way to preserve the current container behaviour:
`ban-host-npm.py` exists because host npm is redirected into Docker, and inside
the agent container there is no Docker socket to redirect into. A general
"skip in container" flag does not exist in Claude settings, so an explicit
basename list is preferable to silently changing the guard's contract.

### Preserve decision semantics and add `updatedInput`

After every handler, `decide(result)` returns `{ deny?, ask?, allow?, context?,
updatedInput? }`:

- exit 2 → `deny` with trimmed stderr (for `UserPromptSubmit` and `Stop` this is
  a block/continuation reason rather than a tool denial);
- exit 0 with `hookSpecificOutput.permissionDecision === "deny"` → `deny` with
  `permissionDecisionReason`;
- `"ask"` → `ask` with the reason; OpenCode has no permission prompt at the
  tool-hook layer, so log it and continue (the static policy still applies);
- `"allow"` → clear only this hook's objection; it never overrides an OpenCode
  `deny` rule;
- `hookSpecificOutput.updatedInput` (PreToolUse only) → map back to OpenCode
  input with `openCodeInput(tool, input)` and assign `event.input`;
- legacy `decision: "block"` plus `reason` → `deny`;
- `hookSpecificOutput.additionalContext` → `context`.

PreToolUse handlers run sequentially. The first `deny` throws (the existing
`execute.before` rejection path). `updatedInput` from a handler is applied to
`event.input` and re-mapped before the next handler runs, so later hooks see the
rewritten call. PostToolUse `additionalContext` is appended to
`event.result.content`; if that is not possible it is queued. UserPromptSubmit
`additionalContext` is appended to `event.prompt.text`, as today.

`updatedInput` is only applied when the reverse mapping is total for that tool
(shell `command`, read `file_path`/`offset`/`limit`, edit/write `file_path`,
subagent `description`/`prompt`/`subagent_type`). Otherwise log and ignore it
rather than corrupting OpenCode's input.

### Lifecycle: keep SubagentStop, gate Stop on a real capability check

- `prompt` → `UserPromptSubmit` handlers.
- `execute.before` → `PreToolUse` handlers whose matcher matches the mapped
  Claude tool name.
- `execute.after` (status `completed`) → `PostToolUse` handlers; keep the
  current `appendResult` behaviour.
- `compaction` → `PreCompact` handlers with `trigger: "auto"`.
- `session.execution.succeeded` / `session.idle` for a child session →
  `SubagentStop` with `session_id` set to `parentID`, `agent_id` to the child,
  and `last_assistant_message` from `lastAssistant()`. `additionalContext` is
  queued on the parent, never the child.
- the same event for a main session → `Stop` handlers with
  `last_assistant_message` and `stop_hook_active: false`. On 2.1.4 a
  `decision: "block"` from Stop cannot resume the session: log it and surface the
  reason through the existing notification path. Do not promise continuation.
- `session.execution.failed` → `StopFailure` handlers plus the current
  `notify(..., "Error", ..., "critical")`.
- Notification: keep `notify()` as the direct `agent-notify.py send` path used
  for done/error/subagent-done, and additionally run `Notification` handlers for
  synthesised `agent_completed` events. There is no OpenCode event for
  permission prompts, so `permission_prompt` handlers remain best-effort and
  never fire from this bridge.

Continuation support is decided once at setup:
`supportsIdleHook = semverAtLeast(ctx.app?.version, "2.2.1")`. When true, also
register `ctx.session.hook("idle", …)` and, on a Stop handler's block decision,
admit `ctx.session.synthetic({ sessionID, text: reason })`. When false, register
nothing extra; the event-stream path above remains. This keeps the change
shippable on the pinned 2.1.4 image and lets a later version bump turn Stop
continuation on without a rewrite.

Alternative considered: rely on `session.execution.succeeded` alone and ignore
the version. Rejected because the current implementation already races a new
prompt against user input and produces duplicate idle notifications; the idle
hook is the correct surface when it exists.

### Test with fixtures, not the network or a live model

Add `docker/opencode/test/claude-hooks.mjs`, driven by
`docker/opencode/test/claude-hooks.sh` (`node --experimental-strip-types`), in
the style of the existing `plugin-harness.mjs`:

- create a temp `CLAUDE_CONFIG_DIR` with `settings.json`, `settings.local.json`
  and `hooks/` fixture scripts (`#!/bin/sh`, read stdin, print JSON or exit 2);
- create a temp git-style project with `.claude/settings.json` and
  `.claude/settings.local.json`;
- import the plugin with the same `@opencode/plugin` shim used by
  `plugin-harness.mjs`, capture the registered hooks, and invoke them with
  synthetic events;
- assert matcher selection, user/project append and dedupe, exit 2, structured
  deny, `additionalContext`, `updatedInput`, SubagentStop parent routing,
  container skip (`OPENCODE_CONTAINER=1`), missing script (fail open) and
  timeout (fail open).

Add `test-hooks` to `docker/opencode/Makefile` and to `test-all`.

## Risks / Trade-offs

- **Project settings become executable code inside OpenCode.** → The container
  mounts arbitrary repositories. Default project settings to off when
  `OPENCODE_CONTAINER=1` or `/.dockerenv` is present; require
  `OPENCODE_HOOKS_TRUST_PROJECT=1` to enable them. Host OpenCode keeps project
  settings on, matching Claude Code. Document this asymmetry.
- **Sequential handlers add latency to every tool call.** → Cache parsed
  settings, keep the handler list small, and run `async: true` handlers
  detached. Timeouts are bounded.
- **A handler can outlive a timeout through grandchildren.** → Kill the direct
  child on timeout; document that a shell that daemonises a process is outside
  the bridge's control. No container policy change.
- **Regex matchers from settings can be catastrophic.** → Compile once, cap the
  pattern length (256), and skip invalid patterns.
- **`updatedInput` reverse mapping can lose OpenCode-only fields.** → Apply only
  on the total mappings listed above; otherwise ignore and log.
- **Read-only `~/.claude` loses hook state in the container.** → Existing
  behaviour; keep the current README warning and do not add state to
  `$CLAUDE_CONFIG_DIR`.
- **Hook command strings may contain secrets.** → Debug logging records the
  event, handler source and exit code, never the command string or environment.

## Migration Plan

1. Land the loader and runner behind the existing plugin path; behaviour is
   identical when settings match today's hard-coded list.
2. Run `node docker/opencode/test/claude-hooks.mjs` and
   `make test-hooks`; then `make test-guardrails` to confirm the unchanged
   plugin path still loads.
3. Rebuild the image and run `make test-stack`; confirm `skill-nudge.py` still
   fires from the settings-derived UserPromptSubmit entry.
4. Rollback is a revert of the plugin commit: the old hard-coded lists remain
   in git history and the Docker policy path does not change.

## Open Questions

- Should `OPENCODE_HOOKS_TRUST_PROJECT` default to on outside containers even
  for a cloned untrusted repo? The design keeps host behaviour aligned with
  Claude Code (project hooks run) and relies on the user's own review of the
  repo.
- Should the Docker image move to OpenCode >= 2.2.1 in this change to enable
  Stop continuation, or stay on 2.1.4 and defer? The design defers; the version
  gate makes the upgrade a one-line change later.
- Is `{type, command, args}` sufficient for Claude's "identical handler runs
  once" rule, or should `timeout`/`async` participate in identity? The design
  treats only invocation identity as significant, so a timeout-only difference
  is de-duplicated.
