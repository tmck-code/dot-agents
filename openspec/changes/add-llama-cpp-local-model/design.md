## Context

`docker/opencode/stack/docker-compose.yml` defines three internal networks:
`opencode-agent` (agent, Squid, broker, LiteLLM), `opencode-egress` (Squid,
broker, LiteLLM outbound) and `opencode-data` (Postgres and LiteLLM only). The
agent is attached to `opencode-agent` alone, so any service placed on
`opencode-data` is unreachable from the agent by construction. LiteLLM is
already dual-homed on `opencode-agent` and `opencode-data`, which makes it the
natural sole route to a local model.

LiteLLM reads provider aliases from `stack/litellm.yaml` and root keys from
`/run/secrets/litellm.env`. The broker mints per-lease virtual keys with a model
allowlist drawn from `LITELLM_MODELS` (default
`claude-sonnet,claude-opus,gpt-mini,deepseek-chat`). OpenCode's system policy
allows only the `litellm` provider, and `config/opencode.jsonc` lists the model
aliases with no explicit limits today. The default model is
`litellm/claude-sonnet`.

The host already has `qwen3.5:4b` in Ollama: a 2.65 GB Q4_K_M model GGUF and a
645 MB projector, both real GGUF files under `~/.ollama/models/blobs`. The
current Ollama runtime uses a 32K context, but the user asked for 64K; Qwen3.5
is trained for 262144 tokens, and llama.cpp loaded 64K in about 5.2 GB of an
8 GB RTX 3070 Ti. The GPU path is verified; the CPU path is the portable
default for hosts and CI without a GPU.

## Goals / Non-Goals

**Goals:**

- Offer a free, local, tool-capable model through the same LiteLLM path as cloud
  models, without giving the agent a new network route.
- Keep the model off by default so existing installs and `make test-all` do not
  need a 2.5 GB file or a GPU.
- Reuse the existing Ollama weights instead of forcing a second download.
- Make the 64K context explicit end to end: server flag, LiteLLM alias and the
  OpenCode model limit.
- Keep the model runtime hardened to the same standard as the other stack
  services: no published port, read-only mounts, dropped capabilities, resource
  limits.
- Make qwen-local the default and only listed OpenCode model while leaving thinking behaviour unchanged; cloud aliases remain in LiteLLM but are omitted from the OpenCode catalogue.

**Non-Goals:**

- Vision or image input in the first slice. The `mmproj` projector is not
  mounted or passed to llama.cpp; the resolver can report its path for a
  follow-up change.
- Auto-starting the local model. Enabling the profile stays an explicit operator
  action, while the default model selection is static in OpenCode config.
- Running the model on the agent network, publishing a host port, or exposing a
  llama.cpp web UI.
- Downloading, converting or committing model weights. The change consumes an
  existing GGUF.
- Changing the broker's lease or virtual-key design; only the default model
  allowlist grows.
- Guaranteeing a particular tokens-per-second rate on CPU.

## Decisions

### Profile-gated service in the base compose file

Add a `llama` service with `profiles: ["llama"]` to
`stack/docker-compose.yml`. Without `--profile llama`, `docker compose up` and
`up --wait` ignore it, so `test/stack-smoke.sh` and current users are unaffected.
With the profile, `depends_on` is deliberately empty: LiteLLM must start even
when the model does not, and enabling the model later must not recreate LiteLLM.

Alternative considered: a separate compose file that must be passed with a
second `-f`. Rejected because two compose invocations drift, and profile
semantics express "optional service" directly.

Alternative considered: always-on. Rejected because most sessions use cloud
models, and a 2.5 GB load plus GPU memory is not an acceptable default cost.

### Place the runtime on `opencode-data`, not `opencode-agent`

The `llama` service joins `opencode-data` only. The agent is not on that
network, so it cannot resolve `llama` even if it ignores the system policy.
LiteLLM reaches `http://llama:8080/v1` because it already joins
`opencode-data`. No port is published, and llama.cpp's web UI is disabled with
`--no-webui`.

Alternative considered: attach `llama` to `opencode-agent` for simpler
name resolution. Rejected: that makes the model directly reachable and bypasses
LiteLLM's virtual-key accounting and model allowlist.

### CPU image in the base, CUDA override for this host

The base service uses the pinned CPU image
`ghcr.io/ggml-org/llama.cpp:server` with `--n-gpu-layers 0`. A separate
`stack/docker-compose.llama-gpu.yml` overrides the image to the pinned
`server-cuda` digest, adds `gpus: all`, and sets `LLAMA_N_GPU_LAYERS=99`.
Operators on the verified RTX 3070 Ti run:

```
docker compose -f stack/docker-compose.yml \
  -f stack/docker-compose.llama-gpu.yml --profile llama up -d
```

This keeps CI and CPU-only hosts working with the same base file and one
documented override. Both images are pinned by the digests recorded in the
research report.

