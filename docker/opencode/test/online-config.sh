#!/usr/bin/env bash
# Static checks for the online-model catalogue and launcher. No stack or model
# service needs to be running.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

COMPOSE=(docker compose -f stack/docker-compose.yml)

fail() { echo "online-config: $*" >&2; exit 1; }

base_services="$("${COMPOSE[@]}" config --services)"
if grep -qx llama <<<"$base_services"; then
  fail "the base stack must not start llama"
fi

for model in deepseek-chat deepseek-reasoner claude-sonnet claude-opus gpt-mini qwen-local; do
  grep -q "\"$model\":" config/opencode.jsonc \
    || fail "OpenCode catalogue is missing $model"
done

grep -q '"model": "{env:OPENCODE_MODEL}"' config/opencode.jsonc \
  || fail "OpenCode default model must come from OPENCODE_MODEL"

grep -q 'OPENCODE_MODEL:-litellm/deepseek-chat' run.sh \
  || fail "run.sh must default OPENCODE_MODEL to litellm/deepseek-chat"

grep -q 'model_name: deepseek-chat' stack/litellm.yaml \
  || fail "LiteLLM deepseek-chat alias missing"
grep -q 'model_name: deepseek-reasoner' stack/litellm.yaml \
  || fail "LiteLLM deepseek-reasoner alias missing"
grep -q 'api_key: os.environ/DEEPSEEK_API_KEY' stack/litellm.yaml \
  || fail "deepseek aliases must read DEEPSEEK_API_KEY"
grep -q 'deepseek-chat,deepseek-reasoner' stack/docker-compose.yml \
  || fail "broker LITELLM_MODELS default must include the deepseek aliases"

[[ -x stack/online.sh ]] || fail "stack/online.sh must be executable"
grep -q 'keepassxc-cli' stack/online.sh \
  || fail "online.sh must support the KeePassXC fallback"
grep -q '^online-up:' Makefile || fail "Makefile online-up target missing"
grep -q '^online-down:' Makefile || fail "Makefile online-down target missing"

echo "online-config: ok"
