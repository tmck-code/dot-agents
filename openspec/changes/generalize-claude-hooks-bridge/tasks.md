## 1. Baseline and in-file refactor

- [ ] 1.1 In `home/general/.config/opencode/plugins/claude-hooks.ts`, record the current behaviour in a short comment block above `PRE_TOOL`: five PreToolUse scripts, two PostToolUse scripts, three lifecycle scripts in `onIdle`, and the direct `agent-notify.py send` path.
- [ ] 1.2 Extract the existing payload helpers (`CLAUDE_TOOL`, `claudeToolName`, `claudeInput`, `basePayload`, `toolPayload`) so they are exported as a `__testing` object at the end of the file; do not change their output yet.
- [ ] 1.3 Extract `decide`, `enqueue`, `drain`, `getSession`, `cwdOf`, `lastAssistant`, `summarise` and `appendResult` into named functions that the test harness can call, preserving their current signatures.
- [ ] 1.4 Keep the plugin's default export and `id: "claude-hooks"` unchanged so `docker/opencode/config/opencode.jsonc` lines 45-48 keep matching both the symlink and repo-target plugin paths.
- [ ] 1.5 Add `const PROJECT_DIR = process.env.CLAUDE_PROJECT_DIR || ctx.location?.directory` handling inside `setup` rather than at module load; a module-level constant would freeze the first session's directory.

## 2. Runtime settings loader

- [ ] 2.1 Add `type HookHandler = { type?: string; command?: string; args?: string[]; timeout?: number; async?: boolean; if?: string }` and `type HookGroup = { matcher?: string; hooks?: HookHandler[] }` to `claude-hooks.ts`.
- [ ] 2.2 Implement `settingsPaths(projectDir: string): string[]` returning `$CLAUDE_CONFIG_DIR/settings.json`, `$CLAUDE_CONFIG_DIR/settings.local.json`, `<projectDir>/.claude/settings.json`, `<projectDir>/.claude/settings.local.json` in that order.
- [ ] 2.3 Implement `projectRoot(cwd: string): string` using `git -C <cwd> rev-parse --show-toplevel` with a synchronous `spawnSync` fallback to `cwd`; do not throw on a non-git directory.
- [ ] 2.4 Implement `loadSettingsFile(path)` using `readFileSync` plus `JSON.parse` in a `try/catch`; cache by `(path, mtimeMs, size)` in a module-level `Map` so a changed file is re-read on the next call.
- [ ] 2.5 Implement `loadClaudeSettings(projectDir): Map<string, HookGroup[]>` that flattens `settings.hooks` per event and skips missing or malformed files.
- [ ] 2.6 Gate project-level files on `!IN_CONTAINER || process.env.OPENCODE_HOOKS_TRUST_PROJECT === "1"`; always include the two user-level files.
- [ ] 2.7 Implement `dedupeHandlers(groups)` using the handler identity `type + "\0" + command + "\0" + (args ?? []).join("\0")`; keep the first matcher and timeout and drop later duplicates.
- [ ] 2.8 Return the merged list in user → user-local → project → project-local order, and add a `source` field (`user`, `user-local`, `project`, `project-local`) for debug output.

## 3. Matcher and command runner

- [ ] 3.1 Implement `matchesMatcher(matcher: string | undefined, value: string): boolean` with the three-way rule: `undefined`/`""`/`"*"` match all; `/^[A-Za-z0-9_\- ,|]+$/` splits on `|` or `,` and trims; otherwise compile `new RegExp(matcher)` and call `.test(value)`.
- [ ] 3.2 Compile regex matchers once per settings load (cache by matcher string), skip patterns longer than 256 characters, and catch `SyntaxError` with a debug line.
- [ ] 3.3 Implement `eventUsesMatcher(event)` returning `false` for `UserPromptSubmit`, `Stop` and `StopFailure` so their matcher field is ignored.
- [ ] 3.4 Implement `handlerTimeout(handler)` returning `Math.min((handler.timeout ?? 600) * 1000, 900_000)`; convert Claude's seconds to milliseconds exactly once.
- [ ] 3.5 Implement `runCommandHandler(handler, payload, cwd)` supporting shell form via `spawn("/bin/sh", ["-c", handler.command], ...)` and exec form via `spawn(handler.command, handler.args, ...)`; pipe `JSON.stringify(payload)` to stdin and resolve `{ code, stdout, stderr, timedOut }`.
- [ ] 3.6 Set the child environment to `{ ...process.env, CLAUDE_CONFIG_DIR: CLAUDE_DIR, CLAUDE_PROJECT_DIR: cwd, CLAUDE_CODE_ENTRYPOINT: "opencode" }` and run with `cwd` and `AbortSignal.timeout(handlerTimeout(handler))`.
- [ ] 3.7 Treat `async: true` as fire-and-forget: spawn with `detached: true`, `unref()` the child, and resolve `{ code: 0 }` immediately so it cannot contribute a decision.
- [ ] 3.8 Return `{ code: 0 }` on spawn error, missing `command`, non-`command` type, or timeout, and write a debug line that names the event and source but not the command string.
- [ ] 3.9 Delete `runPython`, `runHook` and the `PRE_TOOL` constant once no call site uses them; keep `script()` only if `notify()` still needs a resolved `agent-notify.py` path.

