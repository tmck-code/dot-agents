IMAGE ?= opencode-dev:local
OPENCODE_VERSION ?= 2.1.4
# Set for a fully verified download in CI/release builds:
#   make build OPENCODE_SHA256=<sha256-of-opencode-binary>
OPENCODE_SHA256 ?=
PYTHON_VERSION ?= 3.13
UID ?= $(shell id -u)
GID ?= $(shell id -g)

HOST_ARCH := $(shell docker version --format '{{.Server.Arch}}' 2>/dev/null)
ifeq ($(strip $(HOST_ARCH)),)
HOST_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
endif
HOST_PLATFORM ?= linux/$(HOST_ARCH)
REPO_ROOT ?= $(shell git -C $(CURDIR) rev-parse --show-toplevel 2>/dev/null || echo $(CURDIR))

# Published multi-arch images must not inherit the build machine's user. Override
# these when building for a different owner; local `make build` uses the host ID.
PUBLISH_UID ?= 1000
PUBLISH_GID ?= 1000

LABELS = \
	--label org.opencontainers.image.title="OpenCode dev image" \
	--label org.opencontainers.image.source="https://github.com/tmck-code/dot-agents" \
	--label org.opencontainers.image.licenses="MIT" \
	--label org.opencontainers.image.version="$(OPENCODE_VERSION)" \
	--label dev.opencode.hardened="true"

BUILD_ARGS = \
	--build-arg UID=$(UID) \
	--build-arg GID=$(GID) \
	--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	--build-arg OPENCODE_SHA256=$(OPENCODE_SHA256) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION)

PUBLISH_BUILD_ARGS = \
	--build-arg UID=$(PUBLISH_UID) \
	--build-arg GID=$(PUBLISH_GID) \
	--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	--build-arg OPENCODE_SHA256=$(OPENCODE_SHA256) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION)

.PHONY: build run shell test test-legacy test-hardening test-egress test-stack \
	test-broker test-guardrails test-worktree test-unsafe test-no-secrets \
	test-llama-config test-llama llama-up llama-lease llama-status llama-logs llama-down \
	excalidraw-up excalidraw-down test-excalidraw test-all build-multi clean help

## build: build for this host's architecture and load it into Docker
build:
	docker buildx build --load --platform $(HOST_PLATFORM) $(BUILD_ARGS) $(LABELS) -t $(IMAGE) .

## run: open the OpenCode TUI in the current repo
run:
	REPO_ROOT="$(REPO_ROOT)" ./run.sh

## shell: open bash in the container, same mounts and workdir
shell:
	REPO_ROOT="$(REPO_ROOT)" ./run.sh --shell

## test: smoke-test the toolchain and a uv venv install (needs network)
test:
	docker run --rm --init --entrypoint bash $(IMAGE) -c 'set -euo pipefail; \
		echo "opencode $$(opencode --version)"; \
		echo "python   $$(python --version)"; \
		echo "node     $$(node --version)"; \
		echo "npm      $$(npm --version)"; \
		echo "uv       $$(uv --version)"; \
		uv venv /tmp/venv; \
		uv pip install --python /tmp/venv/bin/python six; \
		/tmp/venv/bin/python -c "import six; print(\"six\", six.__version__)"; \
		opencode debug paths'

## test-legacy: verify the legacy toolchain contract (section 1 baseline)
test-legacy:
	IMAGE=$(IMAGE) ./test/legacy-smoke.sh

## test-hardening: non-root, no sudo, no secrets, read-only system policy
test-hardening:
	IMAGE=$(IMAGE) ./test/image-hardening.sh

## test-egress: direct internet, host LAN, metadata and allowlist behaviour
test-egress:
	IMAGE=$(IMAGE) ./test/egress-bypass.sh

## test-stack: start the compose stack, wait for health, run the agent, tear down
test-stack:
	IMAGE=$(IMAGE) ./test/stack-smoke.sh

