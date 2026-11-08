## MODIFIED Requirements

### Requirement: Hardened development image
The system SHALL provide a single `opencode-dev` image target that runs OpenCode as a non-root user with the fixed uid and gid `60917:60917`, contains no embedded credentials, pins base images by digest, and ships a read-only system OpenCode policy at `/etc/opencode/opencode.jsonc`. The image build SHALL NOT derive the agent uid or gid from the building host user.

#### Scenario: Non-root runtime
- **WHEN** the image is started with the default entrypoint
- **THEN** the OpenCode process runs as the non-root `agent` user and cannot escalate with `sudo`

#### Scenario: Fixed agent uid
- **WHEN** the image is built with `make build` on any host
- **THEN** the `agent` user has uid 60917 and gid 60917, and the `dev.opencode.uid` label is `60917`

#### Scenario: No embedded secrets
- **WHEN** the image history and filesystem are inspected
- **THEN** no provider key, GitHub token, SSH key or vault master password is present in any layer or build argument

#### Scenario: System policy is read-only
- **WHEN** the agent container starts
- **THEN** `/etc/opencode/opencode.jsonc` is present, owned by root, and not writable by the agent user

### Requirement: Safe launcher defaults
The launcher SHALL attach the agent container only to an internal Docker network, SHALL NOT mount `~/.ssh` or `~/.config/gh`, SHALL NOT add a host gateway, SHALL mount host configuration read-only, SHALL NOT mount `$CLAUDE_CONFIG_DIR` itself, and SHALL apply `--cap-drop=ALL`, `--security-opt=no-new-privileges`, PID, memory and CPU limits. The launcher SHALL refuse to start in safe mode when the image's agent uid equals the invoking host user's uid.

#### Scenario: No host route by default
- **WHEN** the agent container starts with default flags
- **THEN** it has no route to the host LAN, host loopback services or `host.docker.internal`

#### Scenario: Host credentials are not mounted by default
- **WHEN** the agent container starts with default flags
- **THEN** neither the host `~/.ssh` directory nor the host `~/.config/gh` directory is present inside the container

#### Scenario: Claude credentials are absent
- **WHEN** the agent container starts with default flags
- **THEN** `/home/agent/.claude/.credentials.json`, `/home/agent/.claude/.claude.json`, `/home/agent/.claude/history.jsonl`, `/home/agent/.claude/projects` and `/home/agent/.claude/session-env` do not exist inside the container

#### Scenario: Host uid image is refused
- **WHEN** the image label `dev.opencode.uid` equals the output of `id -u` and the launcher runs in safe mode
- **THEN** the launcher exits non-zero with a message telling the user to rebuild the image

#### Scenario: Capabilities are dropped
- **WHEN** the running container is inspected
- **THEN** its effective capability set is empty and `NoNewPrivs` is set

### Requirement: Explicit escape hatches
The launcher SHALL expose documented `--with-ssh`, `--with-gh` and `--unsafe` flags for trusted debugging, and SHALL print a warning describing the widened exposure whenever one is used. `--unsafe` SHALL take effect only when `OPENCODE_I_ACCEPT_UNSAFE=1` is set, stdin and stderr are terminals, and the user types `unsafe` at the confirmation prompt. Every accepted or refused `--unsafe` attempt SHALL write an audit record. The launcher SHALL reject `OPENCODE_DOCKER_ARGS` containing `--privileged`, `--network`, `--net`, `--pid`, `--ipc`, `--uts`, `--userns`, `--cgroupns`, `--cap-add`, `--security-opt`, `--device`, `-u`, `--user`, `-v`, `--volume`, `--mount` or `--volumes-from`, in any `--flag`, `--flag=value`, `-f` or `-fvalue` form, unless `OPENCODE_I_ACCEPT_UNSAFE=1` is set.

#### Scenario: Unsafe mode warns
- **WHEN** the launcher is invoked with `--unsafe`
- **THEN** it prints a warning listing the host mounts and network access being restored

#### Scenario: Unsafe without acceptance variable is refused
- **WHEN** the launcher is invoked with `--unsafe` and `OPENCODE_I_ACCEPT_UNSAFE` is unset
- **THEN** it exits with status 2, starts no container, and writes an `unsafe.refused` audit record

#### Scenario: Unsafe without a terminal is refused
- **WHEN** the launcher is invoked with `--unsafe`, `OPENCODE_I_ACCEPT_UNSAFE=1`, and stdin is not a terminal
- **THEN** it exits with status 2 and starts no container

#### Scenario: Unsafe with confirmation is audited
- **WHEN** the launcher is invoked with `--unsafe`, `OPENCODE_I_ACCEPT_UNSAFE=1`, on a terminal, and the user types `unsafe`
- **THEN** it writes an `unsafe.start` audit record listing the restored exposures and starts the legacy container