## 4. Event wiring

- [ ] 4.1 In `setup`, call `const settings = loadClaudeSettings(projectDir)` lazily per event (or via `currentSettings(projectDir)`) so edits are picked up without restarting OpenCode.
- [ ] 4.2 Rewrite `ctx.session.hook("prompt")` to select `UserPromptSubmit` groups whose matcher is ignored, build `{ ...basePayload(session, cwd, "UserPromptSubmit"), prompt: event.prompt.text }`, and append any `additionalContext` to `event.prompt.text`.
- [ ] 4.3 Rewrite `ctx.tool.hook("execute.before")` to select `PreToolUse` groups matching `claudeToolName(event.tool)`, run handlers sequentially, and keep `throw new Error(deny)` as the rejection path.
- [ ] 4.4 Rewrite `ctx.tool.hook("execute.after")` to select `PostToolUse` groups matching the mapped tool name for `event.status === "completed"`, and replace the hard-coded `same-file-write-audit.py` / `subagent-report-announce.py` calls.
- [ ] 4.5 Rewrite `ctx.session.hook("compaction")` to run `PreCompact` groups with `{ ...basePayload(session, cwd, "PreCompact"), trigger: "auto" }`, replacing the direct `precompact-probe.py` call.
- [ ] 4.6 Keep `ctx.session.hook("context")` as the single drain point for `pendingContext`, unchanged in behaviour.

## 5. Decisions, payloads and input rewriting

- [ ] 5.1 Extend `decide(result)` to return `{ deny?, ask?, allow?, context?, updatedInput? }`, covering exit 2, `hookSpecificOutput.permissionDecision` (`deny`/`ask`/`allow`), legacy top-level `decision: "block"` with `reason`, and `hookSpecificOutput.updatedInput`.
- [ ] 5.2 Add `openCodeInput(tool: string, input: Record<string, unknown>)` as the inverse of `claudeInput`: `Bash` → `{ command, background }`, `Read` → `{ path, offset, limit }`, `Edit`/`Write` → `{ path }`, `Grep`/`Glob` → `{ ...input, path: file_path }`, `Agent` → `{ description, prompt, agent: subagent_type }`.
- [ ] 5.3 In `execute.before`, apply a handler's `updatedInput` to `event.input`, rebuild `toolPayload(...)` for subsequent handlers, and ignore the rewrite with a debug line when `openCodeInput` cannot map the tool.
- [ ] 5.4 Keep the `deny` short-circuit: the first denying handler throws and later handlers do not run.
- [ ] 5.5 Extend `basePayload` with `transcript_path` omitted (OpenCode has no path) and a `tool_response` field in `PostToolUse` derived best-effort from `event.result`.
- [ ] 5.6 Preserve the current `additionalContext` behaviour: prompt append for `UserPromptSubmit`, `appendResult` then `enqueue` fallback for `PostToolUse`, and `enqueue` for `PreToolUse` contexts collected after all handlers pass.

## 6. Lifecycle fidelity

- [ ] 6.1 In `onIdle`, select `SubagentStop` groups for child sessions and build the existing payload (`session_id` = `parentID`, `agent_id` = child id, `agent_type`, `last_assistant_message`, `stop_hook_active: false`).
- [ ] 6.2 Run the selected `SubagentStop` handlers sequentially, keep the `lastCaptured` de-duplication, and enqueue any `additionalContext` on `parentID`.
- [ ] 6.3 Select `Stop` groups for a main session on `session.execution.succeeded` / `session.idle` and run them with `last_assistant_message` and `stop_hook_active: false`.
- [ ] 6.4 Add `supportsIdleHook(version)` comparing `ctx.app?.version` against `2.2.1`; when true, register `ctx.session.hook("idle", ...)` and admit a blocked Stop reason with `ctx.session.synthetic({ sessionID, text: reason })`.
- [ ] 6.5 When `supportsIdleHook` is false, log the Stop block reason and surface it through the existing `notify(...)` call; do not admit a new prompt.
- [ ] 6.6 On `session.execution.failed`, select `StopFailure` groups, run them with the error message, and keep the existing `notify(..., "Error", ..., "critical")`.
- [ ] 6.7 Keep `notify()` as the direct `agent-notify.py send` path and add a synthesised `Notification` pass only for `agent_completed`; do not claim `permission_prompt` support.
- [ ] 6.8 Keep the `lastIdle` 1.5-second guard and the `controller.abort()` cleanup in the returned teardown function.

