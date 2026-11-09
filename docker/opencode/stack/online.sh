#!/usr/bin/env bash
# One-command online-model workflow for the hardened OpenCode stack.
#
# Starts the base stack (Squid, broker, LiteLLM, Postgres) without the optional
# llama profile, then approves a LiteLLM lease for an online model. No GGUF or
# GPU is needed. A missing provider key is read from KeePassXC on the host when
# ~/.secrets.kdbx exists; the key is written only to the host-side
# stack/secrets/litellm.env, which compose grants to the litellm service alone,
# never to the agent container. Generated secrets (broker-admin.token,
# litellm-master.key, litellm-keygen.key, postgres-password, llama-api-key) are
# created on first run, one file each, and are never overwritten.
#
#   ./stack/online.sh up        # start the stack and approve a lease
#   ./stack/online.sh lease     # approve another lease
#   ./stack/online.sh status    # show the stack containers
#   ./stack/online.sh logs      # follow LiteLLM logs
#   ./stack/online.sh down      # stop the stack, keep named volumes
#
# Environment:
#   OPENCODE_MODEL      OpenCode model id (default: litellm/deepseek-chat).
#                       The lease uses the alias after the provider prefix.
#   OPENCODE_MODEL_TTL  Lease TTL (default: 8h).
#   OPENCODE_SESSION    Lease session name (default: $USER-online).
#   LEASE_ADMIN_TOKEN_FILE  Set to stack/secrets/broker-admin.token by this script.
#   OPENCODE_SESSION_ID     Lease session id; used before OPENCODE_SESSION when set.
#   OPENCODE_EGRESS_SUBNET  Egress network subnet; must be inside 10/8, 172.16/12
#                           or 192.168/16.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE=(docker compose -f stack/docker-compose.yml)
command_name="${1:-up}"
shift || true

MODEL_ID="${OPENCODE_MODEL:-litellm/deepseek-chat}"
MODEL_ALIAS="${MODEL_ID#*/}"
TTL="${OPENCODE_MODEL_TTL:-8h}"

# Optional KeePassXC fallback for provider keys. The database password itself is
# never accepted on the command line: use KEEPASSXC_PASSWORD or the interactive
# prompt, exactly like scripts/opencode-secrets.sh.
KEEPASS_DB="${KEEPASSXC_DB:-$HOME/.secrets.kdbx}"
KEEPASS_ENTRY="${KEEPASSXC_ENTRY:-}"
USE_KEEPASS=1
SECRETS_SCRIPT="../../scripts/opencode-secrets.sh"

die() { echo "online: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: online.sh <command> [options]

Commands:
  up        Start the base stack and approve a lease for an online model
  lease     Approve another lease against an already-running stack
  status    Show the stack containers
  logs      Follow LiteLLM logs
  down      Stop the stack; named volumes are left intact

Options (up/lease):
  --model ID               OpenCode model id (default litellm/deepseek-chat)
  --ttl DURATION           Lease TTL (default 8h)
  --keepass-db PATH        KeePassXC database (default ~/.secrets.kdbx)
  --keepass-entry ENTRY    Entry path; defaults to the provider key name
  --no-keepass             Do not try to resolve a missing key from KeePassXC

Environment:
  OPENCODE_MODEL (default litellm/deepseek-chat), OPENCODE_MODEL_TTL (default 8h),
  OPENCODE_SESSION, OPENCODE_SESSION_ID, OPENCODE_EGRESS_SUBNET, KEEPASSXC_DB,
  KEEPASSXC_ENTRY, KEEPASSXC_PASSWORD

A missing provider key is looked up in KeePassXC when the database exists. The
entry's password field is written to stack/secrets/litellm.env (mode 0600), a
file only the litellm service can read. It is never printed, exported to the
agent, or passed on a command line.
EOF
}

ensure_stack_env() {
  # shellcheck disable=SC1091
  . stack/lib/secrets.sh
  validate_egress_subnet || exit 1
  ensure_stack_secrets stack/secrets
  if [[ -f stack/secrets/stack.env ]]; then
    set -a
    # shellcheck disable=SC1091
    . stack/secrets/stack.env
    set +a
  fi
  export LEASE_ADMIN_TOKEN_FILE="$PWD/stack/secrets/broker-admin.token"
}

provider_key_for_model() {
  case "$1" in
    claude-*) printf 'ANTHROPIC_API_KEY' ;;
    gpt-*) printf 'OPENAI_API_KEY' ;;
    deepseek-*) printf 'DEEPSEEK_API_KEY' ;;
    *) printf '' ;;
  esac
}

