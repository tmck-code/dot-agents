## MODIFIED Requirements

### Requirement: Lease visibility and audit
The broker SHALL expose a host-side way to list active leases with service, scope, expiry and last use, and SHALL record lease creation, revocation, grants, authentication rejections, admin authentication failures, and token issuance and refresh events without recording any token or secret value. Each recorded event SHALL be stored in the broker `events` table and SHALL also be written to standard output as one line in the `structured-audit-log` schema, with `component` set to `broker` or `broker-admin`.

#### Scenario: Operator lists leases
- **WHEN** the operator runs the lease listing command
- **THEN** active leases show scope, TTL, last use and active grants

#### Scenario: Logs omit secrets
- **WHEN** a token is minted or refreshed
- **THEN** the audit record contains the lease ID and result but not the token value

#### Scenario: Event is streamed as JSON
- **WHEN** the agent-facing broker mints a GitHub installation token
- **THEN** `docker logs opencode-broker` contains one JSON line with `component` `broker`, `event` `github.mint`, the lease ID, the repository and `outcome` `ok`

### Requirement: Secret storage integration
The system SHALL provide a wrapper that resolves named secrets from SOPS+age or KeePassXC and writes each to its own file in `docker/opencode/stack/secrets/` without writing plaintext secrets into the repository, image or shell history. `LITELLM_MASTER_KEY` SHALL be written only to `litellm-master.key`, `BROKER_ADMIN_TOKEN` only to `broker-admin.token`, and every LiteLLM provider key, including `OPENROUTER_API_KEY` and `GEMINI_API_KEY`, to `litellm.env`. The wrapper SHALL accept `--pem ENTRY[:ATTACHMENT]` to export the GitHub App private key from a KeePassXC entry attachment to `github-app.pem`.

#### Scenario: SOPS source
- **WHEN** the operator runs the stack wrapper with a SOPS-encrypted file
- **THEN** only the selected values are decrypted into their per-service files

#### Scenario: KeePassXC source
- **WHEN** the operator selects a dedicated KeePassXC agent database
- **THEN** only the named entries are fetched, and the `.kdbx` file is never mounted into the agent container

#### Scenario: Master key has one home
- **WHEN** the wrapper resolves `LITELLM_MASTER_KEY`
- **THEN** the value is written to `litellm-master.key` and to no other file

#### Scenario: OpenRouter key reaches LiteLLM
- **WHEN** the wrapper resolves `OPENROUTER_API_KEY`
- **THEN** the value is written to `litellm.env` and not to `stack.env`

#### Scenario: GitHub App key from an attachment
- **WHEN** the operator runs the wrapper with `--source keepassxc --pem github/app`
- **THEN** the attachment `github-app.pem` of entry `github/app` is exported to `stack/secrets/github-app.pem` with mode 0600, and the database password is passed on stdin, never in argv

## ADDED Requirements

### Requirement: Per-service secret isolation
Each compose service SHALL receive only the secret files it needs, through compose `secrets:` entries: `broker` receives `github-app.pem` and `litellm-keygen.key`; `broker-admin` receives `broker-admin.token` and `litellm-keygen.key`; `litellm` receives `litellm-master.key`, `litellm.env`, `postgres-password` and `llama-api-key`; `postgres` receives `postgres-password`; `llama` receives `llama-api-key`. No service SHALL mount the whole `stack/secrets` directory, and no secret SHALL be passed through compose environment interpolation.

#### Scenario: Agent-facing broker lacks the admin token
- **WHEN** the stack is running
- **THEN** `/run/secrets` in `opencode-broker` contains no admin token and no LiteLLM provider key, and its environment contains no `BROKER_ADMIN_TOKEN` or `LITELLM_MASTER_KEY`

#### Scenario: LiteLLM lacks broker secrets
- **WHEN** the stack is running
- **THEN** `/run/secrets` in `opencode-litellm` contains neither `github-app.pem` nor the admin token

#### Scenario: Compose config carries no secret values
- **WHEN** `docker compose config` is rendered with populated secret files
- **THEN** the output contains no secret value

### Requirement: Scoped LiteLLM key-generation credential
The broker and `broker-admin` SHALL mint and delete LiteLLM virtual keys with a dedicated key-generation key that is restricted to `/key/generate`, `/key/delete` and `/key/info`, and SHALL NOT hold the LiteLLM master key, unless the pinned LiteLLM image is verified not to support such a key, in which case the README SHALL state that the broker holds the master key and why.

#### Scenario: Key-generation key cannot change models
- **WHEN** a request to LiteLLM `/model/new` is made with the key-generation key
- **THEN** LiteLLM rejects it

#### Scenario: Virtual key minting still works
- **WHEN** the agent requests `/v1/token/litellm` under an active lease
- **THEN** the broker returns a virtual key minted with the key-generation key

### Requirement: Broker egress through the proxy
The agent-facing broker SHALL be attached only to the internal agent network and SHALL reach the GitHub API only through the Squid proxy.

#### Scenario: Broker has no direct route
- **WHEN** a process in `opencode-broker` connects directly to an external IP
- **THEN** the connection fails

#### Scenario: GitHub mint is proxied
- **WHEN** the broker mints an installation token
- **THEN** the Squid access log records a `CONNECT api.github.com:443` from the broker's address

### Requirement: Constant-time admin authentication
`broker-admin` SHALL compare the presented admin token with the configured token in constant time and SHALL record each failed comparison as an event with outcome `deny`.

#### Scenario: Wrong admin token
- **WHEN** a request to `broker-admin` carries a wrong `X-Admin-Token`
- **THEN** it returns `401` and an `admin.auth` event with outcome `deny` is recorded

### Requirement: Generated stack credentials
The stack start scripts SHALL generate any missing `broker-admin.token`, `litellm-master.key`, `litellm-keygen.key`, `postgres-password` and `llama-api-key` file with 32 random bytes, mode 0600, through one shared helper, and SHALL NOT overwrite an existing file. The compose file SHALL NOT contain default values for any password or API key.

#### Scenario: First start generates passwords
- **WHEN** `online.sh up` runs with an empty `stack/secrets` directory
- **THEN** all five files exist with mode 0600 and distinct random values

#### Scenario: Restart keeps existing values
- **WHEN** `llama.sh up` runs after `online.sh up`
- **THEN** the five files are unchanged

#### Scenario: No fixed default password
- **WHEN** the compose file is searched for `litellm-local` or `sk-llama-local`
- **THEN** neither string is present

### Requirement: Secret flow documentation
`docker/opencode/README.md` SHALL describe the KeePassXC secret flow in four numbered steps: the host KeePassXC database holds long-lived secrets; `scripts/opencode-secrets.sh` extracts named entries and the GitHub App key attachment; the values are written to per-service files in `docker/opencode/stack/secrets/`; compose grants each file only to the services that read it. It SHALL state that the agent never sees the `.kdbx` file or the secret files. The README mount table SHALL show the safe-mode mode of each host path, so no row describes a safe-mode mount as read-write when it is read-only, a named volume or absent.

#### Scenario: Four-step flow documented
- **WHEN** a reader opens the README "Secrets" section
- **THEN** it contains the four numbered steps and names the per-service files

#### Scenario: Mount table is accurate
- **WHEN** a reader looks up `~/.claude` in the README mount table
- **THEN** the safe-mode column says it is replaced by a read-only staged allowlist, and the unsafe column says read-write