## test-broker: pytest coverage for leases, expiry, revocation and logging
test-broker:
	docker run --rm -v "$(CURDIR)/broker:/app/broker" -w /app -e PYTHONPATH=/app \
		python:3.12-slim@sha256:12316debbfb86890f6b2d825820612741ba527ad5a44e3902759141d572bfe8f \
		sh -c 'pip install --quiet -r /app/broker/requirements-dev.txt && pytest -q /app/broker/tests'

## test-guardrails: protected paths, external directories and audit redaction
test-guardrails:
	IMAGE=$(IMAGE) ./test/guardrails.sh

## test-worktree: linked worktree mounts still work in safe mode
test-worktree:
	IMAGE=$(IMAGE) ./test/worktree-smoke.sh

## test-unsafe: --unsafe warns and restores legacy mounts; safe is the default
test-unsafe:
	IMAGE=$(IMAGE) ./test/unsafe-mode.sh

## test-no-secrets: root keys/App key/PAT never reach the agent; revoked key rejected
test-no-secrets:
	IMAGE=$(IMAGE) ./test/no-secrets.sh

## test-llama-config: static checks for the optional local model (no model/GPU)
test-llama-config:
	./test/llama-config.sh

## test-llama: opt-in real-model smoke test (needs LLAMA_MODEL_PATH)
test-llama:
	LLAMA_MODEL_PATH="$(LLAMA_MODEL_PATH)" LLAMA_GPU="$(LLAMA_GPU)" \
		IMAGE=$(IMAGE) ./test/llama-smoke.sh

## llama-up: resolve qwen3.5, start the llama profile and approve a lease
llama-up:
	./stack/llama.sh up

## llama-lease: approve another lease for qwen-local
llama-lease:
	./stack/llama.sh lease

## llama-status: show the llama container, health and context
llama-status:
	./stack/llama.sh status

## llama-logs: follow llama.cpp logs
llama-logs:
	./stack/llama.sh logs

## llama-down: stop the llama service, leave the rest of the stack up
llama-down:
	./stack/llama.sh down

## excalidraw-up: start the optional Excalidraw renderer sidecar
excalidraw-up:
	docker compose -f stack/docker-compose.yml --profile tools up -d --build --wait --force-recreate excalidraw

## excalidraw-down: stop the Excalidraw renderer sidecar
excalidraw-down:
	docker compose -f stack/docker-compose.yml --profile tools rm -sf excalidraw

## test-excalidraw: build and exercise the Excalidraw renderer sidecar
test-excalidraw:
	IMAGE=$(IMAGE) ./test/excalidraw-renderer.sh

## test-all: every suite that does not need a running production lease
test-all: test-legacy test-hardening test-broker test-guardrails test-worktree test-unsafe test-llama-config

# usage: make build-multi PUSH_IMAGE=registry.example.com/you/opencode-dev:2.1.4
## build-multi: build amd64+arm64 with SBOM/provenance and push (UID/GID 1000:1000)
build-multi:
	@test -n "$(PUSH_IMAGE)" || { \
		echo "error: build-multi needs PUSH_IMAGE=<registry>/<name>:<tag>"; \
		echo; \
		echo "A multi-arch manifest cannot be loaded into the local image store,"; \
		echo "so this target pushes instead. For local use, 'make build' on each host."; \
		exit 1; \
	}
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		$(PUBLISH_BUILD_ARGS) \
		$(LABELS) \
		--sbom=true \
		--provenance=mode=max \
		--push \
		-t $(PUSH_IMAGE) \
		.

## clean: remove the local image
clean:
	-docker image rm -f $(IMAGE)

## help: show available targets
help:
	@awk 'BEGIN {print "Targets:"} /^## / { s = substr($$0, 4); i = index(s, ": "); printf "  %-14s %s\n", substr(s, 1, i - 1), substr(s, i + 2) }' $(MAKEFILE_LIST)
