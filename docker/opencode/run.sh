#!/usr/bin/env bash
# Run an OpenCode v2 session in the hardened opencode-dev image.
#
#   ./run.sh                     # OpenCode TUI in the current repo (safe mode)
#   ./run.sh --shell             # bash in the same container setup
#   ./run.sh run "explain this"  # any non-TUI OpenCode command
#   ./run.sh --unsafe            # legacy mounts/network for trusted debugging
#   ./run.sh --with-ssh          # mount ~/.ssh and forward the agent
#   ./run.sh --with-gh           # mount ~/.config/gh read-only
#   ./run.sh --read-only         # read-only rootfs with tmpfs and named volumes
#
# Safe mode requires the local stack (Squid, broker, LiteLLM) to be healthy and
# a lease token to exist. It fails closed rather than starting an agent with no
# egress control or credentials.
#
# Env: IMAGE, REPO_ROOT, CLAUDE_CONFIG_DIR, XDG_*_HOME,
#      LEASE_TOKEN, LEASE_TOKEN_FILE, BROKER_URL,
#      OPENCODE_ENV_PASSTHROUGH="FOO BAR",
#      OPENCODE_DOCKER_ARGS="--network=host"  # extra `docker run` flags
set -euo pipefail

IMAGE="${IMAGE:-opencode-dev:local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOST_OS="$(uname -s)"

shell_mode=0
unsafe=0
with_ssh=0
with_gh=0
read_only=0

usage() {
  cat <<'EOF'
Usage: run.sh [options] [opencode arguments]

Options:
  --shell          open bash in the same container setup
  --unsafe         legacy behaviour: host gateway, SSH/gh mounts, token
                   passthrough, no capability/resource defaults (warns)
  --with-ssh       mount ~/.ssh read-only and forward SSH_AUTH_SOCK on Linux
  --with-gh        mount ~/.config/gh read-only
  --read-only      run the agent root filesystem read-only
  -h, --help       show this help

Safe mode (the default) attaches the container to the internal
`opencode-agent` network only, drops capabilities, applies resource limits and
requires a healthy proxy/broker/LiteLLM stack plus a lease token.

Environment:
  IMAGE, REPO_ROOT, CLAUDE_CONFIG_DIR, XDG_*_HOME,
  LEASE_TOKEN, LEASE_TOKEN_FILE, BROKER_URL,
  OPENCODE_ENV_PASSTHROUGH, OPENCODE_DOCKER_ARGS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell|shell) shell_mode=1; shift ;;
    --unsafe) unsafe=1; shift ;;
    --with-ssh) with_ssh=1; shift ;;
    --with-gh) with_gh=1; shift ;;
    --read-only) read_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) break ;;
    *) break ;;
  esac
done

# Repo to expose at the same absolute path inside the container. Default to
# the git root of the caller's directory, so running from a subdirectory mounts
# the whole repo; fall back to $PWD outside git.
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
fi
if [[ ! -d "$REPO_ROOT" ]]; then
  echo "error: REPO_ROOT does not exist: $REPO_ROOT" >&2
  exit 1
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: image '$IMAGE' not found.

Build it first:
  make -C "$SCRIPT_DIR" build

or from this directory:
  cd "$SCRIPT_DIR" && make build
EOF
  exit 1
fi

# Warn when the image was built for a different host user; bind-mounted files
# would be read/written as the wrong UID.
image_uid="$(docker image inspect --format '{{ index .Config.Labels "dev.opencode.uid" }}' "$IMAGE" 2>/dev/null || true)"
if [[ "$image_uid" =~ ^[0-9]+$ && "$image_uid" != "$(id -u)" ]]; then
  echo "warning: image built for UID $image_uid, host UID is $(id -u)." >&2
  echo "         Rebuild with: make -C \"$SCRIPT_DIR\" build" >&2
fi

# Host config/state dirs. Create them as the host user first so Docker does not
# create them as root on first mount.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"

for dir in "$CLAUDE_DIR" "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$CACHE_DIR"; do
  mkdir -p "$dir"
done

CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd -P)"
CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd -P)"
DATA_DIR="$(cd "$DATA_DIR" && pwd -P)"
STATE_DIR="$(cd "$STATE_DIR" && pwd -P)"
CACHE_DIR="$(cd "$CACHE_DIR" && pwd -P)"

