## Why

The committed OpenCode bridge (`home/general/.config/opencode/plugins/claude-hooks.ts`,
commit `6359d00`) hard-codes five PreToolUse scripts and three PostToolUse
scripts, so every new or reordered hook in `~/.claude/settings.json` has to be
mirrored by hand in TypeScript. The Python hooks are already the single source of
truth for Claude Code; OpenCode should honour the same settings file instead of a
second, drifting list.

## What Changes

- Replace the bridge's `PRE_TOOL` constant and the hard-coded per-event script
  calls with a runtime loader for `~/.claude/settings.json`,
  `~/.claude/settings.local.json`, `<git-root>/.claude/settings.json` and
  `<git-root>/.claude/settings.local.json`.
- Parse the `hooks` map by event and matcher, merge levels the way Claude Code
  does (append, identical handlers run once), and run `type: "command"`
  handlers with the Claude-shaped stdin payload.
- Execute shell-form commands through `/bin/sh -c` and exec-form commands
  (`args`) directly; apply per-handler `timeout` (seconds), `async`, and the
  `CLAUDE_CONFIG_DIR` / `CLAUDE_PROJECT_DIR` environment.
- Preserve the current decision and lifecycle behaviour: exit 2 + stderr,
  structured `permissionDecision` (`deny`/`ask`/`allow`), legacy
  `decision: "block"`, `additionalContext` queueing, `updatedInput` replacement,
  SubagentStop routing to the parent, Stop/StopFailure best-effort, and the
  direct `agent-notify.py send` notification path.
- Keep the container exception narrow and explicit: skip only
  `ban-host-npm.py` when `OPENCODE_CONTAINER=1` or `/.dockerenv` exists. Do not
  run project settings inside the container unless explicitly trusted.
- Add a fixture-driven Node harness (`docker/opencode/test/claude-hooks.mjs`)
  covering matcher selection, level precedence, exit 2, structured deny,
  `additionalContext`, `updatedInput`, SubagentStop parent routing, container
  skip, missing handlers and timeouts, with a `make test-hooks` target.
- Update `docker/opencode/README.md` and `docs/opencode-port.md` with the runtime
  settings behaviour, the container trust boundary and the Stop limitation.
- No new plugin file and no new runtime dependency: the Docker
  `integration.use` allow-list in `docker/opencode/config/opencode.jsonc` keeps
  naming the same single plugin path.

## Capabilities

### New Capabilities

- `claude-hook-settings`: runtime discovery, merge/precedence, matcher
  selection, command execution and the project-settings trust boundary for
  Claude hooks under OpenCode.
- `claude-hook-fidelity`: Claude-shaped payloads, blocking/allow decisions,
  `updatedInput`, `additionalContext` delivery, lifecycle events, SubagentStop
  parent routing and the container host-only guard.

### Modified Capabilities

<!-- No baseline specs exist; openspec/specs/ is empty because
     secure-opencode-runtime and add-llama-cpp-local-model are not archived.
     The bridge is therefore captured as two new capabilities. -->

## Impact

- `home/general/.config/opencode/plugins/claude-hooks.ts`: replaced hard-coded
  hook lists with settings loading, matcher evaluation and a generic command
  runner; existing payload/decision helpers are extended rather than rewritten.
- `docker/opencode/test/claude-hooks.mjs` and `docker/opencode/test/claude-hooks.sh`:
  new fixture harness and wrapper.
- `docker/opencode/Makefile`: new `test-hooks` target, included in `test-all`.
- `docker/opencode/README.md`, `docs/opencode-port.md`: document runtime
  settings, project-settings trust and the OpenCode 2.1.4 Stop limitation.
- `docker/opencode/config/opencode.jsonc`: no path change expected; verify the
  single-plugin allow-list still covers the bridge.
- Behaviour change: hooks added to `settings.json` now run under OpenCode
  without a code change. In the container, project-level hooks are opt-in
  because the mounted repository is not trusted the way the user's dotfiles are.
