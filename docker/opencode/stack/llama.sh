#!/usr/bin/env bash
# One-command local-model workflow for the hardened OpenCode stack.
#
#   ./stack/llama.sh up        # resolve model, start profile, approve qwen-local lease
#   ./stack/llama.sh lease     # approve another qwen-local lease
#   ./stack/llama.sh status    # show the container, health and context
#   ./stack/llama.sh logs      # follow llama.cpp logs
#   ./stack/llama.sh down      # stop only the llama service
#
# Environment:
#   LLAMA_MODEL_PATH  GGUF path. Defaults to the qwen3.5:4b Ollama blob.
#   LLAMA_GPU         auto (default), 1, or 0.
#   LLAMA_CTX_SIZE    65536 by default.
#   LLAMA_SESSION     Lease session name (default: $USER-llama).
#   LLAMA_TTL         Lease TTL (default: 1h).
#   LEASE_ADMIN_TOKEN Admin token; also read from stack/secrets/stack.env.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE=(docker compose -f stack/docker-compose.yml)
GPU_OVERRIDE=(-f stack/docker-compose.llama-gpu.yml)
command_name="${1:-up}"
shift || true

die() { echo "llama: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: llama.sh <command> [options]

Commands:
  up [--no-lease]  Resolve the model, start the llama profile, approve a lease
  lease            Approve a qwen-local lease against an already-running stack
  status           Show container state, health and model context
  logs             Follow llama.cpp logs
  down             Stop the llama service; leave the rest of the stack running

Environment:
  LLAMA_MODEL_PATH, LLAMA_GPU=auto|1|0, LLAMA_CTX_SIZE,
  LLAMA_SESSION, LLAMA_TTL, LEASE_ADMIN_TOKEN
EOF
}

detect_gpu() {
  case "${LLAMA_GPU:-auto}" in
    1|yes|true) echo 1 ;;
    0|no|false) echo 0 ;;
    auto)
      if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo 1
      else
        echo 0
      fi
      ;;
    *) die "LLAMA_GPU must be auto, 1 or 0" ;;
  esac
}

compose_cmd() {
  local gpu
  gpu="$(detect_gpu)"
  local args=("${BASE[@]}" --profile llama)
  if ((gpu)); then
    args+=("${GPU_OVERRIDE[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

resolve_model() {
  if [[ -z "${LLAMA_MODEL_PATH:-}" ]]; then
    LLAMA_MODEL_PATH="$(./stack/llama-model.sh)"
    export LLAMA_MODEL_PATH
  fi
  [[ -f "$LLAMA_MODEL_PATH" ]] || die "model file not found: $LLAMA_MODEL_PATH"
  [[ -r "$LLAMA_MODEL_PATH" ]] || die "model file is not readable: $LLAMA_MODEL_PATH"
  echo "llama: model $LLAMA_MODEL_PATH"
}

load_admin_token() {
  if [[ -z "${LEASE_ADMIN_TOKEN:-}" && -f stack/secrets/stack.env ]]; then
    # shellcheck disable=SC1091
    set -a
    . stack/secrets/stack.env
    set +a
    export LEASE_ADMIN_TOKEN="${LEASE_ADMIN_TOKEN:-${BROKER_ADMIN_TOKEN:-}}"
  fi
  export LEASE_ADMIN_TOKEN="${LEASE_ADMIN_TOKEN:-}"
}

approve_lease() {
  load_admin_token
  local session="${LLAMA_SESSION:-${USER:-agent}-llama}"
  local ttl="${LLAMA_TTL:-1h}"
  echo "llama: approving a qwen-local lease (session=$session ttl=$ttl)"
  ./bin/lease approve \
    --session "$session" \
    --service litellm \
    --model qwen-local \
    --ttl "$ttl"
  cat <<EOF

llama: local model is ready.
  In OpenCode: /model litellm/qwen-local
  Default stays litellm/claude-sonnet.
EOF
}

cmd_up() {
  local no_lease=0
  while (($#)); do
    case "$1" in
      --no-lease) no_lease=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown up option: $1" ;;
    esac
  done

  local gpu
  gpu="$(detect_gpu)"
  resolve_model
  echo "llama: starting with LLAMA_GPU=$gpu LLAMA_CTX_SIZE=${LLAMA_CTX_SIZE:-65536}"
  local args=("${BASE[@]}" --profile llama)
  ((gpu)) && args+=("${GPU_OVERRIDE[@]}")
  "${args[@]}" up -d --wait
  if ((no_lease)); then
    echo "llama: started without a lease; run ./stack/llama.sh lease when ready"
    return 0
  fi
  approve_lease
}

cmd_lease() {
  approve_lease
}

cmd_status() {
  local args
  mapfile -t args < <(compose_cmd)
  "${args[@]}" ps llama
  if ! docker inspect opencode-llama >/dev/null 2>&1; then
    echo "llama: opencode-llama does not exist"
    return 0
  fi
  local state health
  state="$(docker inspect --format '{{.State.Status}}' opencode-llama)"
  if [[ "$state" != "running" ]]; then
    echo "llama: opencode-llama is $state"
    return 0
  fi
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' opencode-llama)"
  echo "llama: health=$health"
  if [[ "$health" == "healthy" ]]; then
    local key="${LLAMA_API_KEY:-sk-llama-local}"
    docker exec opencode-llama curl -fsS \
      -H "Authorization: Bearer $key" \
      http://127.0.0.1:8080/v1/models \
      | jq -r '.data[0] | "llama: model=\(.id) context=\(.meta.n_ctx) train=\(.meta.n_ctx_train)"' 2>/dev/null \
      || true
    docker exec opencode-llama sh -c 'nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader' 2>/dev/null \
      | sed 's/^/llama: gpu memory used,free = /' || true
  fi
}

cmd_logs() {
  local args
  mapfile -t args < <(compose_cmd)
  "${args[@]}" logs -f llama
}

cmd_down() {
  "${BASE[@]}" --profile llama stop llama
  echo "llama: stopped; the rest of the stack is unchanged"
}

case "$command_name" in
  up) cmd_up "$@" ;;
  lease) cmd_lease "$@" ;;
  status) cmd_status "$@" ;;
  logs) cmd_logs "$@" ;;
  down) cmd_down "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $command_name (try --help)" ;;
esac
