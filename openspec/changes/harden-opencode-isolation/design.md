## Context

This change layers on `secure-opencode-runtime`. All of that change's tasks are done. An isolation sweep of the working tree (recorded in `.scratch/secure-opencode-runtime/explore-isolation-findings.md`) found these gaps in safe mode:

- `run.sh:284` mounts the whole of `$CLAUDE_CONFIG_DIR` read-only at `/home/agent/.claude`. It holds `.credentials.json` (Claude OAuth access and refresh tokens, MCP OAuth tokens), `.claude.json`, `history.jsonl`, `projects/` (transcripts) and `session-env/`. `opencode.jsonc:65` allows `read` on `/home/agent/.claude/**`, and the `guard.ts` `PROTECTED` list (lines 23-31) matches only a file named exactly `credentials`.
- The image uid is the host uid (`Makefile:7-8` passes `id -u`; `Dockerfile:29-30,149`). Every mode-0600 host file that is mounted is readable by the agent. `run.sh:99-102` only warns on a mismatch.
- The repo is mounted read-write at its host path (`run.sh:214`), and the git common dir is mounted read-write when it is outside the repo (`run.sh:233`). The agent can write `.git/hooks`, `.git/config`, `.envrc`, `Makefile`, `.claude/settings.json` and CI config, which the host later executes with the user's privileges. The existing spec requirement "Workspace and worktree fidelity" requires git metadata "needed for ... hooks", which makes writable hooks an intended feature.
- The `x-broker` compose anchor (`docker-compose.yml:32-60`) mounts the whole `./secrets` directory into both the agent-facing `broker` and `broker-admin`, and passes `BROKER_ADMIN_TOKEN` and `LITELLM_MASTER_KEY` to both. LiteLLM also mounts the whole directory (line 244). The agent-facing broker is on `opencode-egress` (lines 282-284), so a broker bug gives the attacker every root secret and a route to the host LAN.
- `admin_app.py:64` compares the admin token with `!=`.
- `scripts/opencode-secrets.sh:90-93` routes `LITELLM_MASTER_KEY` to `litellm.env`, while `online.sh:100-103` and `llama.sh:107-110` generate it into `stack.env`; compose interpolates it from the shell. The two values can differ. `OPENROUTER_API_KEY` is not routed to `litellm.env`. Nothing writes `github-app.pem`.
- Compose defaults `LITELLM_DB_PASSWORD:-litellm-local` and `LLAMA_API_KEY:-sk-llama-local` are fixed strings.
- Only `excalidraw` and `llama` have resource limits.
- No rootless or user-namespace check exists; `design.md` and the README only mention rootless in prose.
- `--unsafe` prints a warning only (`run.sh:127`). `OPENCODE_DOCKER_ARGS` (`run.sh:195-198`) appends any `docker run` flag unchecked.
- Logging is fragmented: the broker writes events only to the SQLite `events` table (`store.py:209`) and runs uvicorn with `--no-access-log`; Squid writes its own text format; `run.sh` and `bin/lease` write free-text `echo ... >&2` lines.
- Squid has no destination-IP deny for RFC1918, loopback or the Docker gateway, and allows all of `.googleapis.com`.
- The broker serves only `/v1/token/github` and `/v1/token/litellm`, and a lease's service is a single TEXT column (`store.py:20`) fixed at approval.

Stakeholder: the single host user who runs OpenCode in Docker on Linux (primary) and macOS. The target is still trusted repositories, but the agent must be treated as able to run arbitrary shell commands inside its container.

## Goals / Non-Goals

**Goals:**

- No long-lived host credential is readable inside the safe-mode agent container.
- Nothing the agent writes is executed by the host unless the user reviews and merges it.
- A compromise of any one stack service exposes only that service's own secrets.
- The agent's in-container uid never maps to the host user's uid on Linux.
- Every security-relevant decision (session start, unsafe use, lease events, token issue, proxy allow and deny) produces one JSON line in one schema.
- The agent can obtain an additional service credential during a running session, with operator approval, without a restart.

**Non-Goals:**

- Protecting against kernel exploits. This is still container isolation, not a microVM.
- Preventing exfiltration through allowlisted domains. This is documented as an accepted risk.
- Isolating the shared `broker-state` SQLite volume between `broker` and `broker-admin`. A broker compromise can still write lease rows; see Risks.
- Revoking a static upstream API key at the provider. Revoking a grant stops the broker from serving it; it does not invalidate the key upstream.
- Supporting Podman or a non-Docker runtime.
- Carrying uncommitted working-tree changes into the session checkout.

