#!/usr/bin/env bash
# Guardrail regression suite: protected paths, external directories, explicit
# deny finality, proxy env injection, audit redaction and lease refresh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! node --experimental-strip-types --version >/dev/null 2>&1; then
  echo "guardrails: node with --experimental-strip-types is required (Node >= 22.6)" >&2
  exit 1
fi

node --experimental-strip-types ./test/plugin-harness.mjs
