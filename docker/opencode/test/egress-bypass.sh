#!/usr/bin/env bash
# Egress bypass suite. Run from the agent network: direct egress, host services
# and metadata must fail; the allowlisted proxy path must work.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
COMPOSE=(docker compose -f stack/docker-compose.yml)
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "egress-bypass: building $IMAGE" >&2
  make build
fi

if ! docker network inspect opencode-agent >/dev/null 2>&1; then
  echo "egress-bypass: starting the proxy" >&2
  "${COMPOSE[@]}" up -d squid
fi
for _ in $(seq 1 30); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' opencode-squid 2>/dev/null || true)"
  [[ "$status" == "healthy" ]] && break
  sleep 1
done
[[ "${status:-}" == "healthy" ]] || { echo "egress-bypass: squid is not healthy" >&2; exit 1; }

agent() {
  docker run --rm --init --network opencode-agent --entrypoint bash "$IMAGE" -c "$1"
}

expect_fail() {
  local name="$1" command="$2"
  if agent "$command" >/dev/null 2>&1; then
    echo "egress-bypass: $name unexpectedly succeeded" >&2
    exit 1
  fi
  echo "egress-bypass: $name blocked"
}

echo "egress-bypass: direct internet"
expect_fail "direct HTTPS" 'curl -fsS --max-time 5 https://github.com -o /dev/null'

echo "egress-bypass: host services"
expect_fail "host.docker.internal" 'curl -fsS --max-time 3 http://host.docker.internal:80 -o /dev/null'
expect_fail "host LAN gateway" 'curl -fsS --max-time 3 http://172.17.0.1:22 -o /dev/null'

echo "egress-bypass: metadata"
expect_fail "cloud metadata" 'curl -fsS --max-time 3 http://169.254.169.254/latest/meta-data/ -o /dev/null'

echo "egress-bypass: allowlisted domain through the proxy"
agent 'curl -x http://squid:3128 -fsS --max-time 20 https://github.com -o /dev/null'
echo "egress-bypass: github allowed"

echo "egress-bypass: denied domain through the proxy"
expect_fail "unlisted domain" 'curl -x http://squid:3128 -fsS --max-time 10 https://example.com -o /dev/null'

echo "egress-bypass: ok"