## Decisions

### 1. Stage an allowlisted copy of `~/.claude` per session

`run.sh` builds `<session-dir>/claude/` on the host and mounts it read-only at `/home/agent/.claude`. It copies `skills/`, `commands/`, `hooks/` and `agents/` with `cp -RL` (symlinks are dereferenced, so links into the repo still resolve without mounting the main tree). It writes `settings.json` through a `jq` filter that keeps only the top-level keys `hooks`, `permissions` and `model`, and keeps an `env` entry only when its name does not match `(?i)(TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH|COOKIE)`. `mcpServers`, `apiKeyHelper`, `awsAuthRefresh`, `awsCredentialExport`, `otelHeadersHelper` and every other key are dropped. The directory list is a bash array `CLAUDE_ALLOW_DIRS` near the top of `run.sh`.

Reason: a key allowlist fails closed when Claude Code adds a new credential-bearing setting; a denylist does not. Copying (not bind-mounting subdirectories) removes the symlink dependency on the host repo and keeps the staged tree immutable for the session.

Alternative considered: bind-mount each allowed subdirectory read-only. Rejected because symlinks inside them still point at host paths that would have to be mounted, and `settings.json` cannot be filtered with a bind mount.

Alternative considered: a key denylist for `settings.json`. Rejected because it fails open for new keys.

Cost: a copy per session (the four directories on this host are small); hooks that read other `~/.claude` paths (for example `scripts/`) stop working until those paths are added to the allowlist. See Open Questions.

### 2. One secret file per service through compose `secrets:`

Replace the `./secrets:/run/secrets:ro` bind mounts with top-level compose `secrets:` entries backed by files in `stack/secrets/`, each granted only to the services that need it:

| Secret (file) | `broker` | `broker-admin` | `litellm` | `postgres` | `llama` |
|---|---|---|---|---|---|
| `github-app.pem` | yes | | | | |
| `litellm-keygen.key` | yes | yes | | | |
| `broker-admin.token` | | yes | | | |
| `litellm-master.key` | | | yes | | |
| `litellm.env` (provider keys only) | | | yes | | |
| `postgres-password` | | | yes | yes | |
| `llama-api-key` | | | yes | | yes |

