#!/usr/bin/env bash
# Image hardening: non-root, no sudo, no embedded secrets, no host keys and a
# root-owned read-only system policy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
if [[ -e Dockerfile.new ]]; then
  echo "image-hardening: Dockerfile.new is obsolete and must not exist" >&2
  exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image-hardening: building $IMAGE" >&2
  make build
fi

echo "image-hardening: checking runtime user and filesystem"
docker run --rm --init --entrypoint bash "$IMAGE" -c '
  set -euo pipefail
  [[ "$(id -un)" == "agent" ]]
  [[ "$(id -u)" -ne 0 ]]
  command -v sudo >/dev/null && { echo "sudo must not be installed" >&2; exit 1; } || true
  [[ ! -e /home/agent/.ssh ]]
  [[ ! -e /home/agent/.config/gh ]]

  [[ -f /etc/opencode/opencode.jsonc ]]
  [[ "$(stat -c %U /etc/opencode/opencode.jsonc)" == "root" ]]
  [[ "$(stat -c %a /etc/opencode/opencode.jsonc)" == "444" ]]
  [[ "$(stat -c %U /etc/opencode/plugins/guard.ts)" == "root" ]]
  [[ "$(stat -c %a /etc/opencode/plugins/guard.ts)" == "444" ]]
  [[ ! -w /etc/opencode/opencode.jsonc ]]
  [[ ! -w /etc/opencode/plugins/guard.ts ]]

  # The git safe.directory wildcard is a launcher concern now, scoped to the
  # mounted repo rather than trusted system-wide.
  ! git config --system --get-all safe.directory 2>/dev/null | grep -qx "\*"
  git config --system --get-all safe.directory 2>/dev/null || true
'

echo "image-hardening: checking image config and history for secrets"
config="$(docker image inspect --format '{{json .Config}}' "$IMAGE")"
if grep -Eq '(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY)' <<<"$config"; then
  echo "image-hardening: secret-like value in image config" >&2
  exit 1
fi
history="$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE")"
if grep -Eq '(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY)' <<<"$history"; then
  echo "image-hardening: secret-like value in image history" >&2
  exit 1
fi

echo "image-hardening: ok"
