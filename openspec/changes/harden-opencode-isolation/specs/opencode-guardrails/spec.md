## MODIFIED Requirements

### Requirement: Least-privilege permissions
OpenCode permissions SHALL deny reads and edits of protected paths (`.env*`, `.ssh`, key files, `auth.json`, vault files, and the Claude credential files `.credentials.json`, `.claude.json` and `history.jsonl`) and SHALL require explicit approval or denial for paths outside the workspace. Shell SHALL remain usable inside the container boundary.

#### Scenario: Env file is protected
- **WHEN** the agent attempts to read `.env` or `.env.local`
- **THEN** the action is denied by policy

#### Scenario: SSH material is protected
- **WHEN** the agent attempts to read a private key or `~/.ssh` content
- **THEN** the action is denied by policy

#### Scenario: Claude credentials are protected
- **WHEN** the agent attempts to read or edit a file named `.credentials.json`, `.claude.json` or `history.jsonl` at any path
- **THEN** the action is denied by policy and by the guard plugin

#### Scenario: External directory is blocked
- **WHEN** the agent attempts to read or edit a path outside the workspace
- **THEN** the action is denied unless the path is explicitly allowed