Alternative considered: CUDA as the base image with a CPU override. Rejected
because it makes the common CI path depend on NVIDIA tooling and `--gpus`.

### One model source variable and a resolver script

Compose mounts `${LLAMA_MODEL_PATH:-./models/model.gguf}:/models/model.gguf:ro`.
The default is relative to `stack/`, is git-ignored, and only matters when the
profile is enabled; a required-variable form (`:?`) is deliberately avoided
because Compose interpolates every service, so it would break the profile-off
stack and `make test-all`. When the variable is unset and the default file is
absent, the bind mount fails with an error naming that path, and
`stack/llama-model.sh` is the documented way to supply a real one. The value is
host-specific and never committed. `stack/llama-model.sh` resolves the Ollama
manifest (`~/.ollama/models/manifests/registry.ollama.ai/library/qwen3.5/4b`),
selects the layer with `mediaType:
application/vnd.ollama.image.model`, and prints the blob path or an `export`
line. It also accepts `--gguf <path>` for a standalone file and `--projector`
to report the `application/vnd.ollama.image.projector` blob for the deferred
vision work. It does not copy or re-download weights.

`docker/opencode/stack/models/` and `*.gguf` are git-ignored so a standalone
model can live locally without entering the repository.

Alternative considered: bake the model into a derived image. Rejected: a 2.5 GB
image layer is slow to rebuild, duplicates host data, and cannot be digest-pinned
meaningfully.

### 64K context, one slot, explicit flags

The server command sets:

```
--model /models/model.gguf
--alias qwen3.5-4b
--host 0.0.0.0 --port 8080
--ctx-size ${LLAMA_CTX_SIZE:-65536}
--parallel 1
--n-gpu-layers ${LLAMA_N_GPU_LAYERS:-0}
--flash-attn on
--cache-type-k q8_0 --cache-type-v q8_0
--jinja --no-webui
--api-key ${LLAMA_API_KEY:-sk-llama-local}
```

`--parallel 1` is load-bearing: llama.cpp's auto-parallel mode produced four
slots at 64K each on the test host. `--jinja` keeps the model's tool-calling
template active; `--no-webui` removes an unnecessary surface. The base CPU
service defaults `LLAMA_N_GPU_LAYERS=0`; the GPU override defaults it to 99.
The previous Ollama 32K setting is documented as prior behaviour, and
`LLAMA_CTX_SIZE` allows a 32K fallback on smaller hosts.

Alternative considered: leaving context to llama.cpp's default. Rejected: the
trained context is 262144 and the default would allocate far beyond the host's
VRAM.

### Shared local API key, no secrets-file dependency

Both `llama` and `litellm` receive `LLAMA_API_KEY`, defaulting to
`sk-llama-local`. llama.cpp requires it on `/v1`, and LiteLLM sends it via
`api_key: os.environ/LLAMA_API_KEY`. This is a local network credential, not a
provider root key: it is not published on the host, and the agent never sees it.
Keeping it as a compose default avoids making the optional profile depend on a
new entry in `stack/secrets/litellm.env`. Operators can override it in their
env file, and both services read the same value.

Alternative considered: no API key because the network is internal. Rejected as
defence in depth; the verified llama.cpp command already used one, and a
misconfigured network attachment should not silently expose the model.

### LiteLLM alias, broker allowlist, explicit lease scope

`stack/litellm.yaml` gains:

```yaml
- model_name: qwen-local
  litellm_params:
    model: openai/qwen3.5-4b
    api_base: http://llama:8080/v1
    api_key: os.environ/LLAMA_API_KEY
```

`LITELLM_MODELS` in the broker environment gains `qwen-local`. The broker
continues to mint keys from the lease's explicit model list, falling back to
`LITELLM_MODELS` only when the lease omits one. A lease approved with
`--model qwen-local` therefore gets a virtual key limited to that alias; a
lease without it is rejected by LiteLLM. The broker code, store and admin API do
not change.

### OpenCode model entry is the default

`config/opencode.jsonc` adds `qwen-local` under `provider.litellm.models` with
`name` and `limit: {context: 65536, output: 8192}`, and changes the top-level
`"model"` to `litellm/qwen-local`. This branch exists to run the local model, so
making it the default is the intended behaviour; cloud aliases such as
`litellm/claude-sonnet` stay in LiteLLM but are omitted from the OpenCode
`provider.litellm.models` map, so only `qwen-local` is listed. Re-enable a
cloud alias by adding its entry back. Thinking remains enabled; the README
documents
`chat_template_kwargs: {enable_thinking: false}` for a per-request opt-out.

Because OpenCode config is static and the llama profile is host-side, the
default points at an unavailable alias when the profile is down. `make
llama-up` is the supported start path; callers that only want cloud models can
stop the profile and select a cloud alias explicitly. The alternative — keeping
claude-sonnet as the default and making the local model opt-in — was rejected
by the user because it defeats the purpose of the change.