## 7. Container policy and host-only guard

- [ ] 7.1 Add `HOST_ONLY_SCRIPTS = new Set(["ban-host-npm.py"])` and skip a handler in `IN_CONTAINER` when `handler.command` or any `args` entry contains one of those basenames.
- [ ] 7.2 Allow `OPENCODE_HOOKS_SKIP` (comma-separated basenames) to extend `HOST_ONLY_SCRIPTS` without editing the plugin.
- [ ] 7.3 Confirm `docker/opencode/config/opencode.jsonc` still allows `plugin:/home/agent/.config/opencode/plugins/claude-hooks.ts` and `plugin:/home/freman/dev/dot-agents/home/general/.config/opencode/plugins/claude-hooks.ts`; no new path is added.
- [ ] 7.4 Confirm the Dockerfile still mounts `~/.claude` read-only in safe mode and that no bridge code writes to `$CLAUDE_CONFIG_DIR`; state loss remains documented, not fixed.

## 8. Fixture harness

- [ ] 8.1 Add `docker/opencode/test/claude-hooks.sh` mirroring `guardrails.sh`: require Node >= 22.6 and run `node --experimental-strip-types ./test/claude-hooks.mjs`.
- [ ] 8.2 Add `docker/opencode/test/claude-hooks.mjs` with the `@opencode/plugin` shim from `plugin-harness.mjs`, a temp `CLAUDE_CONFIG_DIR`, a temp project with a `.git` directory, and a `makeCtx()` that captures `session`, `tool` and `event` registrations.
- [ ] 8.3 Add fixture handlers under the temp hooks directory: `exit2.sh` (exit 2 with stderr), `deny.sh` (structured deny), `context.sh` (additionalContext), `rewrite.sh` (updatedInput), `slow.sh` (`sleep 5`), `subagent.sh` and `notify.sh`; keep each one small and shell-only.
- [ ] 8.4 Assert matcher selection: a `Bash`-only handler runs for `shell` but not `read`, and `Edit|Write` runs for `edit` and `write` but not `read`.
- [ ] 8.5 Assert user/project merge and de-duplication: a project-only handler runs after a user handler, and an identical command in both files runs once.
- [ ] 8.6 Assert exit 2 and structured deny both reject `execute.before` with the expected message.
- [ ] 8.7 Assert `additionalContext` is appended to the prompt, appended to a PostToolUse result, and drained through the `context` hook.
- [ ] 8.8 Assert `updatedInput` from `rewrite.sh` changes `event.input` and that a second handler's stdin contains the rewritten `tool_input`.
- [ ] 8.9 Assert SubagentStop: a child-session idle event runs the handler with the parent id and enqueues context on the parent.
- [ ] 8.10 Assert container behaviour: with `OPENCODE_CONTAINER=1`, `ban-host-npm.py` is skipped while `no-long-sleep.py` runs, and project settings are ignored unless `OPENCODE_HOOKS_TRUST_PROJECT=1`.
- [ ] 8.11 Assert fail-open: a missing script and `slow.sh` with `timeout: 0.1` both leave the event unblocked.
- [ ] 8.12 Assert malformed settings: an invalid `settings.json` is skipped while a valid `settings.local.json` still runs its hook.
- [ ] 8.13 Add a `test-hooks` target to `docker/opencode/Makefile` and include it in `test-all`; document the command in the README.

## 9. Documentation and validation

- [ ] 9.1 Update `docker/opencode/README.md` "Claude Code hooks in OpenCode": describe settings-driven selection, the four files, matcher semantics, timeout units, async handlers, project-settings trust in the container, and the `ban-host-npm.py` exception.
- [ ] 9.2 Replace the README's OpenCode 2.1.4 Stop wording with the verified fact that `experimental.idle` arrived in 2.2.1, so Stop is notification-only on the pinned image and continuation activates after a version bump.
- [ ] 9.3 Update `docs/opencode-port.md` section 6 and the table around line 263: replace the hard-coded hook list description with runtime settings loading, and note that `opencode-claude-code-hooks` was used as a semantics reference only.
- [ ] 9.4 Document `OPENCODE_HOOKS_DEBUG`, `OPENCODE_HOOKS_SKIP` and `OPENCODE_HOOKS_TRUST_PROJECT` in both docs, including where the debug log is written.
- [ ] 9.5 Run `openspec validate generalize-claude-hooks-bridge --strict` and fix any artifact errors.
