## ADDED Requirements

### Requirement: Runtime Claude settings discovery
The bridge SHALL read Claude hook configuration at runtime from
`$CLAUDE_CONFIG_DIR/settings.json`, `$CLAUDE_CONFIG_DIR/settings.local.json`,
`<project>/.claude/settings.json` and `<project>/.claude/settings.local.json`,
where `<project>` is the git top level of the session directory or that
directory when it is not a git checkout.

#### Scenario: User settings drive a hook
- **WHEN** `~/.claude/settings.json` declares a `PreToolUse` matcher for `Bash` with a command
- **THEN** the bridge runs that command for an OpenCode `shell` tool call without any TypeScript change

#### Scenario: Project settings are discovered
- **WHEN** the session directory is inside a git checkout whose `.claude/settings.json` declares a `PostToolUse` matcher for `Edit|Write`
- **THEN** the bridge loads that file in addition to the user settings

#### Scenario: Missing or malformed settings do not break startup
- **WHEN** a settings file is absent, unreadable or contains invalid JSON
- **THEN** the bridge skips that file, keeps the remaining settings, and OpenCode starts normally

#### Scenario: Settings edits take effect without a restart
- **WHEN** a settings file's mtime or size changes while a session is running
- **THEN** the next event re-reads that file and uses the new hook list

### Requirement: Claude-compatible merge and precedence
The bridge SHALL merge hook entries across settings levels by appending them in
the order user, user-local, project, project-local, and SHALL run a handler
declared in more than one file only once, keeping the first declaration's
matcher and timeout.

#### Scenario: Project hooks are appended
- **WHEN** the user settings declare one `PreToolUse` command and the project settings declare another
- **THEN** both commands run, user first

#### Scenario: Duplicate handler runs once
- **WHEN** the user settings and the project settings declare the same command with the same matcher
- **THEN** the command runs once for a matching tool call

#### Scenario: Project hooks are not a wholesale replacement
- **WHEN** the project settings declare only a new `PreToolUse` command
- **THEN** the user's existing `PreToolUse` commands still run

### Requirement: Claude matcher selection
The bridge SHALL select matcher groups using Claude Code's matcher rules: an
omitted, empty or `*` matcher matches every occurrence; a matcher containing
only letters, digits, `_`, `-`, spaces, commas and `|` is a list of exact values
split on `|` or `,`; any other matcher is an unanchored JavaScript regular
expression. Events that Claude defines without matcher support SHALL ignore the
matcher field.

#### Scenario: Exact tool matcher
- **WHEN** a `PreToolUse` matcher is `Edit|Write` and OpenCode runs the `edit` tool
- **THEN** the group runs and a `read` tool call does not run it

#### Scenario: Comma-separated exact matcher
- **WHEN** a matcher is `Edit, Write` and OpenCode runs the `write` tool
- **THEN** the group runs

#### Scenario: Regular-expression matcher
- **WHEN** a matcher is `^Note.*` and the mapped Claude tool name is `NotebookEdit`
- **THEN** the group runs

#### Scenario: Matcherless event
- **WHEN** a `UserPromptSubmit` or `Stop` entry carries a matcher
- **THEN** the bridge ignores the matcher and runs the group for every occurrence of that event

#### Scenario: Invalid regular expression
- **WHEN** a matcher is not a valid regular expression
- **THEN** the bridge skips that group, logs a debug line and continues with other groups

### Requirement: Command handler execution
The bridge SHALL execute only `type: "command"` handlers. A handler without
`args` SHALL run through `/bin/sh -c`; a handler with `args` SHALL spawn the
command and arguments directly. The bridge SHALL pass the Claude-shaped payload
on stdin, run in the session working directory, set `CLAUDE_CONFIG_DIR` and
`CLAUDE_PROJECT_DIR`, and honour `timeout` in seconds, `async`, and the 600-second
default timeout.

#### Scenario: Shell expansion matches Claude
- **WHEN** a handler command is `python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/skill-nudge.py"`
- **THEN** the shell expands `CLAUDE_CONFIG_DIR` and the script runs with the payload on stdin

#### Scenario: Exec form avoids a shell
- **WHEN** a handler sets `command` and `args`
- **THEN** the bridge spawns the command with those arguments and does not interpret shell metacharacters

#### Scenario: Async handler does not block the event
- **WHEN** a handler sets `async: true`
- **THEN** the bridge starts it without awaiting it and the event continues immediately

#### Scenario: Timeout fails open
- **WHEN** a handler runs longer than its configured timeout
- **THEN** the bridge kills the child, records no decision and the tool call or prompt continues

#### Scenario: Missing script fails open
- **WHEN** a handler command cannot be spawned or exits 127 because the script is absent
- **THEN** the bridge records no decision, logs a debug line and the event continues

### Requirement: Unsupported handler surfaces are skipped
The bridge SHALL skip handlers whose `type` is `http`, `mcp_tool`, `prompt` or
`agent`, and SHALL ignore the per-handler `if` field, because OpenCode has no
equivalent surface for them in this change.

#### Scenario: HTTP hook is skipped
- **WHEN** a settings file declares a `type: "http"` handler
- **THEN** the bridge does not make an HTTP request and the event continues

#### Scenario: Conditional hook is not evaluated
- **WHEN** a `PreToolUse` handler sets `if: "Bash(git *)"`
- **THEN** the bridge ignores the condition and runs the handler whenever its matcher matches

### Requirement: Container project-settings trust boundary
The bridge SHALL always load the user-level settings, and SHALL NOT run
project-level hook settings inside the agent container unless
`OPENCODE_HOOKS_TRUST_PROJECT=1` is set. On the host, project settings SHALL run
by default.

#### Scenario: Container ignores an untrusted project hook
- **WHEN** `OPENCODE_CONTAINER=1` is set and a mounted repository declares a project `.claude/settings.json` hook
- **THEN** the bridge loads the user hooks but does not run the project hook

#### Scenario: Container runs an explicitly trusted project hook
- **WHEN** `OPENCODE_CONTAINER=1` and `OPENCODE_HOOKS_TRUST_PROJECT=1` are both set
- **THEN** the bridge loads and runs project hooks as on the host

#### Scenario: Host runs project hooks
- **WHEN** OpenCode runs on the host and the repository declares a project hook
- **THEN** the bridge runs it after the user hooks
