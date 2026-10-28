## 1. Model source and repository hygiene

- [x] 1.1 Add `docker/opencode/stack/models/` and `*.gguf` to the root `.gitignore` under the existing "OpenCode secure stack" block, so a standalone model can live locally and no weights can be committed.
- [x] 1.2 Create `docker/opencode/stack/llama-model.sh` (bash, `set -euo pipefail`). Default `--ollama-root` to `${OLLAMA_MODELS:-$HOME/.ollama/models}` and read `manifests/registry.ollama.ai/library/qwen3.5/4b`; select the layer whose `mediaType` is `application/vnd.ollama.image.model` with `jq`, strip the `sha256:` prefix, and print `${ollama_root}/blobs/sha256-<digest>`.
- [x] 1.3 Add `--gguf <path>` to `llama-model.sh` as a passthrough that prints the absolute path without reading a manifest, and `--projector` to select `application/vnd.ollama.image.projector` for the deferred vision work.
- [x] 1.4 Add `--export` to `llama-model.sh` so it prints `export LLAMA_MODEL_PATH='<path>'`; without it print the bare path. On a missing manifest, missing blob or unreadable file, exit non-zero with a message naming the expected path and suggesting `--gguf`.
- [x] 1.5 Compare the resolved file mode/ownership against `${LLAMA_UID:-1000}` inside `llama-model.sh` and print a warning naming `LLAMA_UID`/`LLAMA_GID` when the container user could not read it; do not chmod or chown the host blob.
- [x] 1.6 `chmod +x docker/opencode/stack/llama-model.sh` and verify `./stack/llama-model.sh --gguf /tmp/test.gguf` prints the absolute path.

## 2. Base compose service

- [x] 2.1 Add a `llama` service to `docker/opencode/stack/docker-compose.yml` with `container_name: opencode-llama`, `profiles: ["llama"]`, `restart: unless-stopped`, and `image: ghcr.io/ggml-org/llama.cpp:server@sha256:d880b2a0e478795ce99d0a275732f5a50e579cb234ae7d2d3815afc909fd02f2`.
- [x] 2.2 Attach `llama` to `networks: [opencode-data]` only. Do not add `opencode-agent` or `opencode-egress`, and do not add a `ports:` key.
- [x] 2.3 Add the read-only mount `- ${LLAMA_MODEL_PATH:-./models/model.gguf}:/models/model.gguf:ro` and no other host mount. Do not use the required-variable form `${LLAMA_MODEL_PATH:?...}`: compose interpolates profile-disabled services too, which would break the base stack and `make test-all`.
- [x] 2.4 Set `environment: LLAMA_API_KEY: ${LLAMA_API_KEY:-sk-llama-local}` and `LLAMA_N_GPU_LAYERS: ${LLAMA_N_GPU_LAYERS:-0}`, and set `command:` to `--model /models/model.gguf`, `--alias qwen3.5-4b`, `--host 0.0.0.0`, `--port 8080`, `--ctx-size ${LLAMA_CTX_SIZE:-65536}`, `--parallel 1`, `--n-gpu-layers ${LLAMA_N_GPU_LAYERS:-0}`, `--flash-attn on`, `--cache-type-k q8_0`, `--cache-type-v q8_0`, `--jinja`, `--no-webui`, `--api-key ${LLAMA_API_KEY:-sk-llama-local}`.
- [x] 2.5 Add the healthcheck `test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8080/health"]` with `interval: 10s`, `timeout: 5s`, `retries: 30`, `start_period: 120s`.
- [x] 2.6 Harden the service with `read_only: true`, `tmpfs: /tmp:mode=1777,size=512m`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `init: true`, `pids_limit: ${LLAMA_PIDS_LIMIT:-512}`, `mem_limit: ${LLAMA_MEMORY:-6g}`, and `user: "${LLAMA_UID:-1000}:${LLAMA_GID:-1000}"`.
- [x] 2.7 Add `LLAMA_API_KEY: ${LLAMA_API_KEY:-sk-llama-local}` to the `litellm` service `environment:` block so the alias and the model runtime share the key; do not add it to the agent environment or to `run.sh`.
- [x] 2.8 Leave `llama` out of every `depends_on`, and leave `opencode-llama` out of the mandatory container list in `docker/opencode/run.sh` (which stays `opencode-squid`, `opencode-broker`, `opencode-litellm`).

## 3. GPU override

- [x] 3.1 Create `docker/opencode/stack/docker-compose.llama-gpu.yml` with `services.llama.image: ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:59633c1493f104de906b83a2588e9b44714ef2db0c9d7efbf01495dd5447e425`.
- [x] 3.2 In the override, add `gpus: all` and `environment.LLAMA_N_GPU_LAYERS: ${LLAMA_N_GPU_LAYERS:-99}` so the base `--n-gpu-layers ${LLAMA_N_GPU_LAYERS:-0}` command picks up 99.
- [x] 3.3 Verify `docker compose -f stack/docker-compose.yml -f stack/docker-compose.llama-gpu.yml --profile llama config` resolves the CUDA image, `gpus: all` and 99 layers without changing the base file.

## 4. LiteLLM, broker and OpenCode wiring

