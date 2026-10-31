#!/usr/bin/env bash
# Legacy baseline: the image still provides the toolchain agents expect.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "legacy-smoke: building $IMAGE" >&2
  make build
fi

docker run --rm --init --entrypoint bash "$IMAGE" -c '
  set -euo pipefail
  test "$(id -u)" -ne 0
  opencode --version
  python --version
  node --version
  npm --version
  git --version
  gh --version
  git lfs version
  uv --version
'
echo "legacy-smoke: ok"
