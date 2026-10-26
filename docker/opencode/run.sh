#!/usr/bin/env bash
# Run an OpenCode v2 session in the opencode-dev image.
#
#   ./run.sh                     # OpenCode TUI in the current repo
#   ./run.sh --shell             # bash in the same container setup
#   ./run.sh run "explain this"  # any non-TUI OpenCode command
#
# Env: IMAGE, REPO_ROOT, CLAUDE_CONFIG_DIR, XDG_*_HOME,
#      OPENCODE_ENV_PASSTHROUGH="FOO BAR",
#      OPENCODE_DOCKER_ARGS="--network=host"  # extra `docker run` flags
set -euo pipefail

IMAGE="${IMAGE:-opencode-dev:local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOST_OS="$(uname -s)"

shell_mode=0
if [[ "${1:-}" == "--shell" || "${1:-}" == "shell" ]]; then
  shell_mode=1
  shift
fi

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

# Canonicalize so relative values and symlinked config dirs mount the real path.
CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd -P)"
CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd -P)"
DATA_DIR="$(cd "$DATA_DIR" && pwd -P)"
STATE_DIR="$(cd "$STATE_DIR" && pwd -P)"
CACHE_DIR="$(cd "$CACHE_DIR" && pwd -P)"

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
      # Bare specifiers are container-local packages; only paths are mounted.
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
# one value). Used by ~/bin/ollama-opencode to add --network=host.
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

# Docker Desktop resolves host.docker.internal itself; plain Linux needs it
# wired to the default bridge gateway.
if [[ "$HOST_OS" == Linux ]]; then
  docker_args+=(--add-host=host.docker.internal:host-gateway)
fi

# Repo at the same absolute path, so paths in prompts, configs and logs match.
# It also keeps ~/.claude symlinks into this repo resolving, since deploy.sh
# links them by absolute path.
docker_args+=(-v "$REPO_ROOT:$REPO_ROOT" --workdir "$REPO_ROOT")

# Linked worktrees keep their git dir under the main repo's .git/worktrees/<name>,
# outside the worktree root. Mount the common dir at the same path so git works
# inside the container. Skip it when the common dir is already covered by the
# repo mount.
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
fi

# A linked worktree commonly has ~/.claude symlinks into the main checkout
# (deploy.sh links by absolute path). Mount the main working tree read-only so
# those resolve, without letting a worktree session write to the main checkout.
# The nested .git mount above remains read-write inside this read-only tree.
if [[ -n "${git_common:-}" && -d "$git_common" ]]; then
  main_tree="$(cd "$(dirname "$git_common")" && pwd -P)"
  main_toplevel="$(git -C "$main_tree" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "$main_toplevel" == "$main_tree" \
     && "$main_tree" != "$REPO_ROOT" \
     && "$main_tree" != "$REPO_ROOT"/* ]]; then
    docker_args+=(-v "$main_tree:$main_tree:ro")
  fi
fi

# Claude-compatible skills live in ~/.claude and, for OpenCode, ~/.agents.
docker_args+=(
  -v "$CLAUDE_DIR:/home/agent/.claude"
  --env CLAUDE_CONFIG_DIR=/home/agent/.claude
  -v "$CONFIG_DIR:/home/agent/.config/opencode"
  -v "$DATA_DIR:/home/agent/.local/share/opencode"
  -v "$STATE_DIR:/home/agent/.local/state/opencode"
  -v "$CACHE_DIR:/home/agent/.cache/opencode"
)

# Let OpenCode use its default container config dir: do not forward a host
# OPENCODE_CONFIG_DIR value.

if [[ -d "$HOME/.agents" ]]; then
  docker_args+=(-v "$HOME/.agents:/home/agent/.agents")
fi

# GitHub CLI config, so `gh auth status`, `gh pr`, `gh api`, ... use the host
# login. gh keeps the OAuth token in hosts.yml when the host does not use a
# system keyring, so mounting the directory is enough; no token env var (and
# nothing secret in `docker inspect`). Read-only: every read/API command works,
# but mutating ones (`gh auth switch`, `gh auth refresh`, `gh config set`) must
# be run on the host. A host that stores the token in a keyring instead needs
# GITHUB_TOKEN/GH_TOKEN exported (see the credential-helper block below).
GH_CONFIG_DIR="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
gh_config_mounted=0
if [[ -d "$GH_CONFIG_DIR" ]]; then
  GH_CONFIG_DIR="$(cd "$GH_CONFIG_DIR" && pwd -P)"
  docker_args+=(
    -v "$GH_CONFIG_DIR:/home/agent/.config/gh:ro"
    --env GH_CONFIG_DIR=/home/agent/.config/gh
  )
  gh_config_mounted=1
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

# API keys and tokens: forward only the ones set on the host. `--env NAME`
# copies the value from this process's environment, so the secret does not
# appear on the command line.
pass_env() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    docker_args+=(--env "$name")
  fi
}

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

# HTTPS GitHub remotes: use `gh` as the credential helper so a host `gh auth
# login` (mounted config) or a forwarded GITHUB_TOKEN/GH_TOKEN authenticates
# fetch/push without logging in again inside the container. Injected as
# command-scope git config (GIT_CONFIG_*) because the bind-mounted ~/.gitconfig
# is read-only, and because any credential helper named there (osxkeychain,
# libsecret, ...) does not exist in the image.
if (( gh_config_mounted )) || [[ -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]; then
  docker_args+=(
    --env GIT_CONFIG_COUNT=1
    --env GIT_CONFIG_KEY_0=credential.https://github.com.helper
    --env "GIT_CONFIG_VALUE_0=!gh auth git-credential"
  )
fi

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

# SSH keys and config, read-only. Mounted at the container HOME so the
# `IdentityFile ~/.ssh/...` paths in ~/.ssh/config, and git's default key
# lookup, resolve. This makes git-over-SSH work even when no agent is running
# on the host. Read-only means a host that is not already in known_hosts must
# be trusted on the host first (`ssh-keyscan HOST >> ~/.ssh/known_hosts`).
if [[ -d "$HOME/.ssh" ]]; then
  ssh_dir="$(cd "$HOME/.ssh" && pwd -P)"
  docker_args+=(-v "$ssh_dir:/home/agent/.ssh:ro")
fi

# Forward the SSH agent when there is one. Linux only: on macOS the agent
# socket lives in the host's launchd session and is not shared with Docker
# Desktop's VM without an extra socket forwarder (e.g. ssh-agent over TCP);
# key-file auth via the mount above still works there.
if [[ "$HOST_OS" == Linux && -n "${SSH_AUTH_SOCK:-}" && -S "$SSH_AUTH_SOCK" ]]; then
  docker_args+=(-v "$SSH_AUTH_SOCK:/ssh-agent" --env SSH_AUTH_SOCK=/ssh-agent)
fi

if (( shell_mode )); then
  exec docker "${docker_args[@]}" --entrypoint bash "$IMAGE" "$@"
else
  exec docker "${docker_args[@]}" "$IMAGE" "$@"
fi