LEASE_TOKEN_FILE="${LEASE_TOKEN_FILE:-$STATE_DIR/lease-token}"
BROKER_URL_IN_CONTAINER="${BROKER_URL:-http://broker:8080}"
PROXY_URL="http://squid:3128"
NO_PROXY_VALUE="litellm,broker,squid,excalidraw,localhost,127.0.0.1,::1"

warn_unsafe() {
  cat >&2 <<'EOF'
WARNING: --unsafe restores the legacy trust model:
  - default Docker bridge and host.docker.internal (host services reachable)
  - ~/.ssh read-only and SSH agent forwarding (when available)
  - ~/.config/gh read-only
  - provider API keys and GITHUB_TOKEN/GH_TOKEN from the host environment
  - no --cap-drop=ALL, no-new-privileges, PID/memory/CPU limits
Use it for one debugging session, never as the daily default.
EOF
}

warn_with_ssh() {
  cat >&2 <<'EOF'
WARNING: --with-ssh mounts the host ~/.ssh read-only and may forward
SSH_AUTH_SOCK. The agent can read every key and use the forwarded agent.
EOF
}

warn_with_gh() {
  cat >&2 <<'EOF'
WARNING: --with-gh mounts ~/.config/gh read-only. The agent can read the host
gh OAuth token, which is not scoped to this job and survives revocation.
EOF
}

(( with_ssh )) && warn_with_ssh
(( with_gh )) && warn_with_gh
(( unsafe )) && warn_unsafe

docker_args=(run --rm --init)

# OpenCode v2 registers local TUI/CLI plugins in cli.json by absolute path
# (for example the YAS statusline). They live outside the config dir, so mount
# each one at its host path to keep that absolute entry resolvable. npm package
# names are installed inside the container and need no mount.
CONFIG_FILE=""
for candidate in "$CONFIG_DIR/cli.json" "$CONFIG_DIR/cli.jsonc"; do
  if [[ -f "$candidate" ]]; then
    CONFIG_FILE="$candidate"
    break
  fi
