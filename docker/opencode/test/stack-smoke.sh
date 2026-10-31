#!/usr/bin/env bash
# Start the local stack, wait for health, approve a lease, run the agent through
# the launcher and tear everything down.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
COMPOSE=(docker compose -f stack/docker-compose.yml)
export BROKER_ADMIN_TOKEN="${BROKER_ADMIN_TOKEN:-change-me}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-master}"
export LEASE_ADMIN_TOKEN="$BROKER_ADMIN_TOKEN"
export LEASE_ADMIN_URL="http://127.0.0.1:8081"

cleanup() {
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "stack-smoke: building $IMAGE" >&2
  make build
fi

mkdir -p stack/secrets
echo "stack-smoke: starting the stack"
"${COMPOSE[@]}" up -d --build --wait

echo "stack-smoke: approving a short lease"
lease_json="$(./bin/lease approve \
  --session "stack-smoke-$$" \
  --service all \
  --repo owner/repo \
  --model claude-sonnet \
  --ttl 10m \
  --no-write)"
LEASE_TOKEN="$(jq -r '.lease_token' <<<"$lease_json")"
[[ -n "$LEASE_TOKEN" && "$LEASE_TOKEN" != "null" ]]

echo "stack-smoke: checking the agent can reach the broker and proxy"
docker run --rm --init --network opencode-agent \
  --env "LEASE_TOKEN=$LEASE_TOKEN" \
  --entrypoint bash "$IMAGE" -c '
    set -euo pipefail
    curl -fsS -H "Authorization: Bearer $LEASE_TOKEN" \
      http://broker:8080/v1/leases/self >/dev/null
    curl -x http://squid:3128 -fsS --max-time 20 https://github.com -o /dev/null
    echo "agent network: broker and proxy reachable"
  '

echo "stack-smoke: running the agent through the hardened launcher"
LEASE_TOKEN="$LEASE_TOKEN" ./run.sh --shell -c 'opencode --version'

echo "stack-smoke: ok"
