## ADDED Requirements

### Requirement: Hardened development image
The system SHALL provide a single `opencode-dev` image target that runs OpenCode as a non-root user, contains no embedded credentials, pins base images by digest, and ships a read-only system OpenCode policy at `/etc/opencode/opencode.jsonc`.

#### Scenario: Non-root runtime
- **WHEN** the image is started with the default entrypoint
- **THEN** the OpenCode process runs as the non-root `agent` user and cannot escalate with `sudo`

#### Scenario: No embedded secrets
- **WHEN** the image history and filesystem are inspected
- **THEN** no provider key, GitHub token, SSH key or vault master password is present in any layer or build argument

#### Scenario: System policy is read-only
- **WHEN** the agent container starts
- **THEN** `/etc/opencode/opencode.jsonc` is present, owned by root, and not writable by the agent user

### Requirement: Safe launcher defaults
The launcher SHALL attach the agent container only to an internal Docker network, SHALL NOT mount `~/.ssh` or `~/.config/gh`, SHALL NOT add a host gateway, SHALL mount host configuration read-only, and SHALL apply `--cap-drop=ALL`, `--security-opt=no-new-privileges`, PID, memory and CPU limits.

#### Scenario: No host route by default
- **WHEN** the agent container starts with default flags
- **THEN** it has no route to the host LAN, host loopback services or `host.docker.internal`

#### Scenario: Host credentials are not mounted by default
- **WHEN** the agent container starts with default flags
- **THEN** neither the host `~/.ssh` directory nor the host `~/.config/gh` directory is present inside the container

#### Scenario: Capabilities are dropped
- **WHEN** the running container is inspected
- **THEN** its effective capability set is empty and `NoNewPrivs` is set

### Requirement: Explicit escape hatches
The launcher SHALL expose documented `--with-ssh`, `--with-gh` and `--unsafe` flags for trusted debugging, and SHALL print a warning describing the widened exposure whenever one is used.

#### Scenario: Unsafe mode warns
- **WHEN** the launcher is invoked with `--unsafe`
- **THEN** it prints a warning listing the host mounts and network access being restored

#### Scenario: Safe mode is the default
- **WHEN** the launcher is invoked with no exposure flags
- **THEN** it uses the hardened mount and network defaults

### Requirement: Workspace and worktree fidelity
The launcher SHALL preserve the current repo-at-same-absolute-path behaviour and SHALL continue to mount linked-worktree git metadata needed for `git status`, commits and hooks.

#### Scenario: Linked worktree works
- **WHEN** the launcher is run from a linked worktree
- **THEN** `git status` and `git commit` work inside the container without exposing the main checkout for writes

#### Scenario: Host paths still resolve
- **WHEN** deployed `~/.claude` symlinks point into the mounted repo
- **THEN** they resolve inside the container at the same absolute path

### Requirement: Fail-closed startup
The launcher SHALL verify that the proxy, lease broker and LiteLLM endpoints are reachable before starting OpenCode, and SHALL refuse to start when the security stack is unavailable unless `--unsafe` is set.

#### Scenario: Missing proxy fails closed
- **WHEN** the proxy container is not running
- **THEN** the launcher exits non-zero with a message identifying the missing service

#### Scenario: Unsafe override
- **WHEN** the stack is unavailable and `--unsafe` is set
- **THEN** the launcher starts the container with the legacy behaviour and prints the warning

### Requirement: Image build hygiene
The build SHALL remove the obsolete `Dockerfile.new`, exclude secrets, `.git`, `.scratch` and local state from the build context, and record SBOM and provenance metadata in the multi-arch build target.

#### Scenario: Clean build context
- **WHEN** the image is built from the repository root
- **THEN** the context does not include `.env`, vault files, `.git`, `.scratch` or host state

#### Scenario: Obsolete file removed
- **WHEN** the change is applied
- **THEN** `docker/opencode/Dockerfile.new` no longer exists
