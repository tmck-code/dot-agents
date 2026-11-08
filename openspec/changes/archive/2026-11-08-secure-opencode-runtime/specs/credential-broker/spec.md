## ADDED Requirements

### Requirement: Scoped credential leases
The broker SHALL issue leases that bind a random lease ID to a session, service, resource scope, allowed actions, creation time and expiry. A lease SHALL be revocable before expiry.

#### Scenario: Lease creation records scope
- **WHEN** a human approves GitHub access for one repository for eight hours
- **THEN** the broker stores a lease with the session ID, repository, allowed actions and expiry, and returns a lease token

#### Scenario: Revocation is immediate
- **WHEN** the lease is revoked
- **THEN** subsequent token requests for that lease return `403` and no new credential is minted

#### Scenario: Expiry is enforced
- **WHEN** a lease has passed its expiry
- **THEN** the broker refuses to mint or refresh credentials for it

### Requirement: GitHub App installation tokens
The broker SHALL authenticate as a GitHub App using an App ID and private key held outside the agent, SHALL mint installation tokens scoped to the lease’s repositories and permissions, and SHALL refresh them while the lease is active.

#### Scenario: Token is scoped to one repository
- **WHEN** a lease allows only `owner/repo`
- **THEN** the minted installation token cannot access a different repository

#### Scenario: Long-running job refreshes
- **WHEN** the GitHub token is near expiry and the lease is still active
- **THEN** the broker mints a fresh installation token without another human approval

#### Scenario: Root key never reaches the agent
- **WHEN** the agent requests a GitHub token
- **THEN** it receives only the short-lived installation token, never the App private key or a long-lived PAT

#### Scenario: Exposed token is not refreshed after revoke
- **WHEN** a lease is revoked and the current installation token expires
- **THEN** the broker does not mint a replacement, and the agent must request a new approval

### Requirement: Credential helper for git and gh
The system SHALL provide a local credential helper or `GIT_ASKPASS` integration that fetches the lease token at call time and returns a GitHub-compatible token to `git` and `gh`.

#### Scenario: Git fetch uses the lease
- **WHEN** `git fetch` runs inside the agent container
- **THEN** the helper obtains a valid installation token from the broker and the command succeeds without a host `~/.ssh` mount

#### Scenario: GH uses the lease
- **WHEN** `gh pr create` runs inside the agent container
- **THEN** `gh` receives a valid token from the lease helper and does not read a host `~/.config/gh` directory

### Requirement: Provider virtual keys
The system SHALL place a local LiteLLM reverse proxy between OpenCode and model providers. The agent SHALL receive a per-lease virtual key with a model allowlist, budget and duration; provider root keys SHALL remain in LiteLLM.

#### Scenario: Agent never sees provider key
- **WHEN** OpenCode calls the model provider
- **THEN** the request uses the LiteLLM virtual key and LiteLLM injects the real provider key upstream

#### Scenario: Virtual key expires with the lease
- **WHEN** the lease expires or is revoked
- **THEN** LiteLLM rejects the virtual key

### Requirement: Local-only operation
The broker, proxy and model proxy SHALL run locally with no hosted secret manager, paid service or cloud broker dependency. Root secrets SHALL be supplied from a local SOPS+age store or a dedicated KeePassXC database.

#### Scenario: No cloud secret dependency
- **WHEN** the stack starts on an offline host with local secrets available
- **THEN** the broker, proxy and LiteLLM start without contacting a hosted secrets service

#### Scenario: Local vault source
- **WHEN** the operator provides secrets from SOPS+age or KeePassXC
- **THEN** the root values are loaded only into the host-side stack, not the agent container

### Requirement: Lease visibility and audit
The broker SHALL expose a host-side way to list active leases with service, scope, expiry and last use, and SHALL record token issuance and refresh events without recording the token value.

#### Scenario: Operator lists leases
- **WHEN** the operator runs the lease listing command
- **THEN** active leases show scope, TTL and last use

#### Scenario: Logs omit secrets
- **WHEN** a token is minted or refreshed
- **THEN** the audit record contains the lease ID and result but not the token value

### Requirement: Fail closed
The broker SHALL reject requests with a missing, malformed, expired or revoked lease token and SHALL not fall back to a host credential or a default token.

#### Scenario: Missing token is rejected
- **WHEN** an agent calls a broker token endpoint without a lease token
- **THEN** the broker returns `401` and mints nothing

#### Scenario: Malformed token is rejected
- **WHEN** an agent presents a syntactically invalid lease token
- **THEN** the broker returns `401` and records the rejection

### Requirement: Secret storage integration
The system SHALL provide a wrapper that resolves named secrets from SOPS+age or KeePassXC and starts the security stack without writing plaintext secrets into the repository, image or shell history.

#### Scenario: SOPS source
- **WHEN** the operator runs the stack wrapper with a SOPS-encrypted file
- **THEN** only the selected values are decrypted into the host-side stack environment

#### Scenario: KeePassXC source
- **WHEN** the operator selects a dedicated KeePassXC agent database
- **THEN** only the named entries are fetched, and the `.kdbx` file is never mounted into the agent container