provider_key_available() {
  local var="$1" file="stack/secrets/litellm.env"
  [[ -n "$var" ]] || return 0
  [[ -f "$file" ]] && grep -q "^${var}=..*" "$file"
}

resolve_keepass_key() {
  local var="$1" entry
  (( USE_KEEPASS )) || return 1
  [[ -f "$KEEPASS_DB" ]] || return 1

  command -v keepassxc-cli >/dev/null 2>&1 || {
    echo "online: keepassxc-cli is not installed; cannot read $KEEPASS_DB" >&2
    return 1
  }
  [[ -x "$SECRETS_SCRIPT" ]] || {
    echo "online: secret resolver not found: $SECRETS_SCRIPT" >&2
    return 1
  }

  entry="${KEEPASS_ENTRY:-$var}"
  echo "online: resolving $var from KeePassXC ($KEEPASS_DB entry '$entry')" >&2
  "$SECRETS_SCRIPT" --source keepassxc --db "$KEEPASS_DB" \
    --entry "$var=$entry" --merge
}

ensure_provider_key() {
  local var
  var="$(provider_key_for_model "$MODEL_ALIAS")"
  [[ -n "$var" ]] || return 0

  if provider_key_available "$var"; then
    return 0
  fi
  if resolve_keepass_key "$var" && provider_key_available "$var"; then
    return 0
  fi

  local keepass_hint
  if (( USE_KEEPASS )); then
    keepass_hint="KeePassXC was tried at $KEEPASS_DB with entry '${KEEPASS_ENTRY:-$var}'.
Override it with --keepass-db PATH, --keepass-entry ENTRY, or KEEPASSXC_DB /
KEEPASSXC_ENTRY. Use --no-keepass to skip the lookup."
  else
    keepass_hint="KeePassXC lookup is disabled (--no-keepass)."
  fi

  cat >&2 <<EOF
online: $MODEL_ALIAS needs $var, but it is not set.

Put it in stack/secrets/litellm.env (mode 0600):
  printf '%s=%s\n' '$var' 'your-key' >> stack/secrets/litellm.env

Or resolve it with scripts/opencode-secrets.sh, which writes that file:
  ./scripts/opencode-secrets.sh --source sops --file secrets.enc.yaml \\
      --keys GITHUB_APP_ID,BROKER_ADMIN_TOKEN,LITELLM_MASTER_KEY,$var

$keepass_hint
EOF
  exit 1
}

parse_options() {
  while (($#)); do
    case "$1" in
      --model) MODEL_ID="${2:?--model needs a value}"; MODEL_ALIAS="${MODEL_ID#*/}"; shift 2 ;;
      --ttl) TTL="${2:?--ttl needs a value}"; shift 2 ;;
      --keepass-db) KEEPASS_DB="${2:?--keepass-db needs a value}"; shift 2 ;;
      --keepass-entry) KEEPASS_ENTRY="${2:?--keepass-entry needs a value}"; shift 2 ;;
      --no-keepass) USE_KEEPASS=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done
}

approve_lease() {
  local session="${OPENCODE_SESSION_ID:-${OPENCODE_SESSION:-${USER:-agent}-online}}"
  echo "online: approving a $MODEL_ALIAS lease (session=$session ttl=$TTL)"
  ./bin/lease approve \
    --session "$session" \
    --service litellm \
    --model "$MODEL_ALIAS" \
    --ttl "$TTL"
  cat <<EOF

online: stack is ready.
  OpenCode model: $MODEL_ID
  Launch with:    make run
  If the TUI uses another model, run: /model $MODEL_ID
EOF
}

cmd_up() {
  parse_options "$@"
  ensure_stack_env
  ensure_provider_key
  echo "online: starting the base stack (no llama profile)"
  "${BASE[@]}" up -d --build --wait
  register_keygen_key stack/secrets/litellm-keygen.key
  approve_lease
}

cmd_lease() {
  parse_options "$@"
  ensure_stack_env
  ensure_provider_key
  approve_lease
}

cmd_status() {
  "${BASE[@]}" ps
}

cmd_logs() {
  "${BASE[@]}" logs -f litellm
}

cmd_down() {
  "${BASE[@]}" down --remove-orphans
  echo "online: stopped; named volumes are unchanged"
}

case "$command_name" in
  up) cmd_up "$@" ;;
  lease) cmd_lease "$@" ;;
  status) cmd_status "$@" ;;
  logs) cmd_logs "$@" ;;
  down) cmd_down "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $command_name (try --help)" ;;
esac
