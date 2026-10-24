IMAGE ?= opencode-dev:local
OPENCODE_VERSION ?= 2.1.4
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

BUILD_ARGS = \
	--build-arg UID=$(UID) \
	--build-arg GID=$(GID) \
	--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION)

PUBLISH_BUILD_ARGS = \
	--build-arg UID=$(PUBLISH_UID) \
	--build-arg GID=$(PUBLISH_GID) \
	--build-arg OPENCODE_VERSION=$(OPENCODE_VERSION) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION)

.PHONY: build run shell test build-multi clean help

## build: build for this host's architecture and load it into Docker
build:
	docker buildx build --load --platform $(HOST_PLATFORM) $(BUILD_ARGS) -t $(IMAGE) .

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

# usage: make build-multi PUSH_IMAGE=registry.example.com/you/opencode-dev:2.1.4
## build-multi: build amd64+arm64 and push as UID/GID 1000:1000 (multi-arch cannot be --load-ed)
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
		--push \
		-t $(PUSH_IMAGE) \
		.

## clean: remove the local image
clean:
	-docker image rm -f $(IMAGE)

## help: show available targets
help:
	@awk 'BEGIN {print "Targets:"} /^## / { s = substr($$0, 4); i = index(s, ": "); printf "  %-12s %s\n", substr(s, 1, i - 1), substr(s, i + 2) }' $(MAKEFILE_LIST)