#### Scenario: Widening docker argument is rejected
- **WHEN** `OPENCODE_DOCKER_ARGS` is `--network=host` or `-v /:/host` and `OPENCODE_I_ACCEPT_UNSAFE` is unset
- **THEN** the launcher exits non-zero naming the rejected flag and starts no container

#### Scenario: Harmless docker argument is accepted
- **WHEN** `OPENCODE_DOCKER_ARGS` is `--env FOO=bar`
- **THEN** the launcher appends it to the `docker run` arguments

#### Scenario: Safe mode is the default
- **WHEN** the launcher is invoked with no exposure flags
- **THEN** it uses the hardened mount and network defaults

### Requirement: Workspace and worktree fidelity
In safe mode the launcher SHALL give the agent a per-session git checkout as defined by the `session-workspace` capability, mounted read-write at its own absolute host path and used as the workdir. The launcher SHALL NOT mount the user's working tree or any part of the host repository's git common directory read-write, and SHALL mount only the host common directory's `objects/` directory, read-only. `git status`, `git diff` and `git commit` SHALL work inside the container on the session branch.

#### Scenario: Session checkout works
- **WHEN** the launcher is run from a repository or from a linked worktree of it
- **THEN** `git status` and `git commit` succeed inside the container on branch `opencode/<session-id>`

#### Scenario: Host git metadata is not writable
- **WHEN** a process in the container attempts to write the host repository's `.git/hooks`, `.git/config`, `.git/refs` or `.git/objects`
- **THEN** the write fails because those paths are either not mounted or mounted read-only

#### Scenario: User working tree is untouched
- **WHEN** the agent edits and commits files during a session
- **THEN** the user's working tree and current branch on the host are unchanged

## ADDED Requirements

### Requirement: Claude configuration allowlist
In safe mode the launcher SHALL build a per-session staging directory that contains only the directories listed in `CLAUDE_ALLOW_DIRS` (default `skills`, `commands`, `hooks`, `agents`), copied with symlinks dereferenced, and a `settings.json` filtered to the top-level keys `hooks`, `permissions` and `model` plus `env` entries whose names do not match `TOKEN`, `KEY`, `SECRET`, `PASSWORD`, `CREDENTIAL`, `AUTH` or `COOKIE` (case-insensitive). The launcher SHALL mount the staging directory read-only at `/home/agent/.claude`.

#### Scenario: Allowed directories are present
- **WHEN** the host `~/.claude` contains `skills/` and `hooks/`
- **THEN** both are present under `/home/agent/.claude` inside the container and are read-only

#### Scenario: Credential-shaped settings are stripped
- **WHEN** the host `settings.json` contains `mcpServers`, `apiKeyHelper` and an `env` entry `GITHUB_TOKEN`
- **THEN** the staged `settings.json` contains none of them and keeps the `hooks` and `permissions` keys

#### Scenario: Missing directory is skipped
- **WHEN** an allowlisted directory does not exist on the host
- **THEN** the launcher skips it without error

### Requirement: Rootless Docker required
In safe mode the launcher SHALL refuse to start unless the Docker engine isolates container uids from the host user: the host is macOS, or `docker info` reports `Docker Desktop` as the operating system, or its security options contain `name=rootless` or `name=userns`. The launcher SHALL accept a `--allow-rootful` flag that skips this check only when `OPENCODE_I_ACCEPT_UNSAFE=1` is set, and SHALL print a warning and write an audit record when it is used.

#### Scenario: Rootful daemon is refused
- **WHEN** the launcher runs in safe mode on Linux against a daemon whose security options contain neither `name=rootless` nor `name=userns` and that is not Docker Desktop
- **THEN** it exits non-zero with instructions for rootless setup and starts no container

#### Scenario: Rootless daemon is accepted
- **WHEN** `docker info` security options contain `name=rootless`
- **THEN** the launcher continues to start the agent

#### Scenario: macOS is accepted
- **WHEN** `uname -s` reports `Darwin`
- **THEN** the launcher treats the engine as VM-isolated and continues

#### Scenario: Debug override is fenced
- **WHEN** `--allow-rootful` is passed without `OPENCODE_I_ACCEPT_UNSAFE=1`
- **THEN** the launcher exits non-zero

#### Scenario: Debug override is audited
- **WHEN** `--allow-rootful` is passed with `OPENCODE_I_ACCEPT_UNSAFE=1` on a rootful daemon
- **THEN** the launcher prints a warning, writes a `launcher.rootful_override` audit record, and continues

### Requirement: Read-only mounts are readable by the agent uid
The launcher SHALL verify before starting the agent that the staged Claude directory and the host git `objects/` directory are readable by a uid that owns none of their files, and SHALL exit non-zero naming the first unreadable path otherwise.

#### Scenario: Private objects directory is reported
- **WHEN** the host repository's `.git/objects` has mode 0700
- **THEN** the launcher exits non-zero and names that path and the required mode
