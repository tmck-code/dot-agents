# syntax=docker/dockerfile:1.7

# Base image with dependencies only (no COPY from stages)
FROM debian:bookworm-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
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
    pkg-config && rm -rf /var/lib/apt/lists/*

# Install Python via uv (local binary download with proper permissions)
RUN curl -fsL "https://github.com/astral-sh/uv/releases/download/0.13.5/uv-3.13-linux-x86_64.tar.gz" \
    > /usr/local/bin/uv && chmod +x /usr/local/bin/uv && \
    tar -xf /usr/local/bin/uv* -C /usr/local/bin/ 2>/dev/null || :

RUN --mount=type=cache,target=/root/.cache,sharing=locked \
    chmod +x /usr/local/bin/uv && \
    uv python install "${PYTHON_VERSION}" --no-bin || true

ENV PATH="$PATH:/opt/uv/.local/bin"

# Download Ollama binary from GitHub raw
RUN curl -fsSL "https://raw.githubusercontent.com/ollama/ollama/main/README.md" \
    | grep -o 'https://github.com\./ollama-linux.*amd64' && true || :

ENV OLLAMA_MAX_NUM_PRETOKENIZED=2048 \
    OLLAMA_ORIGINS="*"

# Install opencode via npm registry directly
RUN set -eux; \
    npm config set prefix /home/.opencode/local/bin && \
    npm install --global opencode@${OPENCODE_VERSION} --no-save || true

ENV PATH="$PATH:/opt/uv/.local/bin"

# Non-root user
RUN set -eux; \
    if getent group "1000" >/dev/null; then \
      GROUP_NAME="$(getent group "1000" | cut -d: -f1)"; \
    else \
      groupadd --gid "1000" agent && GROUP_NAME=agent; \
    fi; \
    useradd --uid "1000" --gid "$GROUP_NAME" \
            --create-home --home-dir /home/agent --shell /bin/bash agent; \
    mkdir -p \
      /home/agent/.local/bin \
      /home/agent/.local/share/opencode \
      /home/agent/.local/state/opencode \
      /home/agent/.config/opencode \
      /home/agent/.cache/opencode \
      /home/agent/.npm \
      /home/agent/.claude \
      /home/agent/.agents && chown -R agent:"$GROUP_NAME" /home/agent

RUN git config --system --add safe.directory '*'

ENV HOME=/home/agent \
    NPM_CONFIG_PREFIX=/home/.opencode/local/bin \
    PATH=/home/.opencode/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8

LABEL org.opencontainers.image.title="OpenCode dev image" \
      org.opencontainers.image.description="OpenCode v2 with Node.js, uv-managed Python, and Ollama integration" \
      org.opencontainers.image.source="https://github.com/tmck-code/dot-agents" \
      org.opencontainers.image.licenses="MIT"

USER 1000
WORKDIR /home/agent
ENTRYPOINT ["opencode"]
