## ADDED Requirements

### Requirement: Claude-shaped payloads and tool mapping
The bridge SHALL synthesise Claude Code hook payloads for every supported event
and SHALL map OpenCode tool names and inputs to their Claude equivalents:
`shell`/`bash` to `Bash`, `read` to `Read`, `edit`/`write`/`patch` to
`Edit`/`Write`, `grep` to `Grep`, `glob` to `Glob`, and `subagent`/`task` to
`Agent`. `agent_id` and `agent_type` SHALL be populated only for child sessions.

#### Scenario: Shell call becomes Bash
- **WHEN** OpenCode runs `shell` with `{ command, background }`
- **THEN** the hook receives `tool_name: "Bash"` and `tool_input: { command, run_in_background }`

#### Scenario: File call becomes Edit
- **WHEN** OpenCode runs `edit` with `{ path }`
- **THEN** the hook receives `tool_name: "Edit"` and `tool_input: { file_path }`

#### Scenario: Main session has no agent identity
- **WHEN** a hook runs for a main-thread tool call
- **THEN** `agent_id` and `agent_type` are absent from the payload

#### Scenario: Subagent call carries agent identity
- **WHEN** a hook runs for a tool call in a session with a `parentID`
- **THEN** `agent_id` is the child session id and `agent_type` is the child's agent name

#### Scenario: Prompt payload carries the prompt
- **WHEN** the `prompt` hook runs
- **THEN** the `UserPromptSubmit` payload contains `session_id`, `cwd` and the prompt text

### Requirement: Blocking and allow decisions
The bridge SHALL treat exit code 2 with stderr as a block reason, exit 0 with
`hookSpecificOutput.permissionDecision` `deny` or legacy `decision: "block"` as
a block, and `permissionDecision: "allow"` as clearing only the hook's
objection. A hook `allow` SHALL NOT override an OpenCode permission `deny`.

#### Scenario: Exit 2 blocks a tool call
- **WHEN** a `PreToolUse` hook exits 2 with `do not sleep`
- **THEN** the OpenCode tool call is rejected with `do not sleep` as the error

#### Scenario: Structured deny blocks a tool call
- **WHEN** a `PreToolUse` hook exits 0 with `permissionDecision: "deny"` and a reason
- **THEN** the tool call is rejected with that reason

#### Scenario: Legacy block decision blocks
- **WHEN** a hook exits 0 with `decision: "block"` and a `reason`
- **THEN** the bridge treats it as a deny with that reason

#### Scenario: Allow does not bypass policy
- **WHEN** a hook returns `permissionDecision: "allow"` for a path denied by the OpenCode system policy
- **THEN** the tool call is still denied by OpenCode

#### Scenario: Ask is reported but not prompted
- **WHEN** a hook returns `permissionDecision: "ask"`
- **THEN** the bridge logs the reason and continues without an interactive prompt

### Requirement: updatedInput replacement
For `PreToolUse`, the bridge SHALL apply
`hookSpecificOutput.updatedInput` by mapping it back to OpenCode's tool input
and assigning it to the event, and SHALL re-map that input before running the
next matching handler. It SHALL ignore `updatedInput` when the reverse mapping
for that tool is not total.

#### Scenario: Command is rewritten
- **WHEN** a `PreToolUse` hook for `Bash` returns `updatedInput: { command: "npm test" }`
- **THEN** OpenCode executes `npm test` instead of the original command

#### Scenario: Later hook sees the rewrite
- **WHEN** a second matching `PreToolUse` hook runs after a rewrite
- **THEN** its stdin payload contains the rewritten `tool_input`

#### Scenario: Unmappable rewrite is ignored
- **WHEN** a hook returns `updatedInput` containing fields the bridge cannot map for that tool
- **THEN** the original OpenCode input is left unchanged and a debug line is written

### Requirement: additionalContext delivery
The bridge SHALL deliver `additionalContext` without a native OpenCode channel:
appending it to the prompt for `UserPromptSubmit`, appending it to the tool
result for `PostToolUse` when possible, and queueing it for the session's next
model call otherwise. A `SubagentStop` context SHALL be queued on the parent
session, never the child.

#### Scenario: Prompt context is appended
- **WHEN** a `UserPromptSubmit` hook returns `additionalContext`
- **THEN** the text is appended to the prompt before the model sees it

