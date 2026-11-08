## ADDED Requirements

### Requirement: Log line schema
Every structured log record SHALL be one JSON object on one line with exactly the keys `ts` (RFC 3339 UTC with milliseconds and `Z`), `component` (one of `run.sh`, `lease-cli`, `broker`, `broker-admin`, `squid`), `event` (dotted name), `lease_id` (string or null), `repo` (`owner/repo`, an absolute path, or null), `outcome` (one of `ok`, `deny`, `error`, `warn`) and `detail` (object). No record SHALL contain a token, key, password or lease token value.

#### Scenario: Record shape
- **WHEN** any emitter writes a record
- **THEN** `jq -e 'keys == ["component","detail","event","lease_id","outcome","repo","ts"]'` succeeds on that line

#### Scenario: Secret values are filtered
- **WHEN** an emitter is given a `detail` containing a key named `token`, `lease_token`, `litellm_key`, `private_key` or `values`
- **THEN** the written record omits that key

### Requirement: Host-side emitters
`run.sh` and `bin/lease` SHALL append records to `${XDG_STATE_HOME:-~/.local/state}/opencode/audit.jsonl` (mode 0600) for session start, session review, session clean, unsafe acceptance and refusal, rootful override, docker argument override, lease approve, lease revoke, lease grant and lease ungrant. Human-readable messages on standard error SHALL remain.

#### Scenario: Session start is logged
- **WHEN** `run.sh` starts a safe-mode session
- **THEN** `audit.jsonl` gains a `session.start` record with the session id and lease id in `detail` and `outcome` `ok`

#### Scenario: Lease grant is logged
- **WHEN** the operator runs `lease grant L excalidraw`
- **THEN** `audit.jsonl` gains a `lease.grant` record with `lease_id` `L` and `detail.service` `excalidraw`

### Requirement: Stack emitters
The broker and `broker-admin` SHALL write every recorded event to standard output in the schema. Squid SHALL write its access log in the schema with `component` `squid`, `event` `proxy.request`, the destination in `detail.host`, the HTTP status in `detail.status`, and `outcome` `ok` for allowed and `deny` for denied requests.

#### Scenario: Squid denial is structured
- **WHEN** the agent requests an unlisted domain through Squid
- **THEN** the Squid access log gains one JSON line with `outcome` `deny` and the domain in `detail.host`

### Requirement: Pretty viewer
The system SHALL provide `docker/opencode/bin/opencode-log pretty [FILE...]` that reads records from files or standard input and prints each record on one line with keys in schema order, each key in a fixed per-column colour, and the `outcome` value green for `ok`, red for `deny` and `error`, and yellow for `warn`, using a Pygments `Terminal256Formatter` and `JsonLexer` with the `dracula` style by default. It SHALL accept `--component`, `--lease`, `--outcome`, `--style` and `--no-color`, SHALL disable colour when standard output is not a terminal or `NO_COLOR` is set, and SHALL print non-JSON lines unchanged.

#### Scenario: Filter by lease
- **WHEN** the operator runs `opencode-log pretty --lease L audit.jsonl`
- **THEN** only records with `lease_id` `L` are printed

#### Scenario: Plain output when piped
- **WHEN** the viewer's standard output is a pipe
- **THEN** the output contains no ANSI escape sequences

#### Scenario: Non-JSON line passes through
- **WHEN** the input contains a line that is not JSON
- **THEN** the line is printed unchanged and processing continues
