#!/usr/bin/env bash
# Provider root keys, the GitHub App private key and long-lived PATs must not
# appear in the agent's config or /proc/1/environ. A revoked virtual key must
# be rejected by LiteLLM.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
COMPOSE=(docker compose -f stack/docker-compose.yml)
# The stack reads per-service secret files; create any that are missing.
# shellcheck disable=SC1091
. stack/lib/secrets.sh
ensure_stack_secrets stack/secrets
export LEASE_ADMIN_TOKEN_FILE="$PWD/stack/secrets/broker-admin.token"

tmp="$(mktemp -d /tmp/opencode-no-secrets.XXXXXX)"
session_id="$(date -u +%Y%m%dT%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
export XDG_STATE_HOME="$tmp/state"
export CLAUDE_CONFIG_DIR="$tmp/claude"
export REPO_ROOT="$tmp/repo"

cleanup() {
  docker rm -f opencode-secrets-check >/dev/null 2>&1 || true
  # Session work/ files belong to the agent uid; only run.sh clean removes them.
  if [[ -d "$XDG_STATE_HOME/opencode/sessions/$session_id" ]]; then
    ./run.sh clean "$session_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp" 2>/dev/null || true
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "no-secrets: building $IMAGE" >&2
  make build
fi
"${COMPOSE[@]}" up -d --build --wait
# The key-generation key is registered with LiteLLM after the stack is up.
register_keygen_key stack/secrets/litellm-keygen.key

# Fake host Claude config: credential files that must not be staged, a skill
# that must be, and a settings.json with keys that must be stripped.
mkdir -p "$REPO_ROOT" "$CLAUDE_CONFIG_DIR/projects/x" "$CLAUDE_CONFIG_DIR/session-env/x" \
  "$CLAUDE_CONFIG_DIR/skills/s"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-marker"}}\n' > "$CLAUDE_CONFIG_DIR/.credentials.json"
printf '{"userID":"marker"}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
printf '{"prompt":"marker"}\n' > "$CLAUDE_CONFIG_DIR/history.jsonl"
printf 'marker\n' > "$CLAUDE_CONFIG_DIR/projects/x/t.jsonl"
printf 'marker\n' > "$CLAUDE_CONFIG_DIR/session-env/x/env"
printf '# s\n' > "$CLAUDE_CONFIG_DIR/skills/s/SKILL.md"
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{"model": "sonnet",
 "mcpServers": {"m": {"command": "x"}},
 "apiKeyHelper": "echo secret",
 "env": {"GITHUB_TOKEN": "ghp_settingsmarker", "FOO": "bar"}}
JSON
git -C "$REPO_ROOT" init -q -b main
git -C "$REPO_ROOT" config user.name "No Secrets"
git -C "$REPO_ROOT" config user.email "no-secrets@example.invalid"
git -C "$REPO_ROOT" commit -q --allow-empty -m init

# The Docker host may be rootful; safe mode then needs the explicit fence.
run_flags=()
security_options="$(docker info --format '{{.SecurityOptions}}' 2>/dev/null || true)"
if [[ "$security_options" != *name=rootless* && "$security_options" != *name=userns* ]]; then
  run_flags+=(--allow-rootful)
  export OPENCODE_I_ACCEPT_UNSAFE=1
fi

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
OPENCODE_SESSION_ID="$session_id" \
OPENCODE_DOCKER_ARGS="--name opencode-secrets-check" \
  ./run.sh "${run_flags[@]}" --shell -c 'sleep 30' >/dev/null 2>&1 &
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

echo "no-secrets: the staged Claude dir holds no credentials"
claude_exec() { docker exec opencode-secrets-check "$@"; }
for gone in .credentials.json .claude.json history.jsonl projects session-env; do
  if claude_exec test -e "/home/agent/.claude/$gone"; then
    echo "no-secrets: staged .claude contains $gone" >&2
    exit 1
  fi
done
claude_exec test -f /home/agent/.claude/skills/s/SKILL.md
staged_settings="$(claude_exec cat /home/agent/.claude/settings.json)"
for stripped in mcpServers apiKeyHelper; do
  if jq -e --arg key "$stripped" 'has($key)' <<<"$staged_settings" >/dev/null; then
    echo "no-secrets: staged settings.json kept $stripped" >&2
    exit 1
  fi
done
if jq -e '.env | has("GITHUB_TOKEN")' <<<"$staged_settings" >/dev/null; then
  echo "no-secrets: staged settings.json kept env.GITHUB_TOKEN" >&2
  exit 1
fi
[[ "$(jq -r '.env.FOO' <<<"$staged_settings")" == bar ]]
if grep -Fq -- 'sk-ant-oat-marker' <<<"$config$proc"; then
  echo "no-secrets: host Claude credentials reached the container environment" >&2
  exit 1
fi

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