done
if [[ -n "$CONFIG_FILE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r plugin; do
      [[ -n "$plugin" ]] || continue
      [[ "$plugin" == /* ]] || continue
      if [[ ! -d "$plugin" ]]; then
        echo "warning: plugin path in $CONFIG_FILE is not a host directory: $plugin" >&2
        continue
      fi
      case "$plugin" in
        "$REPO_ROOT"|"$REPO_ROOT"/*|"$CLAUDE_DIR"|"$CLAUDE_DIR"/*|"$CONFIG_DIR"|"$CONFIG_DIR"/*) continue ;;
      esac
      docker_args+=(-v "$plugin:$plugin:ro")
    done < <(
      jq -r '(.plugins // [])[]
             | if type == "string" then . elif type == "object" then (.package // empty) else empty end' \
        "$CONFIG_FILE" 2>/dev/null || true
    )
  else
    echo "warning: jq not found; local plugin paths in $CONFIG_FILE will not be mounted" >&2
  fi
fi

# Extra `docker run` flags, word-split deliberately (it is a list of flags, not
# one value).
if [[ -n "${OPENCODE_DOCKER_ARGS:-}" ]]; then
  read -r -a extra_docker_args <<< "${OPENCODE_DOCKER_ARGS}"
  docker_args+=("${extra_docker_args[@]}")
fi

# Allocate a pseudo-TTY only when attached to a terminal.
if [[ -t 0 ]]; then
  docker_args+=(-i)
fi
if [[ -t 1 ]]; then
  docker_args+=(-t)
fi
if [[ -t 1 && -n "${TERM:-}" ]]; then
  docker_args+=(--env TERM)
fi

# Repo at the same absolute path, so paths in prompts, configs and logs match.
# It also keeps ~/.claude symlinks into this repo resolving, since deploy.sh
# links them by absolute path.
docker_args+=(-v "$REPO_ROOT:$REPO_ROOT" --workdir "$REPO_ROOT")

# Linked worktrees keep their git dir under the main repo's .git/worktrees/<name>,
# outside the worktree root. Mount the common dir at the same path so git works
# inside the container. Skip it when the common dir is already covered by the
# repo mount.
git_common=""
if git_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"; then
  if [[ "$git_common" != /* ]]; then
    git_common="$REPO_ROOT/$git_common"
  fi
  if [[ -d "$git_common" ]]; then
    git_common="$(cd "$git_common" && pwd -P)"
    if [[ "$git_common" != "$REPO_ROOT" && "$git_common" != "$REPO_ROOT"/* ]]; then
      docker_args+=(-v "$git_common:$git_common")
    fi
  fi
else
  git_common=""
fi

# A linked worktree commonly has ~/.claude symlinks into the main checkout
# (deploy.sh links by absolute path). Mount the main working tree read-only so
# those resolve, without letting a worktree session write to the main checkout.
main_toplevel=""
if [[ -n "${git_common:-}" && -d "$git_common" ]]; then
  main_tree="$(cd "$(dirname "$git_common")" && pwd -P)"
  main_toplevel="$(git -C "$main_tree" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "$main_toplevel" == "$main_tree" \
     && "$main_tree" != "$REPO_ROOT" \
     && "$main_tree" != "$REPO_ROOT"/* ]]; then
    docker_args+=(-v "$main_tree:$main_tree:ro")
  fi
fi

# Scoped git configuration. The image no longer trusts every path; the launcher
# trusts only the mounted repo/worktree paths it actually exposes.
git_config_count=0
add_git_config() {
  local key="$1" value="$2"
  docker_args+=(--env "GIT_CONFIG_KEY_${git_config_count}=${key}")
  docker_args+=(--env "GIT_CONFIG_VALUE_${git_config_count}=${value}")
  git_config_count=$((git_config_count + 1))
}
add_git_config "safe.directory" "$REPO_ROOT"
if [[ -n "$git_common" && "$git_common" != "$REPO_ROOT" ]]; then
  add_git_config "safe.directory" "$git_common"
fi
if [[ -n "$main_toplevel" && "$main_toplevel" != "$REPO_ROOT" ]]; then
  add_git_config "safe.directory" "$main_toplevel"
fi

# Claude-compatible skills live in ~/.claude and, for OpenCode, ~/.agents.
# Config and plugins are read-only: a session may edit the repo, not its own
# policy. State and cache go to dedicated volumes in safe mode.
if (( unsafe )); then
  docker_args+=(
    -v "$CLAUDE_DIR:/home/agent/.claude"
    -v "$CONFIG_DIR:/home/agent/.config/opencode"
    -v "$DATA_DIR:/home/agent/.local/share/opencode"
    -v "$STATE_DIR:/home/agent/.local/state/opencode"
    -v "$CACHE_DIR:/home/agent/.cache/opencode"
  )
else
  docker_args+=(
    -v "$CLAUDE_DIR:/home/agent/.claude:ro"
    -v "$CONFIG_DIR:/home/agent/.config/opencode:ro"
    -v "opencode-data:/home/agent/.local/share/opencode"
    -v "opencode-state:/home/agent/.local/state/opencode"
    -v "opencode-cache:/home/agent/.cache/opencode"
    -v "opencode-audit:/var/log/opencode"
  )
fi

if [[ -d "$HOME/.agents" ]]; then
  if (( unsafe )); then
    docker_args+=(-v "$HOME/.agents:/home/agent/.agents")
  else
    docker_args+=(-v "$HOME/.agents:/home/agent/.agents:ro")
  fi
fi

if [[ -f "$HOME/.gitconfig" ]]; then
  docker_args+=(-v "$HOME/.gitconfig:/home/agent/.gitconfig:ro")
fi

git_name="$(git -C "$REPO_ROOT" config --get user.name 2>/dev/null || true)"
git_email="$(git -C "$REPO_ROOT" config --get user.email 2>/dev/null || true)"
if [[ -n "$git_name" ]]; then
  docker_args+=(--env "GIT_AUTHOR_NAME=$git_name" --env "GIT_COMMITTER_NAME=$git_name")
fi
if [[ -n "$git_email" ]]; then
  docker_args+=(--env "GIT_AUTHOR_EMAIL=$git_email" --env "GIT_COMMITTER_EMAIL=$git_email")
fi

pass_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    docker_args+=(--env "$name")
  fi
}

if (( unsafe )); then
  for name in \
    ANTHROPIC_API_KEY \
    OPENAI_API_KEY \
    OPENROUTER_API_KEY \
    GOOGLE_GENERATIVE_AI_API_KEY \
    GEMINI_API_KEY \
    GROQ_API_KEY \
    MISTRAL_API_KEY \
    XAI_API_KEY \
    DEEPSEEK_API_KEY \
    GITHUB_TOKEN \
    GH_TOKEN \
    GH_HOST
  do
    pass_env "$name"
  done

  # SSH keys/config + agent forwarding are legacy `--unsafe` behaviour, and
  # remain available individually through --with-ssh.
  if (( unsafe || with_ssh )) && [[ -d "$HOME/.ssh" ]]; then
    ssh_dir="$(cd "$HOME/.ssh" && pwd -P)"
    docker_args+=(-v "$ssh_dir:/home/agent/.ssh:ro")
    if [[ "$HOST_OS" == Linux && -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
      docker_args+=(-v "$SSH_AUTH_SOCK:/ssh-agent" --env SSH_AUTH_SOCK=/ssh-agent)
    fi
  fi
else
  # Safe mode never forwards provider root keys or long-lived GitHub tokens.
  if (( with_ssh )) && [[ -d "$HOME/.ssh" ]]; then
    ssh_dir="$(cd "$HOME/.ssh" && pwd -P)"
    docker_args+=(-v "$ssh_dir:/home/agent/.ssh:ro")
    if [[ "$HOST_OS" == Linux && -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
      docker_args+=(-v "$SSH_AUTH_SOCK:/ssh-agent" --env SSH_AUTH_SOCK=/ssh-agent)
    fi
  fi
fi

# gh config: only when explicitly requested (or in unsafe mode).
GH_CONFIG_DIR="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
if (( with_gh || unsafe )) && [[ -d "$GH_CONFIG_DIR" ]]; then
  GH_CONFIG_DIR="$(cd "$GH_CONFIG_DIR" && pwd -P)"
  docker_args+=(
    -v "$GH_CONFIG_DIR:/home/agent/.config/gh:ro"
    --env GH_CONFIG_DIR=/home/agent/.config/gh
  )
fi

if (( unsafe )); then
  # Docker Desktop resolves host.docker.internal itself; plain Linux needs it
  # wired to the default bridge gateway.
  if [[ "$HOST_OS" == Linux ]]; then
    docker_args+=(--add-host=host.docker.internal:host-gateway)
  fi
  if [[ -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]] || [[ -d "$GH_CONFIG_DIR" ]]; then
    add_git_config "credential.https://github.com.helper" "!gh auth git-credential"
  fi
else
  # ---- fail-closed stack checks -------------------------------------------
  if ! docker network inspect opencode-agent >/dev/null 2>&1; then
    cat >&2 <<EOF
error: the opencode-agent network does not exist; refusing to start in safe mode.

Start the stack:
  docker compose -f "$SCRIPT_DIR/stack/docker-compose.yml" up -d

Then approve a lease:
  "$SCRIPT_DIR/bin/lease" approve --session "\${USER:-agent}" --service all \\
      --repo OWNER/REPO --model claude-sonnet --ttl 8h

Use --unsafe only for a trusted debugging session.
EOF
    exit 1
  fi
  for container in opencode-squid opencode-broker opencode-litellm; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    if [[ "$status" != "healthy" && "$status" != "running" ]]; then
      echo "error: required stack service '$container' is not healthy (status: ${status:-missing})." >&2
      echo "       Refusing to start without egress control. Fix the stack or use --unsafe." >&2
      exit 1
    fi
  done

  # ---- lease and virtual key ----------------------------------------------
  if [[ -z "${LEASE_TOKEN:-}" && -f "$LEASE_TOKEN_FILE" ]]; then
    LEASE_TOKEN="$(tr -d '\r\n' < "$LEASE_TOKEN_FILE")"
  fi
  if [[ -z "${LEASE_TOKEN:-}" ]]; then
    cat >&2 <<EOF
error: no lease token. Safe mode needs an approved, scoped lease.

Approve one on the host:
  "$SCRIPT_DIR/bin/lease" approve --session "\${USER:-agent}" --service all \\
      --repo OWNER/REPO --model claude-sonnet --ttl 8h

The token is written to: $LEASE_TOKEN_FILE
EOF
    exit 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required in safe mode to resolve the lease credentials." >&2
    exit 1
  }

  # Fetch the virtual key through the running broker container. The broker is
  # on the internal network, so the host cannot resolve `broker` itself, and we
  # deliberately do not publish the agent-facing listener on the host.
  litellm_response="$(docker exec \
    --env "LEASE_TOKEN=$LEASE_TOKEN" \
    opencode-broker python -c '
import json, os, urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:8080/v1/token/litellm",
    headers={"Authorization": "Bearer " + os.environ["LEASE_TOKEN"]},
)
with urllib.request.urlopen(request, timeout=10) as response:
    print(response.read().decode())
' 2>/dev/null || true)"
  LITELLM_API_KEY="$(jq -r '.key // empty' <<<"$litellm_response" 2>/dev/null || true)"
  if [[ -z "$LITELLM_API_KEY" ]]; then
    echo "error: the lease did not yield a LiteLLM virtual key." >&2
    echo "       Check 'lease self' and 'lease list', or approve a lease with --service all." >&2
    exit 1
  fi
  LITELLM_BASE_URL="$(jq -r '.base_url // "http://litellm:4000/v1"' <<<"$litellm_response")"

  # ---- hardened runtime ----------------------------------------------------
  docker_args+=(
    --network opencode-agent
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --pids-limit="${OPENCODE_PIDS_LIMIT:-2048}"
    --memory="${OPENCODE_MEMORY:-8g}"
    --cpus="${OPENCODE_CPUS:-4}"
    --ulimit nofile=1024:4096
    --env HTTP_PROXY="$PROXY_URL"
    --env HTTPS_PROXY="$PROXY_URL"
    --env http_proxy="$PROXY_URL"
    --env https_proxy="$PROXY_URL"
    --env NO_PROXY="$NO_PROXY_VALUE"
    --env no_proxy="$NO_PROXY_VALUE"
    --env BROKER_URL="$BROKER_URL_IN_CONTAINER"
    --env LEASE_TOKEN="$LEASE_TOKEN"
    --env LITELLM_API_KEY="$LITELLM_API_KEY"
    --env LITELLM_BASE_URL="$LITELLM_BASE_URL"
    --env EXCALIDRAW_RENDER_URL="http://excalidraw:8080"
    --env OPENCODE_WORKSPACE="$REPO_ROOT"
    --env OPENCODE_AUDIT_LOG=/var/log/opencode/audit.jsonl
    --env GIT_TERMINAL_PROMPT=0
  )
  add_git_config "credential.https://github.com.helper" "!git-credential-lease"

  if (( read_only )); then
    docker_args+=(
      --read-only
      --tmpfs /tmp:rw,noexec,nosuid,size=1g
      --tmpfs /run:rw,noexec,nosuid,size=64m
      -v "opencode-home-local:/home/agent/.local"
      -v "opencode-home-npm:/home/agent/.npm"
      -v "opencode-cache:/home/agent/.cache/opencode"
      -v "opencode-state:/home/agent/.local/state/opencode"
      -v "opencode-data:/home/agent/.local/share/opencode"
      -v "opencode-audit:/var/log/opencode"
    )
  fi
fi

# Export the git config count last, after every add_git_config call.
docker_args+=(--env "GIT_CONFIG_COUNT=$git_config_count")

if [[ -n "${OPENCODE_ENV_PASSTHROUGH:-}" ]]; then
  read -r -a passthrough <<< "${OPENCODE_ENV_PASSTHROUGH//,/ }"
  for name in "${passthrough[@]}"; do
    if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      pass_env "$name"
    else
      echo "warning: ignoring invalid OPENCODE_ENV_PASSTHROUGH name: $name" >&2
    fi
  done
fi

if (( shell_mode )); then
  exec docker "${docker_args[@]}" --entrypoint bash "$IMAGE" "$@"
else
  exec docker "${docker_args[@]}" "$IMAGE" "$@"
fi
