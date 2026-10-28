#!/usr/bin/env bash
# Opt-in real-model smoke test for the llama.cpp profile.
#
#   LLAMA_MODEL_PATH="$(./stack/llama-model.sh)" make test-llama
#   LLAMA_GPU=1 LLAMA_MODEL_PATH=... make test-llama
#
# Requires a real GGUF, a working Docker host, and optionally an NVIDIA GPU.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -z "${LLAMA_MODEL_PATH:-}" ]]; then
  echo "llama-smoke: LLAMA_MODEL_PATH is not set; skipping"
  exit 0
fi

IMAGE="${IMAGE:-opencode-dev:local}"
COMPOSE=(docker compose -f stack/docker-compose.yml --profile llama)
if [[ "${LLAMA_GPU:-0}" == "1" ]]; then
  COMPOSE+=(-f stack/docker-compose.llama-gpu.yml)
fi
export LLAMA_MODEL_PATH
export LLAMA_API_KEY="${LLAMA_API_KEY:-sk-llama-local}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-master}"
export BROKER_ADMIN_TOKEN="${BROKER_ADMIN_TOKEN:-change-me}"
export LITELLM_DB_PASSWORD="${LITELLM_DB_PASSWORD:-litellm-local}"
export LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-65536}"

cleanup() {
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "llama-smoke: building $IMAGE" >&2
  make build
fi

mkdir -p stack/secrets
echo "llama-smoke: starting the stack with the llama profile"
"${COMPOSE[@]}" up -d --build --wait

echo "llama-smoke: checking llama.cpp health and context"
docker exec opencode-llama curl -fsS \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
  http://127.0.0.1:8080/health >/dev/null
models_json="$(docker exec opencode-llama curl -fsS \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
  http://127.0.0.1:8080/v1/models)"
jq -e '.data[0].meta.n_ctx == 65536' >/dev/null <<<"$models_json" \
  || { echo "llama-smoke: unexpected context: $models_json" >&2; exit 1; }

echo "llama-smoke: calling qwen-local through LiteLLM"
agent_request() {
  docker run --rm --init --network opencode-agent \
    --env "LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY" \
    --entrypoint bash "$IMAGE" -c "$1"
}

chat_json="$(agent_request '
  curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    http://litellm:4000/v1/chat/completions \
    -d "{\"model\":\"qwen-local\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: local-ok\"}],\"max_tokens\":64,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false}}"
')"
jq -e '.choices[0].message.content | length > 0' >/dev/null <<<"$chat_json" \
  || { echo "llama-smoke: empty chat completion: $chat_json" >&2; exit 1; }

tool_json="$(agent_request '
  curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    http://litellm:4000/v1/chat/completions \
    -d "{\"model\":\"qwen-local\",\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Sydney? Use the tool.\"}],\"chat_template_kwargs\":{\"enable_thinking\":false},\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get current weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":256,\"temperature\":0}"
')"
jq -e '.choices[0].message.tool_calls | length > 0' >/dev/null <<<"$tool_json" \
  || { echo "llama-smoke: tool call missing: $tool_json" >&2; exit 1; }

echo "llama-smoke: checking the agent cannot reach llama directly"
agent_request '
  if getent hosts llama >/dev/null 2>&1; then
    echo "llama-smoke: agent resolved llama" >&2
    exit 1
  fi
  if curl --max-time 3 -fsS http://llama:8080/health >/dev/null 2>&1; then
    echo "llama-smoke: agent reached llama" >&2
    exit 1
  fi
  curl -fsS http://litellm:4000/health/liveliness >/dev/null
'

echo "llama-smoke: ok"
