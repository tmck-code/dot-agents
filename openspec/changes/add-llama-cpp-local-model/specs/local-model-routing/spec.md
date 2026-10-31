## ADDED Requirements

### Requirement: LiteLLM local-model alias
LiteLLM SHALL expose a `qwen-local` alias backed by `openai/qwen3.5-4b` at `http://llama:8080/v1`, authenticated with the shared local `LLAMA_API_KEY`, and SHALL keep the alias independent of the `llama` profile lifecycle.

#### Scenario: Alias is advertised
- **WHEN** LiteLLM is running and its `/v1/models` endpoint is queried
- **THEN** `qwen-local` is listed alongside the cloud aliases

#### Scenario: Alias reaches llama.cpp
- **WHEN** a caller with a valid virtual key sends a chat completion to `qwen-local` while the profile is up
- **THEN** LiteLLM forwards it to `http://llama:8080/v1` and returns the model response

#### Scenario: Profile down does not break LiteLLM
- **WHEN** the `llama` profile is disabled and a cloud alias is called
- **THEN** the cloud alias still succeeds and only `qwen-local` calls fail

### Requirement: OpenCode model catalogue entry
The OpenCode system policy SHALL list `qwen-local` under the `litellm` provider with `limit.context: 65536` and `limit.output: 8192`, and the top-level default model SHALL be `litellm/qwen-local`. Cloud aliases MAY remain configured in LiteLLM but SHALL NOT be listed in the OpenCode `provider.litellm.models` map, so only `qwen-local` is offered by default.

#### Scenario: Local model is selectable
- **WHEN** the agent starts and the model catalogue is inspected
- **THEN** `litellm/qwen-local` is available with a 65536-token context limit and an 8192-token output limit

#### Scenario: Local model is the default
- **WHEN** the agent starts with no model override
- **THEN** it uses `litellm/qwen-local`

#### Scenario: Cloud aliases are not listed by default
- **WHEN** the agent starts with no model override
- **THEN** the model picker lists `litellm/qwen-local` but none of the omitted cloud aliases

#### Scenario: Cloud alias can be re-added
- **WHEN** the operator adds a cloud alias back to `provider.litellm.models` and rebuilds
- **THEN** that alias appears in the catalogue and still routes through LiteLLM

#### Scenario: Context limit matches the server
- **WHEN** the model is selected and a long conversation approaches the context limit
- **THEN** OpenCode's configured 65536-token limit matches the llama.cpp `--ctx-size` default

### Requirement: Broker model allowlist
The broker SHALL include `qwen-local` in its default `LITELLM_MODELS` allowlist, and SHALL mint a `qwen-local`-scoped virtual key only for a lease that explicitly includes that model.

#### Scenario: Default allowlist includes the alias
- **WHEN** the broker starts with no `LITELLM_MODELS` override
- **THEN** its default allowlist contains `claude-sonnet`, `claude-opus`, `gpt-mini`, `deepseek-chat` and `qwen-local`

#### Scenario: Lease can request the local model
- **WHEN** the operator approves a lease with `--model qwen-local`
- **THEN** the broker passes `qwen-local` to `create_virtual_key` unchanged and the resulting key reaches the local alias

#### Scenario: Lease without the model is rejected
- **WHEN** a lease is scoped only to cloud aliases and its key calls `qwen-local`
- **THEN** LiteLLM rejects the call because the model is outside the key's allowlist

### Requirement: No direct agent access to the model
The agent SHALL reach the local model only through LiteLLM, and SHALL NOT be able to resolve or connect to the `llama` service directly.

#### Scenario: Agent tries the model service directly
- **WHEN** a process inside the agent container resolves or connects to `llama:8080`
- **THEN** the attempt fails because the agent is not attached to `opencode-data`

#### Scenario: Agent goes through LiteLLM
- **WHEN** the agent sends a chat completion to the LiteLLM base URL for `qwen-local`
- **THEN** the request succeeds without the agent knowing the model service address or API key

#### Scenario: Agent has no model key
- **WHEN** the agent container's environment and filesystem are inspected
- **THEN** `LLAMA_API_KEY` is absent and only the per-lease LiteLLM virtual key is present

### Requirement: Tools and thinking behaviour
The local model path SHALL preserve tool calling through LiteLLM and SHALL leave Qwen thinking enabled by default.

#### Scenario: Tool call passes through
- **WHEN** a request through `qwen-local` asks the model to call a tool
- **THEN** the response contains `tool_calls` and the arguments survive the LiteLLM hop

#### Scenario: Thinking is opt-out only
- **WHEN** a request does not set `chat_template_kwargs`
- **THEN** thinking stays enabled, and a request that sets `chat_template_kwargs: {enable_thinking: false}` suppresses it for that request

#### Scenario: Coding path needs no vision
- **WHEN** the model is used for text and tool tasks without an `mmproj` projector
- **THEN** those tasks work and image input is documented as a follow-up rather than a requirement
