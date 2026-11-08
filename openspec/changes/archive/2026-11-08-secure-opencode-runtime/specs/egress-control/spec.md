## ADDED Requirements

### Requirement: Internal-only agent network
The agent container SHALL be attached only to a Docker network created with `internal: true`. The proxy, lease broker and LiteLLM SHALL be dual-homed between that internal network and an egress bridge. The agent SHALL NOT be attached to the default bridge or host network.

#### Scenario: Direct internet access fails
- **WHEN** a process inside the agent container connects directly to an external IP
- **THEN** the connection fails because no default route exists

#### Scenario: Host services are unreachable
- **WHEN** a process inside the agent container connects to a host LAN address or `host.docker.internal`
- **THEN** the connection fails

#### Scenario: Only the stack is reachable
- **WHEN** the agent container inspects its routes and neighbours
- **THEN** only the internal network and the proxy/broker/LiteLLM addresses are reachable

### Requirement: Default-deny egress allowlist
The proxy SHALL deny all egress by default and allow only explicitly configured destinations required by the project, such as the selected model provider, GitHub, npm and PyPI.

#### Scenario: Allowed registry works
- **WHEN** the agent installs a package from an allowlisted registry
- **THEN** the proxy permits the request and logs the destination

#### Scenario: Unlisted destination is denied
- **WHEN** the agent requests an unlisted domain
- **THEN** the proxy denies the request and records the denial

#### Scenario: Metadata endpoint is denied
- **WHEN** the agent requests a cloud metadata address or link-local address
- **THEN** the proxy denies the request

### Requirement: Proxy is the only egress path
The launcher SHALL set `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` for the agent, and the network SHALL prevent bypass when those variables are ignored or unset.

#### Scenario: Proxy variables are optional for reachability
- **WHEN** a tool ignores `HTTPS_PROXY` and attempts a direct connection
- **THEN** the connection fails rather than bypassing the proxy

#### Scenario: Proxy address is stable
- **WHEN** the stack starts
- **THEN** the agent receives a stable internal proxy hostname and port

### Requirement: No TLS interception by default
The default proxy SHALL NOT terminate TLS or require a custom CA in the agent. Header injection for model providers SHALL be implemented by the reverse proxy; service-specific token injection for git and cloud SHALL be implemented by the lease broker or credential helper.

#### Scenario: Agent trust store is unchanged
- **WHEN** the agent container starts in default mode
- **THEN** no custom proxy CA is installed

#### Scenario: Provider auth uses reverse proxy
- **WHEN** OpenCode calls a model provider
- **THEN** authentication is added by LiteLLM, not by a TLS-intercepting forward proxy

### Requirement: Egress logging
The proxy SHALL log allowed and denied requests with timestamp, lease or session identifier where available, destination host and result, and SHALL NOT log request bodies or credential values.

#### Scenario: Allowed request is logged
- **WHEN** the agent reaches an allowlisted host
- **THEN** the proxy writes an allow record with host and result

#### Scenario: Denied request is logged
- **WHEN** the agent attempts an unlisted host
- **THEN** the proxy writes a deny record with host and result

#### Scenario: Credentials are not logged
- **WHEN** a request carries an Authorization header or token
- **THEN** the proxy log omits the credential value

### Requirement: Proxy failure is fail-closed
If the proxy, broker or LiteLLM health check fails, the launcher SHALL refuse to start the agent in safe mode.

#### Scenario: Proxy down
- **WHEN** the proxy container is stopped
- **THEN** the launcher exits non-zero instead of starting an agent with no egress control

#### Scenario: Broker down
- **WHEN** the lease broker is unreachable
- **THEN** git and gh operations fail closed rather than falling back to host credentials

### Requirement: Egress bypass tests
The test suite SHALL include a direct-egress test, a host-service test, an allowlisted-domain test and a denied-domain test run from inside the agent container.

#### Scenario: Bypass suite passes
- **WHEN** the egress test suite runs against the stack
- **THEN** direct and host-service requests fail, the allowlisted request succeeds, and the denied request fails
