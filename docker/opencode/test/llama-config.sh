#!/usr/bin/env bash
# Static checks for the optional local llama.cpp model. No model file, GPU or
# running stack required.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

COMPOSE=(docker compose -f stack/docker-compose.yml)
GPU_COMPOSE=(docker compose -f stack/docker-compose.yml -f stack/docker-compose.llama-gpu.yml)

fail() { echo "llama-config: $*" >&2; exit 1; }

base_services="$("${COMPOSE[@]}" config --services)"
if grep -qx llama <<<"$base_services"; then
  fail "llama must be absent from the base stack"
fi

profiled="$("${COMPOSE[@]}" --profile llama config --format json)"
jq -e '.services.llama' >/dev/null <<<"$profiled" || fail "profiled config lacks llama"
jq -e '(.services.llama.ports // []) | length == 0' >/dev/null <<<"$profiled" \
  || fail "llama must not publish ports"
jq -e '.services.llama.volumes[] | select(.target == "/models/model.gguf") | .read_only == true' \
  >/dev/null <<<"$profiled" || fail "model mount must be read-only"
jq -e '.services.llama.image | startswith("ghcr.io/ggml-org/llama.cpp:server@")' \
  >/dev/null <<<"$profiled" || fail "base service must use the pinned CPU image"
jq -e '.services.llama.command[0] | contains("--ctx-size") and contains("--parallel 1") and contains("--jinja")' \
  >/dev/null <<<"$profiled" || fail "llama command is missing the required flags"
jq -e '.services.llama.environment.LLAMA_CTX_SIZE == "65536"' >/dev/null <<<"$profiled" \
  || fail "default context must be 65536"

gpu="$("${GPU_COMPOSE[@]}" --profile llama config --format json)"
jq -e '.services.llama.image | contains("server-cuda@")' >/dev/null <<<"$gpu" \
  || fail "GPU override must select the CUDA image"
jq -e '.services.llama.gpus[0].count == -1' >/dev/null <<<"$gpu" \
  || fail "GPU override must request all GPUs"
jq -e '.services.llama.environment.LLAMA_N_GPU_LAYERS == "99"' >/dev/null <<<"$gpu" \
  || fail "GPU override must default to 99 GPU layers"

grep -q 'model_name: qwen-local' stack/litellm.yaml \
  || fail "LiteLLM alias qwen-local missing"
grep -q 'api_base: http://llama:8080/v1' stack/litellm.yaml \
  || fail "LiteLLM alias must point at llama:8080"
grep -q 'claude-sonnet,claude-opus,gpt-mini,deepseek-chat,qwen-local' stack/docker-compose.yml \
  || fail "broker LITELLM_MODELS default must include qwen-local"
grep -q '"qwen-local"' config/opencode.jsonc \
  || fail "OpenCode qwen-local entry missing"
grep -q '"context": 65536' config/opencode.jsonc \
  || fail "OpenCode qwen-local context must be 65536"
grep -q '"output": 8192' config/opencode.jsonc \
  || fail "OpenCode qwen-local output must be 8192"
[[ -x stack/llama.sh ]] || fail "stack/llama.sh must be executable"
grep -q '^llama-up:' Makefile || fail "Makefile llama-up target missing"
grep -q '^llama-down:' Makefile || fail "Makefile llama-down target missing"

echo "llama-config: ok"
