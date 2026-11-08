## Why

The `secure-opencode-runtime` change put the agent on an internal network behind a proxy, a lease broker and LiteLLM, but an isolation sweep found that the safe-mode agent can still read live host credentials and write files that the host later executes. The agent mounts the whole of `~/.claude` (including `.credentials.json` with the Claude OAuth refresh token and MCP OAuth tokens), runs as the host uid, edits the user's working tree and `.git` read-write (including `.git/hooks` and `.git/config`), and talks to a broker that holds every root secret in the stack. These gaps undo the "no long-lived secrets in the agent" and "host state is not silently modified" goals, so they must be closed before the stack is used on real repositories.

## What Changes

- **BREAKING**: Safe mode no longer mounts `$CLAUDE_CONFIG_DIR`. `run.sh` stages a per-session copy that contains only `skills/`, `commands/`, `hooks/`, `agents/` and a filtered `settings.json`, and mounts that copy read-only. `.credentials.json`, `.claude.json`, `history.jsonl`, `projects/` and `session-env/` are never present in the container.
- Tighten `opencode.jsonc` and `guard.ts` so `.credentials.json`, `.claude.json` and `history.jsonl` are denied by name.
- Mount one secret file per compose service through the compose `secrets:` feature. The agent-facing broker gets the GitHub App key and a LiteLLM key-generation credential only. LiteLLM gets its own provider and database secrets only. Only `broker-admin` gets the admin token.
- The agent-facing broker leaves `opencode-egress`. Its GitHub API calls go through Squid.
- Every compose service gets `pids_limit`, `mem_limit` and `cpus`.
- Fix `scripts/opencode-secrets.sh`: `LITELLM_MASTER_KEY` has one home, `OPENROUTER_API_KEY` is routed to LiteLLM, and a new `--pem` option exports `github-app.pem` from a KeePassXC attachment. `online.sh` and `llama.sh` generate the Postgres password and the llama API key instead of using compose defaults.
- **BREAKING**: Safe mode requires rootless Docker (or a user-namespace-remapped daemon, or a VM-backed engine such as Docker Desktop or any macOS engine). A debug-only `--allow-rootful` override exists.
- **BREAKING**: The agent image runs as a fixed uid/gid `60917:60917` instead of the host uid. `make build` no longer passes `id -u`.
- **BREAKING**: The agent no longer edits the user's working tree. `run.sh` creates a per-session git checkout that borrows objects from the host repo through git alternates, on a branch `opencode/<session-id>`. The host `.git` is never writable from the container; only its `objects/` directory is mounted, read-only.
- Add `run.sh review`, `run.sh sessions` and `run.sh clean`. `review` fetches the session branch into the host repo, prints `git diff --stat` against the base commit, and highlights changed files that a host tool would execute.
- **BREAKING**: `--unsafe` requires `OPENCODE_I_ACCEPT_UNSAFE=1` and a typed confirmation on a TTY, and writes an audit record. `OPENCODE_DOCKER_ARGS` rejects isolation-widening flags unless the same variable is set.
- Add one structured JSON log line format (`ts`, `component`, `event`, `lease_id`, `repo`, `outcome`, `detail`) emitted by `run.sh`, the broker, the `lease` CLI and Squid, plus an `opencode-log pretty` viewer with Pygments colouring.
- Compare the admin token with `hmac.compare_digest`. Add a Squid destination-IP deny for private, loopback and link-local ranges ahead of the allow rule. Narrow `.googleapis.com` to `generativelanguage.googleapis.com`.
- Document the accepted exfiltration risk through allowlisted domains, the KeePassXC four-step secret flow, and correct the README mount table.
- Add on-demand per-service tokens: an agent-facing `GET /v1/token/{service}` and an admin `lease grant <lease_id> <service> [--ttl]` that adds a service to a running lease without restarting the agent.

## Capabilities

### New Capabilities

- `session-workspace`: per-session git checkout with alternates, read-only host object store, session branch naming, and the `review`, `sessions` and `clean` subcommands.
- `structured-audit-log`: the shared JSON log line schema, the emitters (`run.sh`, broker, `lease` CLI, Squid) and the `opencode-log pretty` viewer.
- `service-token-grants`: generic per-service secrets granted to a running lease and fetched by the agent over HTTP with a short TTL.

### Modified Capabilities

- `opencode-runtime-hardening`: `~/.claude` allowlist staging, fixed agent uid, rootless Docker requirement, fenced `--unsafe` and `OPENCODE_DOCKER_ARGS`, and the workspace requirement that previously required writable hook metadata.
- `credential-broker`: per-service secret files, broker off the egress network, constant-time admin auth, single source for the LiteLLM master key, KeePassXC `--pem`, generated stack passwords, and structured lease audit.
- `egress-control`: destination-IP deny ahead of the allowlist, narrowed Google domain, broker egress through Squid, structured proxy log, and the documented exfiltration risk.
- `opencode-guardrails`: Claude credential files added to the protected paths.

## Impact

- `docker/opencode/run.sh`: new staging, rootless check, session workspace, subcommands, unsafe fencing, argument validation, JSON logging.
- `docker/opencode/Dockerfile`, `docker/opencode/Makefile`: fixed uid/gid `60917`; new test targets.
- `docker/opencode/stack/docker-compose.yml`, `squid.conf`, `online.sh`, `llama.sh`, `litellm.yaml`, `secrets.example.yaml`; new `stack/lib/secrets.sh`.
- `docker/opencode/broker/`: `admin_app.py`, `agent_app.py`, `store.py`, `settings.py`, `litellm.py`, new `log.py`, tests.
- `docker/opencode/bin/lease` (new `grant`, admin token file default), new `docker/opencode/bin/opencode-log`.
- `docker/opencode/config/opencode.jsonc`, `docker/opencode/config/plugins/guard.ts`.
- `scripts/opencode-secrets.sh`; `home/general/bin/opencode-docker` (passes the new subcommands through).
- Tests under `docker/opencode/test/` (`no-secrets.sh`, `unsafe-mode.sh`, `worktree-smoke.sh`, `egress-bypass.sh`, new `rootless-check.sh`, `review.sh`, `docker-args.sh`, `stack-secrets.sh`) and `docker/opencode/broker/tests/`.
- `docker/opencode/README.md`.
- Host prerequisites: rootless Docker with `/etc/subuid` and `/etc/subgid` entries on Linux. Existing images built with the host uid must be rebuilt. Existing stacks must re-run `online.sh up` to regenerate secrets into the new file layout.
- This change depends on `secure-opencode-runtime` and must be archived after it.
