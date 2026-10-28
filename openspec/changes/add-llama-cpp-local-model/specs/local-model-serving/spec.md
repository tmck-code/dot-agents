## ADDED Requirements

### Requirement: Optional profile-gated runtime
The stack SHALL define a `llama` service in `docker/opencode/stack/docker-compose.yml` behind the `llama` compose profile, and SHALL NOT start it for a plain `docker compose up` without that profile.

#### Scenario: Base stack omits the model runtime
- **WHEN** the operator runs `docker compose -f stack/docker-compose.yml config` or `up -d --wait` without `--profile llama`
- **THEN** no `llama` service is started, and the existing agent, Squid, broker, LiteLLM and Postgres services behave as before

#### Scenario: Profile enables the model runtime
- **WHEN** the operator runs `docker compose -f stack/docker-compose.yml --profile llama up -d`
- **THEN** the `llama` service starts while every other service keeps its existing configuration

#### Scenario: Model runtime is not a required dependency
- **WHEN** LiteLLM starts while the `llama` profile is disabled or the model is still loading
- **THEN** LiteLLM becomes healthy and cloud model aliases remain usable

### Requirement: Isolated network placement
The `llama` service SHALL attach only to the `opencode-data` network, SHALL NOT publish a host port, and SHALL NOT be reachable from any container attached only to `opencode-agent`.

#### Scenario: Agent cannot resolve the model runtime
- **WHEN** a container on `opencode-agent` attempts to resolve or connect to `llama:8080`
- **THEN** the attempt fails because `llama` is not on that network

#### Scenario: Only LiteLLM reaches the model
- **WHEN** the `litellm` container calls `http://llama:8080/v1`
- **THEN** the call succeeds because LiteLLM is attached to `opencode-data`

#### Scenario: No host exposure
- **WHEN** the running `llama` service is inspected
- **THEN** it has no published ports and its web UI is disabled with `--no-webui`

### Requirement: Read-only model supply
The service SHALL mount a host GGUF file read-only at `/models/model.gguf` from `LLAMA_MODEL_PATH`, defaulting to the git-ignored `stack/models/model.gguf` only when the profile is enabled, and SHALL NOT commit model weights to the repository.

#### Scenario: Existing Ollama blob is reused
- **WHEN** the operator resolves `qwen3.5:4b` from the Ollama manifest and exports `LLAMA_MODEL_PATH`
- **THEN** the container mounts that blob read-only and llama.cpp loads it without copying or re-downloading the file

#### Scenario: Standalone GGUF is supported
- **WHEN** the operator points `LLAMA_MODEL_PATH` at a standalone GGUF file
- **THEN** the service loads it through the same read-only mount

#### Scenario: Missing model path fails clearly
- **WHEN** the `llama` service is started without `LLAMA_MODEL_PATH` and no `stack/models/model.gguf` exists
- **THEN** compose refuses to start it with a bind-mount error naming the expected path, while starting without the profile still succeeds

#### Scenario: Weights are never committed
- **WHEN** `docker/opencode/stack/models/` or any `*.gguf` file exists in a working tree
- **THEN** git ignores it and the repository contains no model weights

### Requirement: 64K single-slot inference defaults
The server SHALL run with a 65536-token context by default, exactly one parallel slot, flash attention enabled, `q8_0` key and value caches, the model's Jinja chat template, and the alias `qwen3.5-4b`, with the context overridable through `LLAMA_CTX_SIZE`.

#### Scenario: Context and slot count are explicit
- **WHEN** the model is healthy at default settings and `/v1/models` is queried
- **THEN** the reported context is 65536 and llama.cpp reports one slot

#### Scenario: Context can be reduced
- **WHEN** the operator sets `LLAMA_CTX_SIZE=32768` and restarts the service
- **THEN** the server starts with a 32768-token context and the previous Ollama 32K behaviour is documented as an option rather than a default

#### Scenario: KV cache is quantised
- **WHEN** the container command is inspected
- **THEN** it contains `--flash-attn on`, `--cache-type-k q8_0`, `--cache-type-v q8_0`, and `--parallel 1`

### Requirement: CPU base with GPU override
The base service SHALL use the digest-pinned CPU llama.cpp image with zero GPU layers, and a separate GPU override file SHALL select the digest-pinned CUDA image with `gpus: all` and a configurable GPU-layer count.

#### Scenario: Base stack needs no GPU
- **WHEN** the base compose file is used on a host without an NVIDIA GPU
- **THEN** the service uses `ghcr.io/ggml-org/llama.cpp:server` with `--n-gpu-layers 0` and requires no GPU runtime

#### Scenario: GPU host uses the override
- **WHEN** the operator adds `-f stack/docker-compose.llama-gpu.yml` on the verified RTX 3070 Ti host
- **THEN** the service uses `ghcr.io/ggml-org/llama.cpp:server-cuda`, requests `gpus: all`, and defaults `LLAMA_N_GPU_LAYERS` to 99

### Requirement: Hardened runtime
The `llama` service SHALL run with a read-only root filesystem, a writable `/tmp` tmpfs, all capabilities dropped, `no-new-privileges`, an init process, memory and PID limits, and a non-root UID/GID configurable through `LLAMA_UID` and `LLAMA_GID`.

#### Scenario: Capabilities and root filesystem are restricted
- **WHEN** the running `llama` container is inspected
- **THEN** its effective capability set is empty, `NoNewPrivs` is set, and its root filesystem is read-only with `/tmp` writable

#### Scenario: Model file is readable by the runtime user
- **WHEN** the resolved GGUF file is readable by the configured UID
- **THEN** the container starts and loads the model, and an unreadable file produces a resolver warning that names the UID/GID override

### Requirement: Health and readiness
The service SHALL expose a healthcheck that calls `curl -fsS http://127.0.0.1:8080/health` with a start period long enough for a cold model load, and SHALL report healthy only after the model is ready.

#### Scenario: Loading is not healthy
- **WHEN** the model is still loading and `/health` returns 503
- **THEN** the container health status is not `healthy`

#### Scenario: Ready model is healthy
- **WHEN** the model has loaded and `/health` returns 200
- **THEN** the container health status becomes `healthy`

### Requirement: Base verification without the model
The default test suite SHALL verify the model configuration without requiring the `llama` profile, a GPU, or a model file, and a separate opt-in suite SHALL exercise the real model.

#### Scenario: Static tests run model-free
- **WHEN** `make test-all` runs on a host with no GGUF file
- **THEN** it verifies profile gating, the read-only mount, absence of published ports, and the alias/allowlist/limit wiring without starting `llama`

#### Scenario: Real-model smoke test is explicit
- **WHEN** the operator runs `make test-llama` with `LLAMA_MODEL_PATH` set
- **THEN** the suite starts the profile, checks health and a LiteLLM completion, and skips with a clear message when the variable is unset