#### Scenario: Post-tool context is appended to the result
- **WHEN** a `PostToolUse` hook returns `additionalContext` and the result has text content
- **THEN** the text is appended to the tool result content

#### Scenario: Context falls back to the queue
- **WHEN** a hook returns `additionalContext` that cannot be attached to a result
- **THEN** it is queued and added as a system part on the session's next model call

#### Scenario: Subagent context reaches the parent
- **WHEN** a `SubagentStop` hook returns `additionalContext`
- **THEN** the next model call in the parent session receives it and the child session does not

### Requirement: Lifecycle event fidelity
The bridge SHALL run `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and
`PreCompact` handlers from settings, SHALL run `SubagentStop` handlers when a
child session reaches a terminal idle event, and SHALL run `Stop` and
`StopFailure` handlers on the corresponding main-session events. `Stop`
continuation SHALL be attempted only when the running OpenCode plugin API
exposes the experimental `idle` session hook.

#### Scenario: PreCompact runs before compaction
- **WHEN** OpenCode starts a compaction
- **THEN** the `PreCompact` handlers run with `trigger: "auto"`

#### Scenario: SubagentStop routes to the parent
- **WHEN** a child session finishes and `lastAssistant()` returns its final text
- **THEN** `SubagentStop` handlers receive `session_id` equal to the parent id, `agent_id` equal to the child id, and the final text as `last_assistant_message`

#### Scenario: Stop runs on a completed main session
- **WHEN** a main session emits `session.execution.succeeded` or `session.idle`
- **THEN** the `Stop` handlers run with `last_assistant_message` and `stop_hook_active: false`

#### Scenario: Stop block is best-effort on 2.1.4
- **WHEN** the running OpenCode version does not expose the `idle` session hook and a `Stop` handler blocks
- **THEN** the bridge logs and surfaces the reason without promising to resume the session

#### Scenario: Stop continuation on a capable version
- **WHEN** the running OpenCode version exposes the `idle` session hook and a `Stop` handler blocks
- **THEN** the bridge admits the reason with `ctx.session.synthetic` and the session continues

#### Scenario: StopFailure runs on failure
- **WHEN** a main session emits `session.execution.failed`
- **THEN** the `StopFailure` handlers run with the error message and the existing critical notification fires

### Requirement: Notification best-effort
The bridge SHALL keep the direct `agent-notify.py send` path for done, error and
subagent-done notifications, and SHALL run `Notification` handlers only for
notification types it can synthesise. It SHALL NOT claim to observe OpenCode
permission prompts.

#### Scenario: Done notification still fires
- **WHEN** a main session completes
- **THEN** the bridge invokes `agent-notify.py send` with the existing project, title and body arguments

#### Scenario: Permission notification does not fire
- **WHEN** the settings declare a `Notification` matcher for `permission_prompt`
- **THEN** the bridge does not synthesise that event because OpenCode exposes no permission-prompt event

### Requirement: Container host-only guard
The bridge SHALL skip the host-only `ban-host-npm.py` handler when
`OPENCODE_CONTAINER=1` or `/.dockerenv` exists, and SHALL run every other
settings-derived handler subject to the project trust boundary.

#### Scenario: Host npm guard is skipped in the container
- **WHEN** `OPENCODE_CONTAINER=1` and the settings declare `ban-host-npm.py` for `Bash`
- **THEN** the bridge does not run that handler

#### Scenario: Other guards still run in the container
- **WHEN** `OPENCODE_CONTAINER=1` and the settings declare `no-long-sleep.py` and `subagent-git-tree-guard.py`
- **THEN** the bridge runs both for matching `Bash` calls

#### Scenario: Host runs the npm guard
- **WHEN** OpenCode runs on the host
- **THEN** the bridge runs `ban-host-npm.py` for matching `Bash` calls

### Requirement: Fail-open and diagnostics
The bridge SHALL never block an OpenCode event because of a missing settings
file, malformed JSON, an unspawnable command, an invalid matcher or a timeout.
When `OPENCODE_HOOKS_DEBUG` is set it SHALL log the event, the handler source and
the exit code, and SHALL NOT log the command string or the child environment.

#### Scenario: Broken settings never wedge a call
- **WHEN** every settings file is malformed and a tool call runs
- **THEN** the tool call completes normally

#### Scenario: Debug log omits the command
- **WHEN** `OPENCODE_HOOKS_DEBUG=1` and a handler runs
- **THEN** the log records the event and exit code but not the handler command string
