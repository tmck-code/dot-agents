## Why

The hardened OpenCode stack can only reach cloud models through LiteLLM, so an
offline or privacy-sensitive session has no model at all. A local Qwen3.5 4B
served by llama.cpp gives the agent a usable, free model without weakening the
network boundary: the agent still talks only to LiteLLM, and the model runtime
stays on the internal data network that the agent cannot join.

## What Changes

- Add a profile-gated `llama` service to `docker/opencode/stack/docker-compose.yml`,
  attached only to `opencode-data`, with no published port and a read-only GGUF
  mount. The base service uses the pinned CPU image; a new
  `docker-compose.llama-gpu.yml` override selects the pinned CUDA image and
  `gpus: all` for hosts with an NVIDIA GPU.
- Serve at 64K context by default (`LLAMA_CTX_SIZE=65536`), single slot
  (`--parallel 1`), flash attention on, `q8_0` KV cache, `--jinja`,
  `--no-webui`, and an API key. The previous 32K Ollama configuration is
  documented as prior behaviour, not copied.
- Resolve model weights from the existing Ollama GGUF blob through
  `LLAMA_MODEL_PATH`, with a helper that reads the Ollama manifest. A standalone
  GGUF path is supported as an alternative. No model file is committed.
- Add a LiteLLM alias `qwen-local` targeting `http://llama:8080/v1`, add
  `qwen-local` to the broker's default `LITELLM_MODELS` allowlist, and add
  `litellm/qwen-local` to the OpenCode model catalogue with
  `limit.context: 65536` and `limit.output: 8192`.
- Keep `litellm/claude-sonnet` as the default model. Think stays enabled by
  default, and vision/mmproj is deferred.
- Add an opt-in real-model smoke test and static configuration tests. The base
  stack smoke test continues to run without the `llama` profile, a GPU or a
  model file.
- Document enabling the profile, CPU versus GPU, model resolution, memory use,
  model switching and rollback in `docker/opencode/README.md`.

## Capabilities

### New Capabilities

- `local-model-serving`: the profile-gated llama.cpp runtime, its network
  placement, model supply, context and sampling defaults, hardening, health and
  operations.
- `local-model-routing`: the LiteLLM alias, broker model allowlist, OpenCode
  model catalogue entry, default-model guarantee and agent-reachability
  invariant.

### Modified Capabilities

<!-- No baseline specs exist yet; openspec/specs/ is empty because
     secure-opencode-runtime is not archived. The broker allowlist change is
     therefore captured inside local-model-routing rather than as a MODIFIED
     delta against credential-broker. -->

## Impact

- `docker/opencode/stack/docker-compose.yml`: new `llama` service, `llama`
  profile, GPU env passthrough, `LLAMA_API_KEY` for LiteLLM, and `qwen-local` in
  the broker's `LITELLM_MODELS` default.
- New `docker/opencode/stack/docker-compose.llama-gpu.yml` and
  `docker/opencode/stack/llama-model.sh`.
- `docker/opencode/stack/litellm.yaml`: `qwen-local` model entry.
- `docker/opencode/config/opencode.jsonc`: `qwen-local` model entry with limits;
  default model unchanged.
- `.gitignore`: ignore `docker/opencode/stack/models/` and `*.gguf`.
- New `docker/opencode/test/llama-smoke.sh` and `test/llama-config.sh`;
  `docker/opencode/Makefile` gains `test-llama` and includes the static test in
  `test-all`.
- `docker/opencode/broker/tests/test_broker.py`: allowlist coverage for
  `qwen-local`.
- `docker/opencode/README.md`: local model operations and rollback.
- No new host port, no new network, no provider root key in the agent, and no
  change to the default model or to the required stack services checked by
  `run.sh`.
