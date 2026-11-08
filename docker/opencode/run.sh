#!/usr/bin/env bash
# Run an OpenCode v2 session in the hardened opencode-dev image.
#
#   ./run.sh                     # OpenCode TUI in a session clone of the repo
#   ./run.sh --shell             # bash in the same container setup
#   ./run.sh run "explain this"  # any non-TUI OpenCode command
#   ./run.sh review [ID]         # fetch a session branch and show what changed
#   ./run.sh sessions            # list sessions of the current repo
#   ./run.sh clean ID            # remove a session
#   ./run.sh --unsafe            # legacy mounts/network for trusted debugging
#   ./run.sh --with-ssh          # mount ~/.ssh and forward the agent
#   ./run.sh --with-gh           # mount ~/.config/gh read-only
#   ./run.sh --read-only         # read-only rootfs with tmpfs and named volumes
#
# Safe mode requires the local stack (Squid, broker, LiteLLM) to be healthy, a
# lease token to exist and a Docker engine that isolates container uids from the
# host user (rootless Docker, userns-remap, or a VM-based engine). It fails
# closed rather than starting an agent with no egress control or credentials.
#
# Env: IMAGE, REPO_ROOT, CLAUDE_CONFIG_DIR, XDG_*_HOME,
#      LEASE_TOKEN, LEASE_TOKEN_FILE, BROKER_URL,
#      OPENCODE_MODEL (default litellm/deepseek-chat),
#      OPENCODE_ENV_PASSTHROUGH="FOO BAR",
#      OPENCODE_DOCKER_ARGS="--env FOO=bar"  # extra `docker run` flags
#      OPENCODE_SESSION_ID                   # reuse a pre-chosen session id
#      OPENCODE_I_ACCEPT_UNSAFE=1            # fence for --unsafe, --allow-rootful
#                                            # and widening OPENCODE_DOCKER_ARGS
set -euo pipefail

IMAGE="${IMAGE:-opencode-dev:local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOST_OS="$(uname -s)"

# Fixed uid/gid of the agent user in the image (see Dockerfile).
AGENT_UID=60917
AGENT_GID=60917

SESSIONS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/sessions"
AUDIT_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/audit.jsonl"

# Paths (relative to the Claude config dir) copied into the staged read-only
# copy. Files and directories are both allowed. Anything else is not copied.
CLAUDE_ALLOW_DIRS=(skills commands hooks agents scripts CLAUDE.md)

# Glob patterns for paths that execute or configure tooling. Patterns without a
# slash also match the file name at any depth.
EXEC_CONFIG_PATTERNS=(
  '.git/hooks/*'
  '.githooks/*'
  '.envrc'
  '.env*'
  'Makefile'
  '*.mk'
  '.github/workflows/*'
  '.claude/*'
  '.opencode/*'
  '.mcp.json'
  'AGENTS.md'
  'CLAUDE.md'
  '.gitmodules'
  '.pre-commit-config.yaml'
)

shell_mode=0
unsafe=0
with_ssh=0
with_gh=0
read_only=0
allow_rootful=0

usage() {
  cat <<'EOF'
Usage: run.sh [options] [opencode arguments]
       run.sh review [SESSION_ID]
       run.sh sessions
       run.sh clean SESSION_ID

Subcommands (no agent container is started):
  review [ID]      fetch the session branch into this repo as
                   refs/opencode/review/ID, show the diff stat, highlight
                   changed executable config and print the merge command
                   (default: newest session of this repo)
  sessions         list the sessions of this repo
  clean ID         delete the review ref and the session directory

Options:
  --shell          open bash in the same container setup
  --unsafe         legacy behaviour: host gateway, SSH/gh mounts, token
                   passthrough, no capability/resource defaults. Needs
                   OPENCODE_I_ACCEPT_UNSAFE=1, a terminal, and typing 'unsafe'
  --allow-rootful  skip the rootless-Docker check (debugging only). Needs
                   OPENCODE_I_ACCEPT_UNSAFE=1
  --with-ssh       mount ~/.ssh read-only and forward SSH_AUTH_SOCK on Linux
  --with-gh        mount ~/.config/gh read-only
  --read-only      run the agent root filesystem read-only
  -h, --help       show this help

Safe mode (the default) attaches the container to the internal
`opencode-agent` network only, drops capabilities, applies resource limits and
requires a healthy proxy/broker/LiteLLM stack, a lease token and rootless
Docker (or userns-remap, or a VM-based engine). The agent works in a per-session
clone, not in your working tree.

Environment:
  IMAGE, REPO_ROOT, CLAUDE_CONFIG_DIR, XDG_*_HOME,
  LEASE_TOKEN, LEASE_TOKEN_FILE, BROKER_URL,
  OPENCODE_MODEL, OPENCODE_ENV_PASSTHROUGH, OPENCODE_DOCKER_ARGS,
  OPENCODE_SESSION_ID, OPENCODE_I_ACCEPT_UNSAFE

OPENCODE_DOCKER_ARGS may not contain flags that widen isolation (--privileged,
--network, --net, --pid, --ipc, --uts, --userns, --cgroupns, --cap-add,
--security-opt, --device, -u/--user, -v/--volume, --mount, --volumes-from)
unless OPENCODE_I_ACCEPT_UNSAFE=1 is set.
EOF
}

