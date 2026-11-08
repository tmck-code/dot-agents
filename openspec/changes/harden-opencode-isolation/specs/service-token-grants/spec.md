## ADDED Requirements

### Requirement: Grant a service to a running lease
`broker-admin` SHALL provide `POST /v1/leases/{lease_id}/grants` that accepts `service`, `ttl_seconds` and `values` (a map of names to secret strings), and `DELETE /v1/leases/{lease_id}/grants/{service}`. The service name SHALL match `^[a-z][a-z0-9-]{1,31}$` and SHALL NOT be `github`, `litellm` or `all`. The grant expiry SHALL be the smallest of the requested TTL, `BROKER_MAX_GRANT_TTL_SECONDS` (default 3600) and the lease's remaining lifetime; the default TTL SHALL be 900 seconds. A grant on a revoked or expired lease SHALL be rejected with `409`. A new grant for the same lease and service SHALL replace the previous one.

#### Scenario: Grant on active lease
- **WHEN** the operator grants `excalidraw` to an active lease with `ttl_seconds` 1800
- **THEN** the broker stores an active grant expiring 1800 seconds later and returns the grant without the values

#### Scenario: TTL clamped to lease
- **WHEN** the lease expires in 600 seconds and the grant requests 1800
- **THEN** the grant expires in 600 seconds

#### Scenario: Reserved name rejected
- **WHEN** the operator grants service `github`
- **THEN** the broker returns `422`

#### Scenario: Revoked lease rejected
- **WHEN** the operator grants a service to a revoked lease
- **THEN** the broker returns `409` and stores nothing

### Requirement: Fetch a granted service token
The agent-facing broker SHALL provide `GET /v1/token/{service}`, authenticated by the lease token like the other token routes, that returns `{"service", "values", "expires_at"}` when the lease is active and has an active, unexpired grant for that service, and `403` otherwise. The route SHALL NOT shadow `/v1/token/github` or `/v1/token/litellm`. Values SHALL be returned only in the HTTP response; the broker SHALL NOT write them into any path visible to the agent container.

#### Scenario: Excalidraw key fetched
- **WHEN** lease `L` has an active `excalidraw` grant and the agent runs `lease token excalidraw`
- **THEN** standard output is JSON with `service` `excalidraw`, `values.TOKEN` set and an `expires_at`, and a `token.issue` event with `detail.service` `excalidraw` is recorded without the value

#### Scenario: No grant
- **WHEN** the agent requests `/v1/token/excalidraw` and lease `L` has no grant for it
- **THEN** the broker returns `403`

#### Scenario: Expired grant
- **WHEN** the grant's `expires_at` has passed
- **THEN** the broker returns `403` and clears the stored values

#### Scenario: Literal routes unaffected
- **WHEN** the agent requests `/v1/token/github` under a GitHub lease
- **THEN** the GitHub handler serves the request

### Requirement: Revocation clears grants
Revoking a lease SHALL revoke all of its grants and clear their stored values. Revoking one grant SHALL clear only that grant.

#### Scenario: Lease revoke
- **WHEN** the operator revokes lease `L` with an active `excalidraw` grant
- **THEN** a later `GET /v1/token/excalidraw` with `L`'s token returns `403` and the grant row holds no values

#### Scenario: Single ungrant
- **WHEN** the operator runs `lease ungrant L excalidraw`
- **THEN** `/v1/token/excalidraw` returns `403` while other grants on `L` still work

### Requirement: Host-side grant command
`bin/lease` SHALL provide `lease grant <lease_id> <service> [--ttl DURATION] [--file PATH | --keepassxc ENTRY]` and `lease ungrant <lease_id> <service>`. Without a source option the values SHALL be read from `docker/opencode/stack/secrets/services/<service>.env` (`NAME=value` lines). With `--keepassxc ENTRY` the command SHALL fetch the entry password with `keepassxc-cli`, passing the database password on stdin, and send it as `TOKEN`. Secret values SHALL NOT appear in argv or on standard output. The `services/` directory SHALL NOT be mounted into any container.

#### Scenario: Grant from service file
- **WHEN** `stack/secrets/services/excalidraw.env` contains `TOKEN=abc` and the operator runs `lease grant L excalidraw --ttl 30m`
- **THEN** the broker receives `values` `{"TOKEN": "abc"}` and `ttl_seconds` 1800

#### Scenario: Grant from KeePassXC
- **WHEN** the operator runs `lease grant L excalidraw --keepassxc excalidraw/api-key`
- **THEN** the entry password is sent as `TOKEN` and the `.kdbx` file is not read by any container

#### Scenario: Missing source
- **WHEN** no source option is given and `services/excalidraw.env` does not exist
- **THEN** the command exits non-zero naming the expected file
