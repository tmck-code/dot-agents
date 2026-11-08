## ADDED Requirements

### Requirement: System policy cannot be overridden by a project
OpenCode SHALL load hard policies from `/etc/opencode/opencode.jsonc` that a project or user configuration cannot re-enable. Policies SHALL deny unapproved providers, dangerous tool resources and unapproved integrations.

#### Scenario: Repository cannot re-enable a denied provider
- **WHEN** a project config allows a provider denied by the system policy
- **THEN** the provider remains denied

#### Scenario: Denied shell command is hard-blocked
- **WHEN** the agent attempts `sudo` or another system-denied shell command
- **THEN** OpenCode refuses the action without prompting

#### Scenario: System policy is read-only
- **WHEN** the agent tries to edit `/etc/opencode/opencode.jsonc`
- **THEN** the write fails

### Requirement: Least-privilege permissions
OpenCode permissions SHALL deny reads and edits of protected paths (`.env*`, `.ssh`, key files, `auth.json`, vault files) and SHALL require explicit approval or denial for paths outside the workspace. Shell SHALL remain usable inside the container boundary.

#### Scenario: Env file is protected
- **WHEN** the agent attempts to read `.env` or `.env.local`
- **THEN** the action is denied by policy

#### Scenario: SSH material is protected
- **WHEN** the agent attempts to read a private key or `~/.ssh` content
- **THEN** the action is denied by policy

#### Scenario: External directory is blocked
- **WHEN** the agent attempts to read or edit a path outside the workspace
- **THEN** the action is denied unless the path is explicitly allowed

### Requirement: Guard plugin
The system SHALL load a guard plugin that uses `ctx.permission.hook("evaluate")`, `ctx.tool.hook("execute.before")` and `ctx.shell.hook("create.before")` to enforce protected paths, dangerous commands and proxy environment variables.

#### Scenario: Guard denies a protected read
- **WHEN** a tool call targets `.env` or a private key
- **THEN** the plugin raises a blocking error before execution

#### Scenario: Guard adds proxy environment
- **WHEN** a shell command is created
- **THEN** the plugin sets `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` for the command environment

#### Scenario: Guard does not override an explicit deny
- **WHEN** a system policy already denies an action
- **THEN** the permission hook cannot turn it into an allow

### Requirement: Audit plugin
The system SHALL load an audit plugin that records tool calls, shell commands, permission decisions and session prompt metadata to a dedicated host-mounted log directory.

#### Scenario: Tool call is recorded
- **WHEN** the agent executes a tool
- **THEN** the audit log records tool name, action, resource, status and duration

#### Scenario: Secrets are redacted
- **WHEN** a command or result contains a value matching a configured secret pattern
- **THEN** the audit record redacts the value

#### Scenario: Audit is not authoritative
- **WHEN** an operator needs tamper-resistant records
- **THEN** the proxy and broker logs are used as the authoritative source, because the agent can modify its own audit volume

### Requirement: Project plugin and MCP control
The system SHALL deny unapproved project plugins, skills and MCP servers through `integration.use` policy, while allowing explicitly approved ones. Trusted-repo project plugins SHALL be allowed only when system policy explicitly approves them, and their tool calls SHALL be audited.

#### Scenario: Unapproved MCP server is hidden
- **WHEN** a project config adds an MCP server not approved by system policy
- **THEN** the server is not loaded

#### Scenario: Unapproved plugin is not loaded
- **WHEN** a project adds a plugin denied by `integration.use`
- **THEN** the plugin is not loaded

#### Scenario: Approved project plugin loads
- **WHEN** a project plugin is explicitly allowed by system policy
- **THEN** the plugin loads and its tool calls appear in the audit log

### Requirement: Auto mode is not a security control
The system SHALL document that `--auto` only suppresses prompts and does not relax system deny rules. Auto mode SHALL only be recommended inside the hardened container.

#### Scenario: Auto mode still enforces deny
- **WHEN** OpenCode runs with `--auto` and a tool matches a system deny
- **THEN** the action is still blocked

### Requirement: Guardrail tests
The test suite SHALL verify protected-path denial, external-directory denial, explicit-deny finality, proxy environment injection, audit redaction and system-policy precedence over project configuration.

#### Scenario: Guardrail suite passes
- **WHEN** the guardrail tests run against a fixture project
- **THEN** every protected-path, external-directory and policy-precedence case produces the expected allow/deny result
