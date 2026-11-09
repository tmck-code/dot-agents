#!/usr/bin/env bash
# Static checks for compose secrets, resource limits and broker networking.
# No running stack needed. The compose file is rendered from a temporary copy
# with dummy secret files, so stack/secrets/ is never touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "stack-secrets: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stack/secrets" "$tmp/broker" "$tmp/tools/excalidraw-renderer"
cp stack/docker-compose.yml stack/squid.conf stack/litellm.yaml "$tmp/stack/"
for name in github-app.pem litellm-keygen.key broker-admin.token litellm-master.key \
    litellm.env postgres-password llama-api-key; do
  echo dummy >"$tmp/stack/secrets/$name"
done

rendered="$(docker compose -f "$tmp/stack/docker-compose.yml" --profile llama --profile tools \
  config --format json)"

# Per-service secret grants (design Decision 2).
declare -A expected=(
  [broker]="github_app_pem litellm_keygen_key"
  [broker-admin]="broker_admin_token litellm_keygen_key"
  [litellm]="litellm_env litellm_master_key llama_api_key postgres_password"
  [postgres]="postgres_password"
  [llama]="llama_api_key"
  [squid]=""
  [excalidraw]=""
)
for service in "${!expected[@]}"; do
  actual="$(jq -r --arg s "$service" \
    '[.services[$s].secrets // [] | .[].source] | sort | join(" ")' <<<"$rendered")"
  [[ "$actual" == "${expected[$service]}" ]] \
    || fail "$service secrets are '$actual', expected '${expected[$service]}'"
done

# No service may mount the secrets directory.
jq -e '[.services[].volumes // [] | .[] | select(.source // "" | test("/secrets$"))] | length == 0' \
  >/dev/null <<<"$rendered" || fail "a service mounts ./secrets"
jq -e '[.services[].volumes // [] | .[] | select(.target == "/run/secrets")] | length == 0' \
  >/dev/null <<<"$rendered" || fail "a service mounts a directory at /run/secrets"

# No secret value or secret-bearing variable in any environment.
jq -e '[.services[].environment // {} | keys[]
        | select(. == "BROKER_ADMIN_TOKEN" or . == "LITELLM_MASTER_KEY"
                 or . == "LLAMA_API_KEY" or . == "POSTGRES_PASSWORD"
                 or . == "LITELLM_DATABASE_URL")] | length == 0' \
  >/dev/null <<<"$rendered" || fail "a secret-bearing variable is set in an environment"

# Broker: only opencode-agent, and GitHub traffic goes through Squid.
jq -e '.services.broker.networks | keys == ["opencode-agent"]' >/dev/null <<<"$rendered" \
  || fail "broker networks must be exactly [opencode-agent]"
jq -e '.services.broker.environment.HTTPS_PROXY == "http://squid:3128"
       and (.services.broker.environment.NO_PROXY | split(",") | index("litellm") != null)' \
  >/dev/null <<<"$rendered" || fail "broker must use Squid and bypass it for litellm"
jq -e '.services.broker.depends_on.squid.condition == "service_healthy"' \
  >/dev/null <<<"$rendered" || fail "broker must depend on squid"
jq -e '(.services["broker-admin"].environment | has("HTTPS_PROXY")) | not' \
  >/dev/null <<<"$rendered" || fail "broker-admin must not use the proxy"
jq -e '.services["broker-admin"].environment.BROKER_ADMIN_TOKEN_FILE == "/run/secrets/broker_admin_token"
       and (.services.broker.environment | has("BROKER_ADMIN_TOKEN_FILE") | not)' \
  >/dev/null <<<"$rendered" || fail "BROKER_ADMIN_TOKEN_FILE must be set on broker-admin only"

# Egress network is pinned.
jq -e '.networks["opencode-egress"].ipam.config[0].subnet == "172.31.250.0/24"' \
  >/dev/null <<<"$rendered" || fail "opencode-egress subnet is not pinned"

# Resource limits on every service.
missing="$(jq -r '.services | to_entries[]
  | select((.value.pids_limit // 0) == 0 or (.value.mem_limit // 0) == 0 or (.value.cpus // 0) == 0)
  | .key' <<<"$rendered")"
[[ -z "$missing" ]] || fail "missing pids_limit, mem_limit or cpus: $missing"

# Removed defaults.
if grep -q -e 'litellm-local' -e 'sk-llama-local' <<<"$rendered"; then
  fail "litellm-local or sk-llama-local still appears"
fi

echo "stack-secrets: ok"