### Health, hardening and required-service independence

The service healthcheck is
`curl -fsS http://127.0.0.1:8080/health`, returning 503 while weights load and
200 when ready. The image ships `curl`. A generous `start_period` (120s)
covers cold loads; the healthcheck does not block LiteLLM or `run.sh`.

Runtime hardening mirrors the other services: `read_only: true`, tmpfs `/tmp`,
`cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `init: true`,
memory and PID limits, and `user: "${LLAMA_UID:-1000}:${LLAMA_GID:-1000}"`. The
model file must be readable by that UID; the resolver prints a warning when it
is not. `run.sh`'s required stack check stays `opencode-squid`,
`opencode-broker`, `opencode-litellm`; `opencode-llama` is optional by design.

### Tests: static always, real model opt-in

`test/llama-config.sh` runs in `make test-all` with no model and no GPU. It
asserts that `docker compose config` without the profile omits `llama`, that
`docker compose --profile llama config` shows a read-only model mount and no
published port, and that the LiteLLM alias, OpenCode limit and broker default
are present.

`test/llama-smoke.sh` (`make test-llama`) is opt-in and requires
`LLAMA_MODEL_PATH` plus a working Docker/GPU host. It starts the profile, waits
for healthy, checks `/v1/models` reports 64K, calls `qwen-local` through
LiteLLM, verifies a tool call, and verifies the agent cannot reach `llama`
directly. It skips with a clear message when `LLAMA_MODEL_PATH` is unset.

A broker pytest case asserts that a `qwen-local` lease scope is passed through
to `create_virtual_key` unchanged. No broker logic changes.

## Risks / Trade-offs

- **2.5 GB model absent from CI and fresh clones** → the profile is off by
  default; the real-model suite is opt-in; the static suite still guards config.
- **CPU inference is slow enough to frustrate interactive use** → document the
  GPU override as the recommended path on this host, and keep the CPU image for
  portability and CI only.
- **64K KV cache exceeds VRAM on smaller GPUs** → default 64K with
  `LLAMA_CTX_SIZE` override, `--parallel 1`, and a documented 32K fallback;
  llama.cpp logs the allocation.
- **A missing default model path surfaces as a bind-mount error** → the
  `.gitignore`d default path is documented, and `llama-model.sh` is the
  supported way to set `LLAMA_MODEL_PATH`; the error names the expected file.
- **Model blob permissions versus the container UID** → run as
  `${LLAMA_UID:-1000}:${LLAMA_GID:-1000}`, have the resolver warn when the blob
  is unreadable, and document `LLAMA_UID`/`LLAMA_GID` overrides.
- **Default model points at `qwen-local` while the profile is down** → the
  default calls fail; LiteLLM itself stays healthy and cloud aliases keep
  working if re-added to the OpenCode catalogue. The README says to start
  `make llama-up` before OpenCode.
- **Lease scoped to `qwen-local` after the model stops** → the lease remains
  valid but model calls fail until the profile is restarted; no credential is
  exposed.
- **Ollama layout changes across versions** → the resolver reads the manifest
  media type rather than a hard-coded blob name and supports `--gguf` as an
  escape hatch.
- **`--jinja` and tool calling vary by chat template** → verified with this
  Qwen3.5 build through LiteLLM; the smoke test covers one tool call, and the
  OpenCode model entry can be removed without touching cloud aliases.
- **Shared default API key is weak** → it is confined to `opencode-data`, is
  overridable, and is never mounted into the agent; the network boundary remains
  the primary control.

## Migration Plan

1. Land the service, resolver, gitignore and static tests with the profile
   disabled. Existing stacks are unchanged.
2. Add the LiteLLM alias, broker default and OpenCode model entry, and make
   `litellm/qwen-local` the default. Start the profile before OpenCode; cloud
   aliases remain selectable with `/model`.
3. On a GPU host, resolve the Ollama blob, start
   `--profile llama` with the GPU override, approve a lease with
   `--model qwen-local`, and select `/model litellm/qwen-local`.
4. Roll back by selecting `/model litellm/claude-sonnet`, revoking the
   `qwen-local` lease, and running `docker compose ... --profile llama stop
   llama`. To use a cloud model again, add it back to `provider.litellm.models`
   and set the top-level `model` back to `litellm/claude-sonnet`. Removing the service and alias is additive-safe
   because no other service depends on `llama`.

## Open Questions

- Should vision arrive as a follow-up change that mounts the Ollama projector
  and adds `--mmproj`, or is a separate multimodal model preferable?
- Is CPU latency acceptable enough to document a default `LLAMA_CTX_SIZE=32768`
  profile for CPU-only hosts, or should 64K stay the unconditional default?
- Should the static config test also assert the pinned image digests, so a
  digest drift is a test failure rather than a review catch?