- The `x-broker` anchor keeps only the shared non-secret settings. `BROKER_ADMIN_TOKEN` and `LITELLM_MASTER_KEY` leave the compose environment entirely.
- `settings.py` gains `*_FILE` variables (`BROKER_ADMIN_TOKEN_FILE`, `LITELLM_KEYGEN_KEY_FILE`) read once at startup. An empty or missing file disables that feature (503), as today.
- Postgres reads `POSTGRES_PASSWORD_FILE`. LiteLLM's entrypoint builds `LITELLM_DATABASE_URL` and exports `LITELLM_MASTER_KEY` and `LLAMA_API_KEY` from the secret files before `exec litellm`. llama reads its key from `/run/secrets/llama_api_key`.
- `stack.env` keeps only non-secret settings (`GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `LITELLM_MODELS`).

This refines the brief's "litellm gets litellm.env only": LiteLLM also needs the Postgres password and the llama key to do its job, but it gets nothing that belongs to the broker or GitHub.

Reason: each secret has exactly one file, which is the single source of truth, and each service's blast radius is its own column.

Alternative considered: keep one directory and rely on file modes. Rejected because every service runs as a fixed uid and would need its own owner; compose `secrets:` already gives per-service selection.

Cost: secret file layout changes; existing `stack.env` values must be migrated (task 2.2).

### 3. LiteLLM key-generation credential

The broker mints virtual keys with a dedicated key, not the master key. `stack/lib/secrets.sh` generates `litellm-keygen.key` (`sk-` plus 32 random bytes hex). After LiteLLM is healthy, `online.sh` and `llama.sh` register that exact value with `POST /key/generate` using the master key, with `key` set to the generated value, `user_role` / owning user set to `proxy_admin`, `allowed_routes` `["/key/generate", "/key/delete", "/key/info"]`, and `key_alias` `opencode-broker-keygen`. Registration is idempotent: a `GET /key/info` with the keygen key is tried first.

LiteLLM's documentation states that keys owned by a `proxy_admin` user can call `/key/generate`, and that `allowed_routes` still applies to them. This was not tested against the pinned `main-stable` digest. Task 2.4 verifies it with a live call before any other task depends on it.

Fallback if the pinned image does not support it: the broker and `broker-admin` receive `litellm-master.key` instead, and the README states that the broker holds the LiteLLM master key because LiteLLM offers no scoped key-generation credential in that version. The master key still never reaches the agent.

Reason: a broker compromise should not give control of LiteLLM's model, user and config endpoints.

Cost: one bootstrap call per stack start; a dependency on LiteLLM's role behaviour that must be re-checked when the image digest changes.

### 4. Broker egress through Squid

`broker` joins only `opencode-agent`. Its environment sets `HTTPS_PROXY=http://squid:3128` and `NO_PROXY=litellm,squid,localhost,127.0.0.1`. httpx uses `trust_env=True` by default, so `github.py` needs no client change. Squid already allows `.github.com`, which covers `api.github.com`, and its `localnet` source ACL covers the broker's address. `broker-admin` stays on `opencode-egress` (it needs LiteLLM and the loopback port publish) and gains no GitHub access.

Reason: the agent-facing broker is the stack service most exposed to the agent; removing its direct route removes host-LAN reach and puts its outbound calls in the proxy log.

Cost: GitHub minting fails when Squid is down; that is already a fail-closed condition for the agent.

### 5. Resource limits on every compose service

Each service gets `pids_limit`, `mem_limit` and `cpus` with `${NAME_PIDS_LIMIT:-n}`, `${NAME_MEMORY:-n}`, `${NAME_CPUS:-n}` defaults, following the existing `excalidraw` pattern (`docker-compose.yml:148-149`):

| Service | pids | memory | cpus |
|---|---|---|---|
| squid | 256 | 512m | 1 |
| postgres | 256 | 1g | 1 |
| litellm | 512 | 2g | 2 |
| broker | 128 | 256m | 0.5 |
| broker-admin | 128 | 256m | 0.5 |
| excalidraw | 512 (existing) | 2g (existing) | 1 |
| llama | 512 (existing) | 6g (existing) | 4 |

### 6. Single source for `LITELLM_MASTER_KEY` and generated stack passwords

A new `docker/opencode/stack/lib/secrets.sh` holds `ensure_secret_file <name> <generator>` and is sourced by both `online.sh` and `llama.sh`, replacing their duplicated `ensure_stack_env` generation (`online.sh:82-106`, `llama.sh:89-113`). It creates any missing file among `broker-admin.token`, `litellm-master.key`, `litellm-keygen.key`, `postgres-password`, `llama-api-key` with `openssl rand -hex 32` under `umask 077`. It never overwrites an existing file.

`scripts/opencode-secrets.sh` routing changes:

- `LITELLM_MASTER_KEY` is written to `litellm-master.key` (value only, no `KEY=`).
- `BROKER_ADMIN_TOKEN` is written to `broker-admin.token`.
- `OPENROUTER_API_KEY` and `GEMINI_API_KEY` join the `litellm.env` list.
- `--pem ENTRY[:ATTACHMENT]` runs `keepassxc-cli attachment-export <db> <entry> <attachment> <out>/github-app.pem` (default attachment name `github-app.pem`; `keepassxc-cli` 2.8.0 on this host supports `attachment-export`). The password is passed on stdin as for `show`.
- Non-merge mode truncates only the files it is about to write.

Compose no longer reads any secret from the shell, so `${LITELLM_MASTER_KEY}`, `${BROKER_ADMIN_TOKEN}`, `${LITELLM_DB_PASSWORD:-litellm-local}` and `${LLAMA_API_KEY:-sk-llama-local}` are removed.

Reason: one generator and one file per secret removes the mismatch between `stack.env` and `litellm.env` and removes the fixed default passwords.

### 7. Rootless Docker required in safe mode

`run.sh` calls a new `check_isolation_backend` before any container starts. It accepts the engine when any of these is true:

- `uname -s` is `Darwin`. Every macOS Docker engine (Docker Desktop, OrbStack, Colima) runs containers in a Linux VM, so the container cannot reach host files except through explicit shares.
- `docker info --format '{{.OperatingSystem}}'` contains `Docker Desktop` (Linux Docker Desktop also runs a VM).
- `docker info --format '{{json .SecurityOptions}}'` contains `name=rootless`.
- The same list contains `name=userns` (daemon `userns-remap`).

Otherwise safe mode exits non-zero with instructions. `--allow-rootful` skips the check for debugging only. It requires `OPENCODE_I_ACCEPT_UNSAFE=1`, prints a warning, and writes a `launcher.rootful_override` audit line. `--unsafe` does not require rootless.

Linux setup to document: `dockerd-rootless-setuptool.sh install`, an `/etc/subuid` and `/etc/subgid` entry of at least 65536 ids for the user (for example `freman:100000:65536`), `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock`, and `systemctl --user enable --now docker`.

Reason: with rootless Docker, container root maps to the host user and every other container uid maps into the subordinate range, so a container escape lands as an unprivileged user and the agent uid owns no host files.

Cost: users with a rootful daemon must set up rootless Docker once; the security stack must also run on the rootless daemon (the networks and volumes are recreated).

### 8. Fixed agent uid `60917:60917`

`Dockerfile` `ARG UID=60917` and `ARG GID=60917`. `Makefile` sets `UID ?= 60917` and `GID ?= 60917` and drops `$(shell id -u)`; `PUBLISH_UID`/`PUBLISH_GID` become 60917 too. `run.sh` replaces the mismatch warning at lines 99-102 with a check that refuses safe mode when the image label `dev.opencode.uid` equals `id -u`.

Why 60917: `login.defs` `UID_MAX` is 60000 on Debian, Arch and Fedora, so regular accounts stay below it; systemd `DynamicUser` allocates 61184-65519; 65534 is `nobody`. 60001-61183 is unused by convention. The uid must be below 65536 so a default 65536-wide subuid range maps it. 60917 sits in the gap and is not a round number another image would pick.

Bind-mount access under rootless Docker: the container uid 60917 maps to host uid `subuid_start + 60917`. That host uid owns no files, so:

- Read-only mounts (staged `~/.claude`, OpenCode config, host `.git/objects`) must be world-readable (`o+r` files, `o+rx` directories). `run.sh` checks this for the staged directory and the objects directory and fails with a message naming the path when it is not.
- Writable content (the session checkout) is created by a container running as 60917, so it is owned by the mapped uid from the start (Decision 9). No host-side `chown` is needed and none of the user's files change owner.
- Mode-0600 host files (for example `~/.config/opencode/service.json`) become unreadable to the agent, which is the intended result.
- Idmapped bind mounts (`--mount type=bind,...,bind-idmap`) would remove the world-readable requirement but are not available on Docker Desktop or older kernels. They are a later option.

macOS: Docker Desktop's file sharing presents shared files as owned by the accessing uid, so uid 60917 can read and write them without `chown`. No subuid setup applies.

`--unsafe` keeps legacy behaviour by running with `--user 0:0` on rootless Docker (container root is the host user) and `--user "$(id -u):$(id -g)"` on a rootful daemon.

### 9. Session workspace: a separate clone with alternates

The agent works in a per-session clone that shares the host repo's object store through git alternates, not in a linked worktree of the host repo.

Session layout under `${XDG_STATE_HOME:-~/.local/state}/opencode/sessions/<session-id>/`:

- `session.json`: `session_id`, `repo_root`, `git_common_dir`, `base_ref`, `base_sha`, `branch`, `created_at`.
- `claude/`: the staged allowlist (Decision 1).
- `work/`: the clone. It is mounted read-write at the same absolute path inside the container and is the workdir.

`session-id` is `<UTC yyyymmddTHHMMSS>-<6 hex>`; the branch is `opencode/<session-id>`; the lease `--session` is the same id.

Creation (`create_session_workspace` in `run.sh`):

1. Refuse if `REPO_ROOT` is not a git repo. Warn (do not refuse) if the working tree is dirty, because uncommitted changes are not carried over.
2. Create the session directory with mode 0700 and `work/` with mode 0777.
3. Run a one-shot container from the agent image as `60917:60917`, `--network none`, `--cap-drop=ALL`, with the host git common dir mounted read-only at its real path and `work/` read-write. Inside it run `git -c safe.directory='*' clone --shared --no-checkout <repo_root> <work>` then `git -C <work> checkout -b opencode/<session-id> <base_sha>`. `--shared` writes `objects/info/alternates` pointing at the host common dir's `objects/`; it is the same mechanism as `--reference` against the source repo.
4. Set the clone's `origin` URL to the host repo's `remote.origin.url` when that URL is `https://`, with any userinfo stripped, so `git fetch` inside the agent goes through Squid and the lease credential helper. Otherwise remove `origin`.
5. `chmod 0755 work/` from the host. Implementation note (2026-11-08): this step is not done. `work/` is owned by the host user, so at 0755 the agent uid 60917 cannot create top-level files in the clone. `work/` stays 0777; the session directory above it is 0700, so no other host user can reach it. `run.sh clean` makes the session directory and `work/` writable before the clean-up container removes `work/` as uid 60917.

Agent mounts: `work/` read-write, `<git_common_dir>/objects` read-only at its real path (so alternates resolve), nothing else from the host repo or its `.git`.

Reason for choosing the clone:

- The host `.git` has no writable path at all from the container. Hooks, config, refs, `packed-refs`, reflogs and the object store of the host repo are never writable. The ro-plus-rw-subdirectory option still exposes `refs/` (the agent could move `main`), `objects/` (the agent could delete or corrupt pack files) and would also need `logs/` writable for reflog updates.
- Under rootless Docker the agent uid owns no host files, so rw binds of the host `.git/objects` and `.git/refs` would require changing ownership of the user's own repository. The clone is written by uid 60917 from the start.
- The clone's own `hooks/` and `config` are writable by the agent but are never read by a host git process (see `review` below).

Alternative considered: ro bind of `.git` plus rw binds of `objects/`, `refs/`, `worktrees/<name>/`. Rejected for the reasons above.

Alternative considered: a full clone without alternates. Rejected only on cost; it would duplicate large object stores per session.

Cost: uncommitted changes are not visible to the agent; the user merges results with `review` instead of seeing them live in their editor; a host `git gc --prune=now` that removes objects the session depends on would break that session (only possible after history rewrite of the base).

`review` (`run.sh review [<session-id>]`, default the newest session for this repo):

1. In the host repo, run `git fetch --no-tags --no-write-fetch-head <work> +refs/heads/opencode/<id>:refs/opencode/review/<id>`. No git command is ever run with the session clone as its working directory or `-C` target, so the clone's `config` (for example `core.fsmonitor`) and hooks are never read by a host git process. Fetch does not run hooks.
2. Print `git diff --stat <base_sha>...refs/opencode/review/<id>`.
3. Print a highlighted list of changed paths that match the executable-config pattern: `.git/hooks/**`, `.githooks/**`, `.envrc`, `.env*`, `Makefile`, `*.mk`, `.github/workflows/**`, `.claude/**`, `.opencode/**`, `.mcp.json`, `AGENTS.md`, `CLAUDE.md`, `.gitmodules`, `.pre-commit-config.yaml`, and `package.json` when its `scripts` object differs between base and head (compared with `jq .scripts` on `git show` output).
4. Print the merge command (`git merge --no-ff refs/opencode/review/<id>`) without running it, and write a `session.review` audit line with the flagged count.

`sessions` lists session directories for the current repo from their `session.json`. `clean <session-id>` removes a session: it deletes `refs/opencode/review/<id>` from the host repo and removes the directory through a one-shot container running as 60917 (the host user cannot delete files owned by the mapped uid).

`run.sh` treats a first positional argument of `review`, `sessions` or `clean` as its own subcommand; all other arguments still pass to `opencode`. `home/general/bin/opencode-docker` passes them through.

### 10. `--unsafe` fencing and `OPENCODE_DOCKER_ARGS` validation

`--unsafe` requires all of:

- `OPENCODE_I_ACCEPT_UNSAFE=1` in the environment;
- stdin and stderr are TTYs;
- the user types `unsafe` at the prompt printed after the existing `warn_unsafe` text.

On success `run.sh` writes an `unsafe.start` audit line with the exposure list in `detail`. On any failure it exits 2 and writes `unsafe.refused`. There is no non-interactive bypass; tests allocate a pseudo-terminal with `script -qec`.

`validate_docker_args` parses `OPENCODE_DOCKER_ARGS` into words and rejects, in any of the forms `--flag`, `--flag=value`, `-f`, `-fvalue`: `--privileged`, `--network`, `--net`, `--pid`, `--ipc`, `--uts`, `--userns`, `--cgroupns`, `--cap-add`, `--security-opt`, `--device`, `-u`, `--user`, `-v`, `--volume`, `--mount`, `--volumes-from`. The brief named `--privileged`, `--network`, `--pid`, `--ipc`, `--cap-add`, `-v`, `--volume` and `--mount`; the rest widen isolation in the same way and are added so the list has no obvious bypass. When `OPENCODE_I_ACCEPT_UNSAFE=1` is set, rejected flags are allowed with a warning and a `docker_args.override` audit line.

### 11. One structured log line format

Schema (one JSON object per line, UTF-8, no pretty printing):

| Field | Type | Meaning |
|---|---|---|
| `ts` | string | RFC 3339 UTC with milliseconds, `Z` suffix |
| `component` | string | `run.sh`, `lease-cli`, `broker`, `broker-admin`, `squid` |
| `event` | string | dotted name, for example `session.start`, `lease.grant`, `token.issue`, `proxy.deny` |
| `lease_id` | string or null | lease the event concerns, when known |
| `repo` | string or null | `owner/repo` when known, otherwise the absolute repo path, otherwise null |
| `outcome` | string | `ok`, `deny`, `error`, `warn` |
| `detail` | object | event-specific fields; never a secret value |

Emitters:

- `run.sh` and `bin/lease`: a `log_event` bash function built with `jq -nc`, appended to `${XDG_STATE_HOME:-~/.local/state}/opencode/audit.jsonl` (mode 0600). The human-readable `echo ... >&2` messages stay.
- Broker: a new `broker/log.py` with `emit(component, event, lease_id, repo, outcome, detail)` that prints one line to stdout. `Store.event` (`store.py:209`) calls it after the SQLite insert, using the same secret-key filter (`store.py:222`). The SQLite `events` table stays as the queryable store; stdout is the stream. `component` is passed in from `create_app` (`broker` or `broker-admin`).
- Squid: a `logformat opencode_json` using Squid's quoted-string modifier, written to the existing `access.log`. The agent-supplied `X-Lease-Id` header goes into `detail.claimed_lease_id`, not `lease_id`, because the agent can set it to any value.

Viewer: `docker/opencode/bin/opencode-log pretty [FILE...]` reads JSON lines from files or stdin. Options: `--component`, `--lease`, `--outcome`, `--style` (default `dracula`), `--no-color`. It prints each record on one line with keys in schema order and each key in a fixed colour per column; the `outcome` value is green for `ok`, red for `deny` and `error`, and yellow for `warn`. Colour is off when stdout is not a TTY or `NO_COLOR` is set. Non-JSON lines are printed unchanged.

Viewer dependency, recommendation: depend on `laser-prynter` and call `laser_prynter.pp` (`ppd` at `laser_prynter/pp.py:147`, which uses Pygments `JsonLexer`, `Terminal256Formatter` and the `dracula` style, with a `ColumnStyle` at line 183). Declare it in PEP 723 inline script metadata and run the viewer with `uv run --script`.

> Recommendation: depend on `laser-prynter`.

> Reason: it is the user's existing library for this exact output; vendoring would create a second copy of the column style that drifts from the original.

Alternative: vendor a small equivalent (Pygments plus a column style) into `docker/opencode/bin/opencode-log`. Cost of the recommendation: the host needs `uv` and network access to resolve `laser-prynter` on first run, and its install source (PyPI name or git URL) must be confirmed. Cost of the alternative: about 60 lines of duplicated formatting code.

### 12. Egress and admin hardening

- `admin_app.py` `require_admin` uses `hmac.compare_digest(x_admin_token.encode(), settings.admin_token.encode())` and writes an `admin.auth` event with outcome `deny` on mismatch.
- `squid.conf` adds `acl blocked_dst dst 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 0.0.0.0/8 ::1/128 fc00::/7 fe80::/10` and `http_access deny blocked_dst` immediately after `deny metadata` and before `allow localnet allowed_domains`. Squid resolves the hostname and checks the resolved address, which covers DNS rebinding and allowlisted names that resolve privately.
- The Docker gateway: the compose file pins `opencode-egress` to `${OPENCODE_EGRESS_SUBNET:-172.31.250.0/24}` with an `ipam` block. Its gateway is therefore inside `172.16.0.0/12` and covered by `blocked_dst`. `online.sh` refuses an override subnet that is not inside an RFC1918 range.
- `.googleapis.com` becomes `generativelanguage.googleapis.com`.
- README gains "Accepted exfiltration risk": an agent can send data to any allowlisted destination, including pushing to any GitHub repository or gist the lease token can reach and calling a model provider with an attacker's own key. The allowlist limits where data can go; it does not stop data leaving.

### 13. KeePassXC flow documentation

README "Secrets" gains a four-step flow: (1) host KeePassXC database holds long-lived secrets; (2) `scripts/opencode-secrets.sh --source keepassxc` extracts named entries and the `--pem` attachment; (3) values are written to per-service files in `docker/opencode/stack/secrets/` (mode 0600, directory 0700, gitignored); (4) compose grants each file to the services in Decision 2. The agent never sees the `.kdbx` or the files. The legacy mount table (`README.md:96-110`) gains a "Safe mode" column so the `~/.claude`, `~/.agents` and `~/.config/opencode` rows no longer read as read-write in safe mode.

### 14. On-demand service grants

The operator adds a service to a running lease from the host:

```
lease grant <lease_id> <service> [--ttl 1h] [--keepassxc ENTRY] [--file PATH]
```

- Secret source, resolved on the host by `bin/lease`: `--file` (default `docker/opencode/stack/secrets/services/<service>.env`), or `--keepassxc ENTRY`, which runs `keepassxc-cli show -q -a password` with the password on stdin and builds `{"TOKEN": value}`. The `.env` file holds `NAME=value` lines; all pairs are sent.
- `bin/lease` POSTs `{service, ttl_seconds, values}` to `broker-admin` `POST /v1/leases/{lease_id}/grants`. Values travel over the loopback admin port only.
- `broker-admin` validates the service name (`^[a-z][a-z0-9-]{1,31}$`, not `github`, `litellm` or `all`), clamps `ttl_seconds` to the lease's remaining lifetime and to `BROKER_MAX_GRANT_TTL_SECONDS` (default 3600, default grant 900), and stores a row in a new `grants` table: `grant_id`, `lease_id`, `service`, `secret_json`, `created_at`, `expires_at`, `status`.
- The agent calls `GET /v1/token/{service}` with its lease token. The broker returns `{"service", "values", "expires_at"}` when an active, unexpired grant exists, `403` otherwise. This route is registered after the literal `github` and `litellm` routes so it does not shadow them.
- `lease revoke <lease_id>` revokes all grants and clears `secret_json`. `lease ungrant <lease_id> <service>` revokes one. Expired grants are cleared on read.
- Each issue writes `token.issue` with `detail.service`, never the value.
- Inside the container, `lease token <service>` prints the JSON to stdout. Nothing writes it to disk; the guard plugin and README tell the agent to read it into a process environment, not a file.

Reason: the secret stays on the host until the operator grants it, so the agent-facing broker holds only secrets for services that have an active grant, not every service file. This keeps Decision 2's per-service property.

Alternative considered: mount `stack/secrets/services/` into the broker and have grants only flip a flag. Rejected because the agent-facing broker would hold every service's secret at all times.

Alternative considered: change `leases.service` to a JSON list. Rejected because grants have their own TTL and secret payload, which a list cannot hold.

Cost: a schema migration (new table only; existing rows unchanged); granted secrets sit in the `broker-state` SQLite file in plaintext until expiry or revocation.

Worked example (Excalidraw API key): the operator stores `EXCALIDRAW_API_KEY` in KeePassXC, runs `lease grant lse_abc excalidraw --keepassxc excalidraw/api-key --ttl 30m`, adds the Excalidraw API host to the Squid allowlist if it is not there, and the agent runs `lease token excalidraw` to get `{"service":"excalidraw","values":{"TOKEN":"..."},"expires_at":"..."}`.

## Risks / Trade-offs

- [Shared `broker-state` volume] → A broker compromise can insert lease or grant rows directly. Mitigation in this change: none beyond fewer secrets in the broker. Splitting state is a follow-up.
- [Granted static keys outlive revocation upstream] → Keep grant TTLs short, document that revoking a grant does not revoke the key at the provider, and rotate keys that may have leaked.
- [Session clone depends on host objects] → A host `git gc --prune=now` after rewriting the base history can break a running session. Document; `review` reports a clear error.
- [Review fetch reads the clone through `git upload-pack`] → `upload-pack` ignores repository-level hook and pack-object settings since git 2.36 safety changes; `review` never runs other git commands in the clone. Document the minimum git version.
- [World-readable requirement for ro mounts under rootless] → Users with `umask 077` repos get a clear error. Idmapped mounts are a later fix.
- [Hooks that need `~/.claude/scripts/` break] → Open question below.
- [LiteLLM scoped key unverified] → Task 2.4 gates the design; fallback is documented.
- [Squid JSON log escaping] → Use Squid's quoted-string modifier on every free-text field; a test feeds a URL containing a quote.

## Migration Plan

1. Rebuild the image (`make build`); the uid changes to 60917. Old named volumes `opencode-data`, `opencode-state`, `opencode-cache` and `opencode-audit` are owned by the old uid; `run.sh` detects an unwritable volume and prints the `docker volume rm` command.
2. Set up rootless Docker on Linux, then run `online.sh up`. `stack/lib/secrets.sh` migrates `BROKER_ADMIN_TOKEN` and `LITELLM_MASTER_KEY` from `stack.env` into their new files once, then removes them from `stack.env`.
3. Re-run `scripts/opencode-secrets.sh` with `--pem` to place `github-app.pem`.
4. Existing linked-worktree workflows change to `run.sh` then `run.sh review`.
5. Rollback: check out the previous commit and rebuild; `--unsafe` (with the new fence) remains for debugging.

## Open Questions

Resolved by the user on 2026-11-08:

- Claude allowlist: `CLAUDE_ALLOW_DIRS` is `skills commands hooks agents scripts CLAUDE.md` by default. `scripts/` is included so the hooks in `settings.json` that call `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/*` work in the container. `CLAUDE.md` is a file, not a directory; `stage_claude_dir` copies it the same way.
- Log viewer: `opencode-log` depends on `laser-prynter @ git+https://github.com/tmck-code/laser-prynter.git` (package `laser_prynter`, function `pp.ppd`) through PEP 723 inline metadata. The package is not vendored.
- `lease grant` is limited to generic services. It does not add `github` or `litellm` to a running lease.
- LiteLLM key-generation credential: see the result of task 2.4 below.

Task 2.4 result (live check, 2026-11-08, worker w1):

- Image: `ghcr.io/berriai/litellm:main-stable@sha256:c169fb3adc514fcf210377c203f3de406d54f10bfdacf13948a4a839db9af7de` (the digest pinned in `docker-compose.yml`), with `postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab`, on a throwaway network. All throwaway objects (`hoi-test-*`) were removed afterwards.
- Steps and results (calls made with `python urllib` inside the LiteLLM container):
  - `POST /user/new` with the master key, `user_role` `proxy_admin`, `user_id` `hoi-keygen`: HTTP 200.
  - `POST /key/generate` with the master key, fixed `key`, `user_id` `hoi-keygen`, `allowed_routes ["/key/generate","/key/delete","/key/info"]`: HTTP 200.
  - `GET /key/info?key=<keygen key>` with the keygen key: HTTP 200.
  - `POST /key/generate` with the keygen key: HTTP 200 (a child key was created).
  - `POST /key/delete` with the keygen key (by alias): HTTP 200.
  - `POST /model/new`, `POST /user/new` and `GET /key/list` with the keygen key: HTTP 403, "Virtual key is not allowed to call this route. Only allowed to call routes: ['/key/generate', '/key/delete', '/key/info']".
  - `GET /key/info?key=sk-nope` with the keygen key (unknown target): HTTP 404. `GET /key/info` with an unregistered caller key: HTTP 401. The idempotent registration check in `register_keygen_key` treats any non-200 as "not registered".
- Not tested: a non-`proxy_admin` user with the same key and routes (the registration call returned HTTP 400, cause not investigated), so it is not shown that the `proxy_admin` role is what permits `/key/generate`. The scoped key works on this digest either way.
- Path chosen: the scoped key-generation credential (Decision 3, main path). The master-key fallback is not used. Task 2.5 (`register_keygen_key`) is implemented. Re-run this check whenever the image digest changes.
- `litellm-keygen.key` is not granted to the `litellm` container, so `register_keygen_key` sends it on stdin from the host file. The master key is read inside the container from `/run/secrets/litellm_master_key`.

Still open:

- Does the Excalidraw API host need a permanent Squid allowlist entry, or a per-grant allowlist mechanism? This is out of scope for this change. Until it is decided, a grant for a service whose host is not in `squid.conf` gives the agent a token it cannot use through the proxy.
