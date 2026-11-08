## ADDED Requirements

### Requirement: Per-session clone
For each safe-mode launch the launcher SHALL create a session directory `${XDG_STATE_HOME:-~/.local/state}/opencode/sessions/<session-id>/`, where `<session-id>` is `<UTC yyyymmddTHHMMSS>-<6 hex>`, containing `session.json` and a `work/` git clone of the host repository made with `git clone --shared` from a one-shot container running as the agent uid with no network. The clone SHALL be checked out on a new branch `opencode/<session-id>` at the host repository's current `HEAD` commit. `session.json` SHALL record `session_id`, `repo_root`, `git_common_dir`, `base_ref`, `base_sha`, `branch` and `created_at`. The lease session name SHALL equal `<session-id>`.

#### Scenario: Session is created
- **WHEN** the launcher starts in safe mode from a repository whose `HEAD` is commit `abc123` on `main`
- **THEN** a session directory exists whose `work/` is on branch `opencode/<session-id>` at `abc123`, and `session.json` records `base_ref` `main` and `base_sha` `abc123`

#### Scenario: Objects are shared, not copied
- **WHEN** the session clone is created
- **THEN** `work/.git/objects/info/alternates` names the host common directory's `objects/` path and no pack files are copied

#### Scenario: Linked worktree as source
- **WHEN** the launcher is started from a linked worktree of the host repository
- **THEN** the session clone uses that worktree's `HEAD` as its base and the common directory's `objects/` as its alternate

#### Scenario: Dirty working tree warns
- **WHEN** the host working tree has uncommitted changes
- **THEN** the launcher prints a warning that uncommitted changes are not in the session and continues

#### Scenario: Not a repository
- **WHEN** `REPO_ROOT` is not inside a git repository
- **THEN** the launcher exits non-zero in safe mode

### Requirement: Session mounts
The agent container SHALL mount the session `work/` directory read-write at its absolute host path as the workdir, and the host common directory's `objects/` read-only at its absolute host path. No other path of the host repository or its git common directory SHALL be mounted.

#### Scenario: Alternates resolve in the container
- **WHEN** the agent runs `git log` in the session clone
- **THEN** commits from the host history are readable through the read-only objects mount

#### Scenario: Host hooks are invisible
- **WHEN** the agent lists the host repository's `.git/hooks` path
- **THEN** the path does not exist inside the container

### Requirement: Clone remote
The launcher SHALL set the session clone's `origin` URL to the host repository's `remote.origin.url` with any userinfo removed when that URL uses `https://`, and SHALL remove `origin` otherwise.

#### Scenario: HTTPS remote is preserved without credentials
- **WHEN** the host `remote.origin.url` is `https://user:tok@github.com/o/r.git`
- **THEN** the session clone's `origin` URL is `https://github.com/o/r.git`

### Requirement: Review before merge
The launcher SHALL provide `run.sh review [<session-id>]` that fetches `opencode/<session-id>` from the session clone into the host repository as `refs/opencode/review/<session-id>`, prints `git diff --stat` between `base_sha` and that ref, and prints a highlighted list of changed paths that match `.git/hooks/**`, `.githooks/**`, `.envrc`, `.env*`, `Makefile`, `*.mk`, `.github/workflows/**`, `.claude/**`, `.opencode/**`, `.mcp.json`, `AGENTS.md`, `CLAUDE.md`, `.gitmodules`, `.pre-commit-config.yaml`, or `package.json` when its `scripts` object changed. It SHALL print the merge command without running it. It SHALL NOT run any git command whose working directory or `-C` target is the session clone. Without a session id it SHALL use the newest session for the current repository.

#### Scenario: Diff stat is shown
- **WHEN** the agent committed changes to `src/app.py` in session `S`
- **THEN** `run.sh review S` prints a diff stat that includes `src/app.py` and the command `git merge --no-ff refs/opencode/review/S`

#### Scenario: Executable config is highlighted
- **WHEN** the session branch changes `.envrc` and `.github/workflows/ci.yml`
- **THEN** `review` lists both under a highlighted "executable config changed" heading

#### Scenario: Package scripts change is highlighted
- **WHEN** the session branch changes the `scripts` object in `package.json`
- **THEN** `review` lists `package.json` as executable config

#### Scenario: Package dependency change is not highlighted
- **WHEN** the session branch changes only `dependencies` in `package.json`
- **THEN** `review` does not list `package.json` as executable config

#### Scenario: Session config is not executed
- **WHEN** the session clone's `.git/config` sets `core.fsmonitor` to a command
- **THEN** `review` completes without that command running

#### Scenario: Review is audited
- **WHEN** `review` completes
- **THEN** a `session.review` audit record is written with the session id and the count of highlighted paths

### Requirement: Session listing and cleanup
The launcher SHALL provide `run.sh sessions`, which lists the sessions of the current repository with id, branch, base and creation time, and `run.sh clean <session-id>`, which deletes `refs/opencode/review/<session-id>` from the host repository and removes the session directory through a one-shot container running as the agent uid.

#### Scenario: Clean removes agent-owned files
- **WHEN** the operator runs `run.sh clean S`
- **THEN** the session directory `S` no longer exists and `refs/opencode/review/S` is deleted

### Requirement: Subcommand dispatch
`run.sh` SHALL treat a first positional argument of `review`, `sessions` or `clean` as its own subcommand and SHALL pass all other arguments to OpenCode as before. `home/general/bin/opencode-docker` SHALL pass these subcommands through to `run.sh`.

#### Scenario: Wrapper passes review through
- **WHEN** the user runs `opencode-docker review`
- **THEN** `run.sh review` runs and no agent container starts
