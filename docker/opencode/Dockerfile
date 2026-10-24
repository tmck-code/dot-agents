# syntax=docker/dockerfile:1.7

# OpenCode v2 dev image: Debian bookworm with Node.js and a uv-managed Python.
# Arch-neutral: the OpenCode installer picks linux-x64 or linux-arm64 itself.
ARG NODE_VERSION=24.22.1
ARG UV_VERSION=0.13.5

FROM node:${NODE_VERSION}-bookworm-slim AS node

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM debian:bookworm-slim

ARG OPENCODE_VERSION=2.1.4
ARG PYTHON_VERSION=3.13
ARG UID=1000
ARG GID=1000
ARG DEBIAN_FRONTEND=noninteractive

# Runtime and build toolchain. Several packages are needed to compile Python
# wheels that have no manylinux build for the target architecture.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      less \
      openssh-client \
      procps \
      ripgrep \
      unzip \
      xz-utils \
      build-essential \
      pkg-config \
      libssl-dev \
      libffi-dev \
      zlib1g-dev \
      libsqlite3-dev \
      libbz2-dev \
      libreadline-dev \
      liblzma-dev \
 && rm -rf /var/lib/apt/lists/*

# Node.js from the official image: binary, npm/corepack modules and headers.
# The npm/npx/corepack symlinks are recreated because COPY does not carry the
# ones from /usr/local/bin.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node /usr/local/include/node /usr/local/include/node
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
 && node --version \
 && npm --version

# uv, plus one managed CPython shared by the root build steps and the agent.
COPY --from=uv /uv /uvx /usr/local/bin/

ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1

RUN uv python install "${PYTHON_VERSION}" --no-bin \
 && PYTHON_BIN="$(uv python find "${PYTHON_VERSION}")" \
 && ln -sf "${PYTHON_BIN}" /usr/local/bin/python \
 && ln -sf "${PYTHON_BIN}" /usr/local/bin/python3 \
 && ln -sf "${PYTHON_BIN}" "/usr/local/bin/$(basename "${PYTHON_BIN}")" \
 && chmod -R a+rX /opt/uv \
 && python --version \
 && python3 --version

# OpenCode v2 via the official installer. npm would pull every platform
# variant (~916 MB); the installer downloads only this architecture's binary.
RUN curl -fsSL https://opencode.ai/v2/install -o /tmp/opencode-install.sh \
 && bash /tmp/opencode-install.sh --version "${OPENCODE_VERSION}" --no-modify-path \
 && mv /root/.opencode/bin/opencode /usr/local/bin/opencode \
 && rm -rf /root/.opencode /tmp/opencode-install.sh \
 && ln -s /usr/local/bin/opencode /usr/local/bin/opencode2 \
 && opencode --version

# Non-root user matching the host UID/GID. macOS reports GID 20 (staff), which
# is already "dialout" in Debian, so reuse the existing group name when the GID
# is taken. A taken UID is a hard error: pick another UID with `make build
# UID=...`.
RUN set -eux; \
    if getent group "${GID}" >/dev/null; then \
      GROUP_NAME="$(getent group "${GID}" | cut -d: -f1)"; \
    else \
      groupadd --gid "${GID}" agent; \
      GROUP_NAME=agent; \
    fi; \
    if getent passwd "${UID}" >/dev/null; then \
      echo "ERROR: UID ${UID} already exists in the image; rebuild with UID=<free uid>" >&2; \
      exit 1; \
    fi; \
    useradd --uid "${UID}" --gid "${GROUP_NAME}" \
            --create-home --home-dir /home/agent --shell /bin/bash agent; \
    mkdir -p \
      /home/agent/.local/bin \
      /home/agent/.local/share/opencode \
      /home/agent/.local/state/opencode \
      /home/agent/.config/opencode \
      /home/agent/.cache/opencode \
      /home/agent/.npm \
      /home/agent/.claude \
      /home/agent/.agents; \
    chown -R agent:"${GROUP_NAME}" /home/agent

# Bind-mounted repos are owned by the host user, which the container cannot
# resolve; without this git refuses them as "dubious ownership".
RUN git config --system --add safe.directory '*'

ENV HOME=/home/agent \
    NPM_CONFIG_PREFIX=/home/agent/.local \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8

LABEL org.opencontainers.image.title="OpenCode dev image" \
      org.opencontainers.image.description="OpenCode v2 with Node.js and a uv-managed Python" \
      org.opencontainers.image.source="https://github.com/tmck-code/dot-agents" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${OPENCODE_VERSION}" \
      dev.opencode.version="${OPENCODE_VERSION}" \
      dev.opencode.python.version="${PYTHON_VERSION}" \
      dev.opencode.uid="${UID}" \
      dev.opencode.gid="${GID}"

USER agent
WORKDIR /home/agent
ENTRYPOINT ["opencode"]