# ---- structured audit log -----------------------------------------------------
# log_event <event> <outcome> [lease_id] [repo] [detail_json]
# Appends one JSON line to $AUDIT_LOG (mode 0600). Never fails the caller and
# never records secret values.
log_event() {
  local event="$1" outcome="$2" lease_id="${3:-}" repo="${4:-}" detail="${5:-}"
  local ts line
  command -v jq >/dev/null 2>&1 || return 0
  [[ -n "$detail" ]] || detail='{}'
  jq -e 'type == "object"' <<<"$detail" >/dev/null 2>&1 || detail='{}'
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  if [[ "$ts" == *N* ]]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  fi
  line="$(jq -nc \
    --arg ts "$ts" --arg event "$event" --arg outcome "$outcome" \
    --arg lease_id "$lease_id" --arg repo "$repo" --arg detail "$detail" \
    '{ts: $ts,
      component: "run.sh",
      event: $event,
      lease_id: (if $lease_id == "" then null else $lease_id end),
      repo: (if $repo == "" then null else $repo end),
      outcome: $outcome,
      detail: ($detail | fromjson
               | del(.token, .lease_token, .litellm_key, .private_key, .values))}')" || return 0
  (
    umask 077
    mkdir -p "$(dirname "$AUDIT_LOG")"
    printf '%s\n' "$line" >> "$AUDIT_LOG"
  ) 2>/dev/null || true
}

# ---- repo and session helpers ---------------------------------------------------
resolve_repo_root() {
  # Repo to expose. Default to the git root of the caller's directory, so
  # running from a subdirectory uses the whole repo; fall back to $PWD outside
  # git.
  if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
  fi
  if [[ ! -d "$REPO_ROOT" ]]; then
    echo "error: REPO_ROOT does not exist: $REPO_ROOT" >&2
    exit 1
  fi
  REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
}

