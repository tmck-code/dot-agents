# syntax=docker/dockerfile:1.7

# OpenCode v2 dev image: Debian bookworm with Node.js and a uv-managed Python.
# Arch-neutral: the OpenCode installer picks linux-x64 or linux-arm64 itself.
#
# Base images are pinned by index digest so a rebuild cannot silently pick up a
# different tag. Refresh the digests deliberately, together with the version
# args, and re-run `make test`.
ARG NODE_VERSION=24.22.1
ARG NODE_DIGEST=sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205
ARG UV_VERSION=0.13.5
ARG UV_DIGEST=sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff
ARG DEBIAN_DIGEST=sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

FROM node:${NODE_VERSION}-bookworm-slim@${NODE_DIGEST} AS node

FROM ghcr.io/astral-sh/uv:${UV_VERSION}@${UV_DIGEST} AS uv

FROM debian:bookworm-slim@${DEBIAN_DIGEST}

ARG OPENCODE_VERSION=2.1.4
# Optional SHA-256 of the installed OpenCode binary. The official installer is
# fetched over HTTPS from opencode.ai and is pinned to OPENCODE_VERSION; when
# this arg is set the resulting binary is also checked against it. Set it in CI
# or a release build for a fully verified download:
#   make build OPENCODE_SHA256=<sha256>
ARG OPENCODE_SHA256=
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
      git-lfs \
      gnupg \
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

# Git LFS filter, installed system-wide so every user (including bind-mounted
# repos with lfs.* filters in ~/.gitconfig) resolves `git lfs` without running
# `git lfs install` per repo.
RUN git lfs install --system --skip-repo \
 && git lfs version

# GitHub CLI from GitHub's own apt repository (Debian bookworm does not package
# it). The real binary is renamed so the lease wrapper in /usr/local/bin can
# supply a short-lived lease token when one is available.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && mv /usr/bin/gh /usr/bin/gh-real \
 && /usr/bin/gh-real --version

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
# The installer is fetched over HTTPS from opencode.ai, pinned to
# OPENCODE_VERSION, and run without piping to a shell. When OPENCODE_SHA256 is
# supplied the resulting binary is verified before it is installed; CI and
# release builds should always set it.
RUN set -eux; \
    curl -fsSL --proto '=https' --tlsv1.2 \
      https://opencode.ai/v2/install -o /tmp/opencode-install.sh; \
    bash /tmp/opencode-install.sh --version "${OPENCODE_VERSION}" --no-modify-path; \
    if [ -n "${OPENCODE_SHA256}" ]; then \
      echo "${OPENCODE_SHA256}  /root/.opencode/bin/opencode" | sha256sum -c -; \
    else \
      echo "warning: OPENCODE_SHA256 is unset; trusting the pinned official installer over HTTPS" >&2; \
    fi; \
    mv /root/.opencode/bin/opencode /usr/local/bin/opencode; \
    rm -rf /root/.opencode /tmp/opencode-install.sh; \
    ln -s /usr/local/bin/opencode /usr/local/bin/opencode2; \
    opencode --version

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

# System OpenCode policy and plugins. Root-owned and not writable by the agent,
# so neither the agent nor a project can re-enable a denied provider or tool.
COPY --chown=root:root config/opencode.jsonc /etc/opencode/opencode.jsonc
COPY --chown=root:root config/plugins/ /etc/opencode/plugins/
RUN chmod 0755 /etc/opencode /etc/opencode/plugins \
 && chmod 0444 /etc/opencode/opencode.jsonc \
 && chmod 0444 /etc/opencode/plugins/*.ts

# Lease-aware git/gh helpers. They are inert without BROKER_URL and
# LEASE_TOKEN, so `--unsafe` mode still falls back to mounted host credentials.
COPY --chown=root:root bin/git-credential-lease /usr/local/bin/git-credential-lease
COPY --chown=root:root bin/git-askpass-lease /usr/local/bin/git-askpass-lease
COPY --chown=root:root bin/gh-lease /usr/local/bin/gh
RUN chmod 0755 /usr/local/bin/git-credential-lease \
             /usr/local/bin/git-askpass-lease \
             /usr/local/bin/gh

# Bind-mounted repos are owned by the host user, which the container cannot
# resolve. The launcher scopes safe.directory to the mounted repo with
# GIT_CONFIG_* instead of trusting every path system-wide.

ENV HOME=/home/agent \
    NPM_CONFIG_PREFIX=/home/agent/.local \
    PATH=/home/agent/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    OPENCODE_SYSTEM_CONFIG=/etc/opencode/opencode.jsonc \
    OPENCODE_SYSTEM_PLUGINS=/etc/opencode/plugins

LABEL org.opencontainers.image.title="OpenCode dev image" \
      org.opencontainers.image.description="Hardened OpenCode v2 with Node.js, a uv-managed Python, git, gh and git-lfs" \
      org.opencontainers.image.source="https://github.com/tmck-code/dot-agents" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${OPENCODE_VERSION}" \
      dev.opencode.version="${OPENCODE_VERSION}" \
      dev.opencode.python.version="${PYTHON_VERSION}" \
      dev.opencode.uid="${UID}" \
      dev.opencode.gid="${GID}" \
      dev.opencode.hardened="true"

USER agent
WORKDIR /home/agent
ENTRYPOINT ["opencode"]