- [x] 4.1 Append a `qwen-local` entry to `model_list` in `docker/opencode/stack/litellm.yaml` with `litellm_params.model: openai/qwen3.5-4b`, `api_base: http://llama:8080/v1`, and `api_key: os.environ/LLAMA_API_KEY`.
- [x] 4.2 Change the `broker` service `LITELLM_MODELS` default in `docker/opencode/stack/docker-compose.yml` from `claude-sonnet,claude-opus,gpt-mini,deepseek-chat` to `claude-sonnet,claude-opus,gpt-mini,deepseek-chat,qwen-local`; leave `broker/settings.py` parsing unchanged.
- [x] 4.3 Add `"qwen-local": { "name": "Qwen3.5 4B (local, via LiteLLM)", "limit": { "context": 65536, "output": 8192 } }` to `provider.litellm.models` in `docker/opencode/config/opencode.jsonc`; leave the other entries and the top-level `"model": "litellm/claude-sonnet"` unchanged.
- [x] 4.4 Confirm `docker/opencode/config/opencode.jsonc` still allows only the `litellm` provider and that no new provider or `LLAMA_API_KEY` reference was added to it.

## 5. Tests

- [x] 5.1 Create `docker/opencode/test/llama-config.sh` (bash, `set -euo pipefail`, `cd` to `..`). Assert `docker compose -f stack/docker-compose.yml config --services` does not contain `llama`, and `docker compose -f stack/docker-compose.yml --profile llama config` does contain it.
- [x] 5.2 In `llama-config.sh`, assert the profiled config has no published ports for `llama`, mounts `/models/model.gguf` read-only, uses the CPU image in the base file, and that the GPU override selects the CUDA image with `gpus: all`.
- [x] 5.3 In `llama-config.sh`, assert `stack/litellm.yaml` contains `model_name: qwen-local` and `api_base: http://llama:8080/v1`, that the compose broker default contains `qwen-local`, and that `config/opencode.jsonc` contains the `qwen-local` entry with `"context": 65536` and `"output": 8192`.
- [x] 5.4 Add `test-llama-config` and `test-llama` targets to `docker/opencode/Makefile` (`.PHONY` plus `## name: description` help comments), and add `test-llama-config` to the `test-all` dependency list. Do not add `test-llama` to `test-all`.
- [x] 5.5 Create `docker/opencode/test/llama-smoke.sh`: skip with `llama-smoke: LLAMA_MODEL_PATH is not set; skipping` and exit 0 when the variable is unset; otherwise start `COMPOSE=(-f stack/docker-compose.yml --profile llama)` (plus `-f stack/docker-compose.llama-gpu.yml` when `LLAMA_GPU=1`), wait for healthy, and trap `down` on exit.
- [x] 5.6 In `llama-smoke.sh`, check `docker exec opencode-llama curl -fsS http://127.0.0.1:8080/health`, assert `/v1/models` reports `n_ctx: 65536`, and assert a `qwen-local` chat completion and a tool call through LiteLLM return successfully.
- [x] 5.7 In `llama-smoke.sh`, run a container on `opencode-agent` and assert `curl --max-time 3 http://llama:8080/health` and name resolution both fail, while the LiteLLM endpoint on `http://litellm:4000` remains reachable.
- [x] 5.8 Add a pytest case to `docker/opencode/broker/tests/test_broker.py` that approves a lease with `models=["qwen-local"]`, stubs `litellm.create_virtual_key`, and asserts the `models` argument equals `["qwen-local"]`; do not change broker logic.

## 6. Documentation

- [x] 6.1 Add `llama` to the "Secure stack" topology diagram in `docker/opencode/README.md` under `opencode-data`, with a note that only LiteLLM reaches it.
- [x] 6.2 Add a "Local model (llama.cpp)" subsection covering: resolving the Ollama blob with `stack/llama-model.sh --export`, standalone GGUF via `LLAMA_MODEL_PATH`, `--profile llama` with and without the GPU override, and that the RTX 3070 Ti uses about 5.2 GB at 64K.
- [x] 6.3 Document `LLAMA_CTX_SIZE`, `LLAMA_N_GPU_LAYERS`, `LLAMA_UID`/`LLAMA_GID`, `LLAMA_MEMORY`, the 32K fallback versus the previous Ollama 32K setting, and the git-ignored `stack/models/` directory.
- [x] 6.4 Document operator flow: start the profile, approve a lease with `--model qwen-local`, select `/model litellm/qwen-local`, keep `litellm/claude-sonnet` as default, and note that thinking is on with `chat_template_kwargs: {enable_thinking: false}` as a per-request opt-out.
- [x] 6.5 Document rollback: switch back to `litellm/claude-sonnet`, revoke the `qwen-local` lease, run `docker compose ... --profile llama stop llama`, and confirm cloud aliases need no restart.
- [x] 6.6 Add `docker/opencode/stack/llama.sh` with `up`/`lease`/`status`/`logs`/`down` subcommands and Makefile wrappers (`llama-up`, `llama-lease`, `llama-status`, `llama-logs`, `llama-down`), auto-resolving the Ollama GGUF and auto-detecting the GPU.

## 7. Validation

- [x] 7.1 Run `make -C docker/opencode test-llama-config` with no `LLAMA_MODEL_PATH` and no GPU, and confirm it passes.
- [x] 7.2 Run `make -C docker/opencode test-stack` and confirm the base stack still starts without the `llama` profile and without a model file.
- [x] 7.3 Run `openspec validate add-llama-cpp-local-model --strict` and fix any artifact issues.