# Sets git_common to the absolute git common dir of REPO_ROOT, or "".
resolve_git_common() {
  local common
  git_common=""
  if common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"; then
    [[ "$common" == /* ]] || common="$REPO_ROOT/$common"
    if [[ -d "$common" ]]; then
      git_common="$(cd "$common" && pwd -P)"
    fi
  fi
}

new_session_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%S)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
}

valid_session_id() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}-[0-9a-f]{6}$ ]]
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required." >&2
    exit 1
  }
}

# Print the newest session id whose session.json repo_root equals REPO_ROOT.
newest_session() {
  local meta dir id newest=""
  for meta in "$SESSIONS_DIR"/*/session.json; do
    [[ -f "$meta" ]] || continue
    [[ "$(jq -r '.repo_root // empty' "$meta" 2>/dev/null)" == "$REPO_ROOT" ]] || continue
    dir="$(dirname "$meta")"
    id="$(basename "$dir")"
    valid_session_id "$id" || continue
    # Ids start with a UTC timestamp, so lexical order is chronological.
    if [[ -z "$newest" || "$id" > "$newest" ]]; then
      newest="$id"
    fi
  done
  printf '%s' "$newest"
}

# Succeeds when <path> matches EXEC_CONFIG_PATTERNS.
is_exec_config() {
  local path="$1" pattern
  for pattern in "${EXEC_CONFIG_PATTERNS[@]}"; do
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$path" == $pattern ]] && return 0
    if [[ "$pattern" != */* ]]; then
      # shellcheck disable=SC2053
      [[ "${path##*/}" == $pattern ]] && return 0
    fi
  done
  return 1
}

# review [SESSION_ID]. No git command here uses the session clone as its working
# directory or -C target, so the clone's config and hooks are never read by a
# host git process. The clone is only the source argument of `git fetch`.
cmd_review() {
  local id="${1:-}" dir meta work base_sha branch ref path flagged=0
  local base_scripts head_scripts red="" bold="" reset=""
  local flagged_paths=()
  require_jq
  resolve_repo_root
  [[ -n "$id" ]] || id="$(newest_session)"
  if [[ -z "$id" ]]; then
    echo "error: no session found for $REPO_ROOT (see: run.sh sessions)" >&2
    exit 1
  fi
  valid_session_id "$id" || { echo "error: invalid session id: $id" >&2; exit 1; }
  dir="$SESSIONS_DIR/$id"
  meta="$dir/session.json"
  [[ -f "$meta" ]] || { echo "error: no such session: $id" >&2; exit 1; }
  if [[ "$(jq -r '.repo_root' "$meta")" != "$REPO_ROOT" ]]; then
    echo "error: session $id belongs to $(jq -r '.repo_root' "$meta"), not $REPO_ROOT" >&2
    exit 1
  fi
  work="$dir/work"
  base_sha="$(jq -r '.base_sha' "$meta")"
  branch="$(jq -r '.branch' "$meta")"
  ref="refs/opencode/review/$id"

  git -C "$REPO_ROOT" fetch --quiet --no-tags --no-write-fetch-head \
    "$work" "+refs/heads/$branch:$ref"

  echo "Session $id ($branch) against $base_sha"
  git -C "$REPO_ROOT" diff --no-ext-diff --no-textconv --stat "$base_sha...$ref"

  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    red=$'\033[31m'
    bold=$'\033[1m'
    reset=$'\033[0m'
  fi
  while IFS= read -r -d '' path; do
    if [[ "${path##*/}" == package.json ]]; then
      base_scripts="$(git -C "$REPO_ROOT" show "$base_sha:$path" 2>/dev/null | jq -S .scripts 2>/dev/null || true)"
      head_scripts="$(git -C "$REPO_ROOT" show "$ref:$path" 2>/dev/null | jq -S .scripts 2>/dev/null || true)"
      if [[ "$base_scripts" != "$head_scripts" ]]; then
        flagged_paths+=("$path")
      fi
    elif is_exec_config "$path"; then
      flagged_paths+=("$path")
    fi
  done < <(git -C "$REPO_ROOT" diff --no-ext-diff --no-textconv --name-only -z "$base_sha...$ref")
  flagged=${#flagged_paths[@]}

  if (( flagged > 0 )); then
    printf '\n%s%sexecutable config changed:%s\n' "$bold" "$red" "$reset"
    for path in "${flagged_paths[@]}"; do
      printf '  %s%s%s%s\n' "$bold" "$red" "$path" "$reset"
    done
  fi

  printf '\nMerge command (run in %s):\n  git merge --no-ff %s\n' "$REPO_ROOT" "$ref"
  log_event session.review ok "" "$REPO_ROOT" \
    "$(jq -nc --arg session_id "$id" --argjson flagged "$flagged" \
        '{session_id: $session_id, flagged: $flagged}')"
}

cmd_sessions() {
  local meta rows=""
  require_jq
  resolve_repo_root
  for meta in "$SESSIONS_DIR"/*/session.json; do
    [[ -f "$meta" ]] || continue
    [[ "$(jq -r '.repo_root // empty' "$meta" 2>/dev/null)" == "$REPO_ROOT" ]] || continue
    rows+="$(jq -r '[.session_id, .branch, .base_ref, (.base_sha[:7]), .created_at] | @tsv' "$meta")"$'\n'
  done
  rows="$(printf 'ID\tBRANCH\tBASE_REF\tBASE_SHA\tCREATED_AT\n%s' "$rows" | sed '/^$/d')"
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' <<<"$rows"
  else
    printf '%s\n' "$rows"
  fi
}

# clean <session-id>. The agent uid owns the files it wrote, so the host user
# cannot delete them. A one-shot container as the agent uid removes work/.
cmd_clean() {
  local id="${1:-}" dir
  require_jq
  resolve_repo_root
  [[ -n "$id" ]] || { echo "usage: run.sh clean SESSION_ID" >&2; exit 2; }
  valid_session_id "$id" || { echo "error: invalid session id: $id" >&2; exit 1; }
  dir="$SESSIONS_DIR/$id"
  [[ -d "$dir" ]] || { echo "error: no such session: $id" >&2; exit 1; }
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "error: image '$IMAGE' not found; it is needed to remove agent-owned files." >&2
    exit 1
  fi
  git -C "$REPO_ROOT" update-ref -d "refs/opencode/review/$id" 2>/dev/null || true
  # The host user owns these two directories; open them so the agent uid can
  # delete the entries it created.
  chmod 0777 "$dir"
  [[ ! -d "$dir/work" ]] || chmod 0777 "$dir/work"
  docker run --rm \
    --user "$AGENT_UID:$AGENT_GID" --network none --cap-drop=ALL \
    --security-opt=no-new-privileges \
    -v "$dir:/session" \
    --entrypoint rm "$IMAGE" -rf /session/work
  rm -rf "$dir"
  log_event session.clean ok "" "$REPO_ROOT" \
    "$(jq -nc --arg session_id "$id" '{session_id: $session_id}')"
  echo "removed session $id"
}

# ---- subcommand dispatch ----------------------------------------------------------
case "${1:-}" in
  review|sessions|clean)
    subcommand="$1"
    shift
    "cmd_$subcommand" "$@"
    exit 0
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell|shell) shell_mode=1; shift ;;
    --unsafe) unsafe=1; shift ;;
    --allow-rootful) allow_rootful=1; shift ;;
    --with-ssh) with_ssh=1; shift ;;
    --with-gh) with_gh=1; shift ;;
    --read-only) read_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) break ;;
    *) break ;;
  esac
done

resolve_repo_root

# Session id: also the lease --session name. Export it so approve_lease callers
# (stack/online.sh, stack/llama.sh) and the container see the same value.
SESSION_ID="${OPENCODE_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="$(new_session_id)"
elif ! valid_session_id "$SESSION_ID"; then
  echo "error: OPENCODE_SESSION_ID must look like 20260101T120000-abc123: $SESSION_ID" >&2
  exit 1
fi
export OPENCODE_SESSION_ID="$SESSION_ID"

warn_unsafe() {
  cat >&2 <<'EOF'
WARNING: --unsafe restores the legacy trust model:
  - default Docker bridge and host.docker.internal (host services reachable)
  - ~/.ssh read-only and SSH agent forwarding (when available)
  - ~/.config/gh read-only
  - provider API keys and GITHUB_TOKEN/GH_TOKEN from the host environment
  - the host repository and ~/.claude mounted read-write
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

# --unsafe needs OPENCODE_I_ACCEPT_UNSAFE=1, a terminal on stdin and stderr, and
# the typed word `unsafe`. There is no non-interactive bypass.
confirm_unsafe() {
  local reason="" answer=""
  if [[ "${OPENCODE_I_ACCEPT_UNSAFE:-}" != 1 ]]; then
    reason="OPENCODE_I_ACCEPT_UNSAFE=1 is not set"
  elif ! [[ -t 0 && -t 2 ]]; then
    reason="stdin and stderr must be terminals"
  else
    printf "Type 'unsafe' to continue: " >&2
    read -r answer || true
    [[ "$answer" == unsafe ]] || reason="confirmation text was not 'unsafe'"
  fi
  if [[ -n "$reason" ]]; then
    echo "error: --unsafe refused: $reason." >&2
    log_event unsafe.refused deny "" "$REPO_ROOT" \
      "$(jq -nc --arg reason "$reason" '{reason: $reason}' 2>/dev/null || true)"
    exit 2
  fi
  log_event unsafe.start warn "" "$REPO_ROOT" \
    '{"exposures": ["host_gateway", "ssh_dir", "gh_config", "provider_env_keys", "host_repo_rw", "claude_dir_rw", "no_cap_drop", "no_resource_limits"]}'
}

# Rejects `docker run` flags that widen isolation. Arguments are the words of
# OPENCODE_DOCKER_ARGS. Prints the first offending word and returns 1.
validate_docker_args() {
  local word flag
  local long_flags=(--privileged --network --net --pid --ipc --uts --userns
    --cgroupns --cap-add --security-opt --device --user --volume --mount
    --volumes-from)
  for word in "$@"; do
    for flag in "${long_flags[@]}"; do
      if [[ "$word" == "$flag" || "$word" == "$flag="* ]]; then
        printf '%s' "$word"
        return 1
      fi
    done
    # Short forms: -u, -uVALUE, -v, -vVALUE and bundles such as -itv.
    if [[ "$word" =~ ^-[dit]*[uv] ]]; then
      printf '%s' "$word"
      return 1
    fi
  done
  return 0
}

(( with_ssh )) && warn_with_ssh
(( with_gh )) && warn_with_gh

if (( allow_rootful )); then
  if [[ "${OPENCODE_I_ACCEPT_UNSAFE:-}" != 1 ]]; then
    echo "error: --allow-rootful requires OPENCODE_I_ACCEPT_UNSAFE=1." >&2
    exit 2
  fi
  echo "WARNING: --allow-rootful skips the rootless Docker check. A container escape" >&2
  echo "         would run as the daemon user (root on a rootful daemon)." >&2
  log_event launcher.rootful_override warn "" "$REPO_ROOT"
fi

if (( unsafe )); then
  warn_unsafe
  confirm_unsafe
fi

# Extra `docker run` flags, word-split deliberately (it is a list of flags, not
# one value). Validated before any container starts.
extra_docker_args=()
if [[ -n "${OPENCODE_DOCKER_ARGS:-}" ]]; then
  read -r -a extra_docker_args <<< "${OPENCODE_DOCKER_ARGS}"
  if ! rejected="$(validate_docker_args "${extra_docker_args[@]}")"; then
    if [[ "${OPENCODE_I_ACCEPT_UNSAFE:-}" == 1 ]]; then
      echo "WARNING: OPENCODE_DOCKER_ARGS contains '$rejected', which widens isolation;" >&2
      echo "         allowed because OPENCODE_I_ACCEPT_UNSAFE=1 is set." >&2
      log_event docker_args.override warn "" "$REPO_ROOT" \
        "$(jq -nc --arg flag "$rejected" '{flag: $flag}' 2>/dev/null || true)"
    else
      echo "error: OPENCODE_DOCKER_ARGS contains '$rejected', which widens isolation." >&2
      echo "       Remove it, or set OPENCODE_I_ACCEPT_UNSAFE=1 to override." >&2
      exit 2
    fi
  fi
fi

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

# The image has a fixed agent uid. If it equals the host uid, the agent would own
# the host user's files; refuse in safe mode.
image_uid="$(docker image inspect --format '{{ index .Config.Labels "dev.opencode.uid" }}' "$IMAGE" 2>/dev/null || true)"
if (( ! unsafe )) && [[ "$image_uid" =~ ^[0-9]+$ && "$image_uid" == "$(id -u)" ]]; then
  echo "error: image '$IMAGE' was built for UID $image_uid, which is the host user's UID." >&2
  echo "       Rebuild with: make -C \"$SCRIPT_DIR\" build" >&2
  exit 1
fi

# ---- container engine isolation -------------------------------------------------
docker_security_options() {
  docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true
}

docker_is_rootless() {
  [[ "$(docker_security_options)" == *name=rootless* ]]
}

# Safe mode needs an engine where container uids do not map to host user files:
# macOS (always a VM), Docker Desktop, rootless Docker, or userns-remap.
check_isolation_backend() {
  local os options
  [[ "$HOST_OS" == Darwin ]] && return 0
  os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  [[ "$os" == *"Docker Desktop"* ]] && return 0
  options="$(docker_security_options)"
  [[ "$options" == *name=rootless* || "$options" == *name=userns* ]] && return 0
  cat >&2 <<EOF
error: the Docker engine is rootful; refusing to start in safe mode.

Safe mode needs rootless Docker (or userns-remap, or a VM-based engine such as
Docker Desktop) so a container escape does not run as root on the host.

Set up rootless Docker on Linux:
  1. Install docker-ce-rootless-extras and uidmap.
  2. Give your user at least 65536 subordinate ids:
       echo "\$USER:100000:65536" | sudo tee -a /etc/subuid /etc/subgid
  3. dockerd-rootless-setuptool.sh install
  4. export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/docker.sock
  5. systemctl --user enable --now docker
  6. Recreate the stack and volumes on the rootless daemon.

For debugging only: OPENCODE_I_ACCEPT_UNSAFE=1 run.sh --allow-rootful
EOF
  exit 1
}

# Named volumes created by an older image (other uid) are not writable by the
# agent. Report them with the command that removes them.
check_volume_ownership() {
  local volume
  for volume in opencode-data opencode-state opencode-cache opencode-audit; do
    docker volume inspect "$volume" >/dev/null 2>&1 || continue
    if ! docker run --rm --network none --cap-drop=ALL --security-opt=no-new-privileges \
        -v "$volume:/v" --entrypoint test "$IMAGE" -w /v >/dev/null 2>&1; then
      echo "error: volume '$volume' is not writable by the agent uid $AGENT_UID" >&2
      echo "       (it was probably created by an image with another uid). Remove it:" >&2
      echo "         docker volume rm $volume" >&2
      exit 1
    fi
  done
}

# Read-only mounts are read by a uid that owns none of the files, so everything
# must be readable by "other": directories o+rx, files o+r.
check_other_readable() {
  local path="$1" bad
  bad="$(find "$path" -type d ! -perm -o+rx -print -quit 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then
    echo "error: $bad is not readable by other users (directories need o+rx)." >&2
    echo "       The agent uid owns no host files. Fix with: chmod o+rx '$bad'" >&2
    return 1
  fi
  bad="$(find "$path" -type f ! -perm -o+r -print -quit 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then
    echo "error: $bad is not readable by other users (files need o+r)." >&2
    echo "       The agent uid owns no host files. Fix with: chmod o+r '$bad'" >&2
    return 1
  fi
  return 0
}

# ---- session workspace ----------------------------------------------------------
# Sets SESSION_DIR, WORK_DIR, BASE_SHA and BASE_REF. The agent works in a clone
# that shares the host object store through git alternates. Uncommitted changes
# in the host working tree are not carried over.
create_session_workspace() {
  local origin_url="" meta_time
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: $REPO_ROOT is not a git repository; safe mode needs one for the session clone." >&2
    exit 1
  fi
  BASE_SHA="$(git -C "$REPO_ROOT" rev-parse --verify -q HEAD || true)"
  if [[ -z "$BASE_SHA" ]]; then
    echo "error: $REPO_ROOT has no commits; the session branch needs a base commit." >&2
    exit 1
  fi
  BASE_REF="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || true)"
  [[ -n "$BASE_REF" ]] || BASE_REF="HEAD"

  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
    echo "warning: uncommitted changes in $REPO_ROOT are not in the session clone." >&2
  fi

  mkdir -p "$SESSIONS_DIR"
  SESSIONS_DIR="$(cd "$SESSIONS_DIR" && pwd -P)"
  SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"
  WORK_DIR="$SESSION_DIR/work"
  mkdir -m 0700 "$SESSION_DIR"
  mkdir -m 0777 "$WORK_DIR"

  origin_url="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
  if [[ "$origin_url" == https://* ]]; then
    origin_url="$(sed -E 's#^(https://)[^/@]*@#\1#' <<<"$origin_url")"
  else
    origin_url=""
  fi

  # Clone from the common dir (the only host git path mounted, read-only). With
  # --shared the clone records the common dir's objects/ as an alternate.
  docker run --rm \
    --user "$AGENT_UID:$AGENT_GID" --network none --cap-drop=ALL \
    --security-opt=no-new-privileges --env HOME=/tmp \
    -v "$git_common:$git_common:ro" \
    -v "$WORK_DIR:$WORK_DIR" \
    --entrypoint bash "$IMAGE" -ec '
      common=$1 work=$2 branch=$3 sha=$4 url=$5
      git config --global --add safe.directory "*"
      git clone --quiet --shared --no-checkout "$common" "$work"
      git -C "$work" update-ref "refs/heads/$branch" "$sha"
      git -C "$work" symbolic-ref HEAD "refs/heads/$branch"
      git -C "$work" reset --quiet --hard
      if [ -n "$url" ]; then
        git -C "$work" remote set-url origin "$url"
      else
        git -C "$work" remote remove origin
      fi
    ' bash "$git_common" "$WORK_DIR" "opencode/$SESSION_ID" "$BASE_SHA" "$origin_url"

  # work/ stays mode 0777: the agent uid (which owns nothing else on the host)
  # must create top-level entries in it. The session directory above it is 0700,
  # so no other host user can reach it.

  meta_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg session_id "$SESSION_ID" --arg repo_root "$REPO_ROOT" \
    --arg git_common_dir "$git_common" --arg base_ref "$BASE_REF" \
    --arg base_sha "$BASE_SHA" --arg branch "opencode/$SESSION_ID" \
    --arg created_at "$meta_time" \
    '{session_id: $session_id, repo_root: $repo_root, git_common_dir: $git_common_dir,
      base_ref: $base_ref, base_sha: $base_sha, branch: $branch, created_at: $created_at}' \
    > "$SESSION_DIR/session.json"
}

# ---- host config/state dirs -------------------------------------------------------
# Create them as the host user first so Docker does not create them as root on
# first mount.
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

# Build the staged, read-only copy of the Claude config dir at <dest>. Only the
# CLAUDE_ALLOW_DIRS entries are copied (symlinks dereferenced). settings.json is
# rewritten to keep only hooks, permissions and model, plus env entries whose
# names do not look like credentials.
stage_claude_dir() {
  local dest="$1" entry
  mkdir -p "$dest"
  chmod 0755 "$dest"
  for entry in "${CLAUDE_ALLOW_DIRS[@]}"; do
    [[ -e "$CLAUDE_DIR/$entry" ]] || continue
    (
      umask 022
      cp -RL --no-preserve=ownership "$CLAUDE_DIR/$entry" "$dest/$entry" 2>/dev/null \
        || cp -RL "$CLAUDE_DIR/$entry" "$dest/$entry"
    ) || echo "warning: could not fully copy $CLAUDE_DIR/$entry into the staged Claude dir" >&2
  done
  if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
    if ! jq '{hooks, permissions, model}
             + {env: ((.env // {}) | with_entries(select(.key | test("TOKEN|KEY|SECRET|PASSWORD|CREDENTIAL|AUTH|COOKIE"; "i") | not)))}
             | with_entries(select(.value != null))' \
        "$CLAUDE_DIR/settings.json" > "$dest/settings.json" 2>/dev/null; then
      echo "warning: could not filter $CLAUDE_DIR/settings.json; staging an empty settings.json" >&2
      printf '{}\n' > "$dest/settings.json"
    fi
  else
    printf '{}\n' > "$dest/settings.json"
  fi
  chmod 0644 "$dest/settings.json"
}

LEASE_TOKEN_FILE="${LEASE_TOKEN_FILE:-$STATE_DIR/lease-token}"
BROKER_URL_IN_CONTAINER="${BROKER_URL:-http://broker:8080}"
PROXY_URL="http://squid:3128"
NO_PROXY_VALUE="litellm,broker,squid,excalidraw,localhost,127.0.0.1,::1"

# GET a broker agent-API path through the running broker container. The broker
# is on the internal network, so the host cannot resolve `broker` itself, and
# the agent-facing listener is deliberately not published on the host.
broker_get() {
  docker exec \
    --env "LEASE_TOKEN=$LEASE_TOKEN" \
    opencode-broker python -c '
import json, os, sys, urllib.request
request = urllib.request.Request(
    "http://127.0.0.1:8080" + sys.argv[1],
    headers={"Authorization": "Bearer " + os.environ["LEASE_TOKEN"]},
)
with urllib.request.urlopen(request, timeout=10) as response:
    print(response.read().decode())
' "$1" 2>/dev/null || true
}

# Safe mode: fail-closed stack checks, lease and virtual key. Sets LEASE_TOKEN,
# LEASE_ID, LITELLM_API_KEY and LITELLM_BASE_URL.
safe_preflight() {
  local container status lease_response litellm_response
  if ! docker network inspect opencode-agent >/dev/null 2>&1; then
    cat >&2 <<EOF
error: the opencode-agent network does not exist; refusing to start in safe mode.

Start the stack:
  docker compose -f "$SCRIPT_DIR/stack/docker-compose.yml" up -d

Then approve a lease for this session and run again with the same session id:
  "$SCRIPT_DIR/bin/lease" approve --session "$SESSION_ID" --service all \\
      --repo OWNER/REPO --model claude-sonnet --ttl 8h
  OPENCODE_SESSION_ID=$SESSION_ID run.sh

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

  if [[ -z "${LEASE_TOKEN:-}" && -f "$LEASE_TOKEN_FILE" ]]; then
    LEASE_TOKEN="$(tr -d '\r\n' < "$LEASE_TOKEN_FILE")"
  fi
  if [[ -z "${LEASE_TOKEN:-}" ]]; then
    cat >&2 <<EOF
error: no lease token. Safe mode needs an approved, scoped lease.

Approve one on the host, then run again with the same session id:
  "$SCRIPT_DIR/bin/lease" approve --session "$SESSION_ID" --service all \\
      --repo OWNER/REPO --model claude-sonnet --ttl 8h
  OPENCODE_SESSION_ID=$SESSION_ID run.sh

The token is written to: $LEASE_TOKEN_FILE
EOF
    exit 1
  fi

  lease_response="$(broker_get /v1/leases/self)"
  LEASE_ID="$(jq -r '.lease_id // empty' <<<"$lease_response" 2>/dev/null || true)"

  litellm_response="$(broker_get /v1/token/litellm)"
  LITELLM_API_KEY="$(jq -r '.key // empty' <<<"$litellm_response" 2>/dev/null || true)"
  if [[ -z "$LITELLM_API_KEY" ]]; then
    echo "error: the lease did not yield a LiteLLM virtual key." >&2
    echo "       Check 'lease self' and 'lease list', or approve a lease with --service all." >&2
    exit 1
  fi
  LITELLM_BASE_URL="$(jq -r '.base_url // "http://litellm:4000/v1"' <<<"$litellm_response")"
}

LEASE_ID=""
git_common=""
SESSION_DIR=""
WORK_DIR=""

if (( ! unsafe )); then
  require_jq
  resolve_git_common
  if [[ -z "$git_common" ]]; then
    echo "error: $REPO_ROOT is not a git repository; safe mode needs one for the session clone." >&2
    exit 1
  fi
  (( allow_rootful )) || check_isolation_backend
  check_volume_ownership
  check_other_readable "$git_common/objects" || exit 1
  safe_preflight
  create_session_workspace
  stage_claude_dir "$SESSION_DIR/claude"
  if ! check_other_readable "$SESSION_DIR/claude"; then
    echo "       Session $SESSION_ID was created; remove it with: run.sh clean $SESSION_ID" >&2
    exit 1
  fi
fi

docker_args=(run --rm --init)

# OpenCode v2 registers local TUI/CLI plugins in cli.json by absolute path
# (for example the YAS statusline). They live outside the config dir, so mount
# each one at its host path to keep that absolute entry resolvable. Package
# names from the registry are installed inside the container and need no mount.
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

if (( ${#extra_docker_args[@]} > 0 )); then
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

# Default to an online model so a run needs no local llama.cpp service. The
# system config reads this via {env:OPENCODE_MODEL}; use `/model` to switch to
# litellm/qwen-local after `make llama-up`.
docker_args+=(--env "OPENCODE_MODEL=${OPENCODE_MODEL:-litellm/deepseek-chat}")
docker_args+=(--env "OPENCODE_SESSION_ID=$SESSION_ID")

# Scoped git configuration. The image no longer trusts every path; the launcher
# trusts only the paths it actually exposes.
git_config_count=0
add_git_config() {
  local key="$1" value="$2"
  docker_args+=(--env "GIT_CONFIG_KEY_${git_config_count}=${key}")
  docker_args+=(--env "GIT_CONFIG_VALUE_${git_config_count}=${value}")
  git_config_count=$((git_config_count + 1))
}

if (( unsafe )); then
  # Legacy: repo at the same absolute path, so paths in prompts, configs and
  # logs match and ~/.claude symlinks into this repo resolve.
  docker_args+=(-v "$REPO_ROOT:$REPO_ROOT" --workdir "$REPO_ROOT")

  # Linked worktrees keep their git dir under the main repo's .git/worktrees/<name>,
  # outside the worktree root. Mount the common dir at the same path so git works
  # inside the container, unless the repo mount already covers it.
  resolve_git_common
  if [[ -n "$git_common" && "$git_common" != "$REPO_ROOT" && "$git_common" != "$REPO_ROOT"/* ]]; then
    docker_args+=(-v "$git_common:$git_common")
  fi

  # A linked worktree commonly has ~/.claude symlinks into the main checkout
  # (deploy.sh links by absolute path). Mount the main working tree read-only so
  # those resolve.
  main_toplevel=""
  if [[ -n "$git_common" && -d "$git_common" ]]; then
    main_tree="$(cd "$(dirname "$git_common")" && pwd -P)"
    main_toplevel="$(git -C "$main_tree" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ "$main_toplevel" == "$main_tree" \
       && "$main_tree" != "$REPO_ROOT" \
       && "$main_tree" != "$REPO_ROOT"/* ]]; then
      docker_args+=(-v "$main_tree:$main_tree:ro")
    fi
  fi

  add_git_config "safe.directory" "$REPO_ROOT"
  if [[ -n "$git_common" && "$git_common" != "$REPO_ROOT" ]]; then
    add_git_config "safe.directory" "$git_common"
  fi
  if [[ -n "$main_toplevel" && "$main_toplevel" != "$REPO_ROOT" ]]; then
    add_git_config "safe.directory" "$main_toplevel"
  fi
else
  # Session clone read-write at its own path; only the host object store is
  # mounted, read-only, so the clone's alternates resolve. No host working tree,
  # no host .git/hooks, config or refs.
  docker_args+=(
    -v "$WORK_DIR:$WORK_DIR"
    --workdir "$WORK_DIR"
    -v "$git_common/objects:$git_common/objects:ro"
  )
  add_git_config "safe.directory" "$WORK_DIR"
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
    -v "$SESSION_DIR/claude:/home/agent/.claude:ro"
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
  # Bind mounts are owned by the host user. On a rootless daemon container root
  # is the host user; on a rootful daemon use the host uid/gid directly.
  if docker_is_rootless; then
    docker_args+=(--user 0:0)
  else
    docker_args+=(--user "$(id -u):$(id -g)")
  fi
  # Docker Desktop resolves host.docker.internal itself; plain Linux needs it
  # wired to the default bridge gateway.
  if [[ "$HOST_OS" == Linux ]]; then
    docker_args+=(--add-host=host.docker.internal:host-gateway)
  fi
  if [[ -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]] || [[ -d "$GH_CONFIG_DIR" ]]; then
    add_git_config "credential.https://github.com.helper" "!gh auth git-credential"
  fi
else
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
    --env OPENCODE_CONTAINER=1
    --env OPENCODE_WORKSPACE="$WORK_DIR"
    --env OPENCODE_AUDIT_LOG=/var/log/opencode/audit.jsonl
    --env GIT_TERMINAL_PROMPT=0
  )
  add_git_config "credential.https://github.com.helper" "!git-credential-lease"

  if (( read_only )); then
    # shellcheck disable=SC2054  # commas belong to the tmpfs option string
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

if (( unsafe )); then
  session_mode=unsafe
else
  session_mode=safe
fi
log_event session.start ok "$LEASE_ID" "$REPO_ROOT" \
  "$(jq -nc --arg session_id "$SESSION_ID" --arg lease_id "$LEASE_ID" \
      --arg image "$IMAGE" --arg mode "$session_mode" \
      '{session_id: $session_id, lease_id: $lease_id, image: $image, mode: $mode}' 2>/dev/null || true)"

if (( shell_mode )); then
  exec docker "${docker_args[@]}" --entrypoint bash "$IMAGE" "$@"
else
  exec docker "${docker_args[@]}" "$IMAGE" "$@"
fi
