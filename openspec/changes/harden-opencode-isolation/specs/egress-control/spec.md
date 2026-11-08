## MODIFIED Requirements

### Requirement: Default-deny egress allowlist
The proxy SHALL deny all egress by default and allow only explicitly configured destinations required by the project, such as the selected model provider, GitHub, npm and PyPI. Google model access SHALL be allowed only through `generativelanguage.googleapis.com`, not the `.googleapis.com` wildcard. Before the allow rule, the proxy SHALL deny any request whose resolved destination address is in `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `0.0.0.0/8`, `::1/128`, `fc00::/7` or `fe80::/10`. The egress network SHALL use a pinned subnet inside an RFC1918 range so its Docker gateway is covered by that deny.

#### Scenario: Allowed registry works
- **WHEN** the agent installs a package from an allowlisted registry
- **THEN** the proxy permits the request and logs the destination

#### Scenario: Unlisted destination is denied
- **WHEN** the agent requests an unlisted domain
- **THEN** the proxy denies the request and records the denial

#### Scenario: Metadata endpoint is denied
- **WHEN** the agent requests a cloud metadata address or link-local address
- **THEN** the proxy denies the request

#### Scenario: Private destination is denied
- **WHEN** the agent requests `CONNECT 10.0.0.1:443`, `CONNECT 127.0.0.1:443`, or the egress network gateway address
- **THEN** the proxy denies the request

#### Scenario: Allowlisted name resolving privately is denied
- **WHEN** an allowlisted hostname resolves to an RFC1918 or loopback address
- **THEN** the proxy denies the request

#### Scenario: Broad Google APIs are denied
- **WHEN** the agent requests `storage.googleapis.com`
- **THEN** the proxy denies the request, while `generativelanguage.googleapis.com` is allowed

### Requirement: Egress logging
The proxy SHALL log allowed and denied requests as one JSON line per request in the `structured-audit-log` schema, with timestamp, destination host and result, and SHALL record any agent-supplied lease identifier only as `detail.claimed_lease_id`. It SHALL NOT log request bodies, query strings or credential values.

#### Scenario: Allowed request is logged
- **WHEN** the agent reaches an allowlisted host
- **THEN** the proxy writes a JSON record with `component` `squid`, the host and `outcome` `ok`

#### Scenario: Denied request is logged
- **WHEN** the agent attempts an unlisted host
- **THEN** the proxy writes a JSON record with the host and `outcome` `deny`

#### Scenario: Credentials are not logged
- **WHEN** a request carries an Authorization header or token
- **THEN** the proxy log omits the credential value

#### Scenario: Claimed lease is not trusted
- **WHEN** the agent sends `X-Lease-Id: lse_fake`
- **THEN** the log record has `lease_id` null and `detail.claimed_lease_id` `lse_fake`

## ADDED Requirements

### Requirement: Documented exfiltration risk
The README SHALL contain a section that states that an agent can send data to any allowlisted destination, including any GitHub repository or gist its lease token can write and any model provider using a key the agent supplies, and that the allowlist limits destinations but does not prevent data from leaving.

#### Scenario: Risk section exists
- **WHEN** a reader opens `docker/opencode/README.md`
- **THEN** a section titled "Accepted exfiltration risk" lists GitHub and model-provider domains as exfiltration channels
