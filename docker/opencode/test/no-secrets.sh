#!/usr/bin/env bash
# Provider root keys, the GitHub App private key and long-lived PATs must not
# appear in the agent's config or /proc/1/environ. A revoked virtual key must
# be rejected by LiteLLM.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
COMPOSE=(docker compose -f stack/docker-compose.yml)
export BROKER_ADMIN_TOKEN="${BROKER_ADMIN_TOKEN:-change-me}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-master}"
export LEASE_ADMIN_TOKEN="$BROKER_ADMIN_TOKEN"

cleanup() {
  docker rm -f opencode-secrets-check >/dev/null 2>&1 || true
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "no-secrets: building $IMAGE" >&2
  make build
fi
mkdir -p stack/secrets
"${COMPOSE[@]}" up -d --wait

lease_json="$(./bin/lease approve \
  --session "no-secrets-$$" \
  --service all \
  --repo owner/repo \
  --model claude-sonnet \
  --ttl 10m \
  --no-write)"
LEASE_TOKEN="$(jq -r '.lease_token' <<<"$lease_json")"
LEASE_ID="$(jq -r '.lease_id' <<<"$lease_json")"

root_key="sk-ant-root-$(printf 'Z%.0s' {1..32})"
pat="ghp_$(printf 'A%.0s' {1..32})"
app_key_marker="BEGIN RSA PRIVATE KEY SHOULD NOT APPEAR"

echo "no-secrets: starting an agent with host root secrets exported"
ANTHROPIC_API_KEY="$root_key" \
OPENAI_API_KEY="$root_key" \
GITHUB_TOKEN="$pat" \
GH_TOKEN="$pat" \
GITHUB_APP_PRIVATE_KEY="$app_key_marker" \
LEASE_TOKEN="$LEASE_TOKEN" \
OPENCODE_DOCKER_ARGS="--name opencode-secrets-check" \
  ./run.sh --shell -c 'sleep 30' >/dev/null 2>&1 &
launcher_pid=$!

for _ in $(seq 1 30); do
  if docker inspect opencode-secrets-check >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! docker inspect opencode-secrets-check >/dev/null 2>&1; then
  echo "no-secrets: agent container did not start" >&2
  kill "$launcher_pid" 2>/dev/null || true
  exit 1
fi

config="$(docker inspect --format '{{json .Config.Env}}' opencode-secrets-check)"
proc="$(docker exec opencode-secrets-check cat /proc/1/environ | tr '\0' '\n')"
for forbidden in "$root_key" "$pat" "$app_key_marker"; do
  if grep -Fq -- "$forbidden" <<<"$config$proc"; then
    echo "no-secrets: forbidden secret reached the agent" >&2
    exit 1
  fi
done
grep -q '^LITELLM_API_KEY=' <<<"$proc"

echo "no-secrets: revoking the lease"
./bin/lease revoke "$LEASE_ID" >/dev/null

echo "no-secrets: revoked lease and virtual key are rejected"
agent_network_curl() {
  docker run --rm --init --network opencode-agent --entrypoint bash "$IMAGE" -c "$1"
}
if agent_network_curl "curl -fsS -H 'Authorization: Bearer $LEASE_TOKEN' http://broker:8080/v1/token/litellm -o /dev/null"; then
  echo "no-secrets: revoked lease still minted a key" >&2
  exit 1
fi

docker rm -f opencode-secrets-check >/dev/null 2>&1 || true
wait "$launcher_pid" 2>/dev/null || true

echo "no-secrets: ok"
