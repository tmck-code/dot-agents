#!/usr/bin/env bash
# Shared secret handling for stack/online.sh and stack/llama.sh. Source it; do
# not run it. Each generated secret is one file holding one bare value. Compose
# grants each file only to the services that need it (design Decision 2).

# Create <path> holding <prefix> plus 64 random hex characters. An existing file
# is never changed. The file is created with mode 0600 and has no trailing
# newline, so every reader gets the exact value.
ensure_secret_file() {
  local path="$1" prefix="${2:-}"
  [[ -e "$path" ]] && return 0
  (
    umask 077
    set -C
    printf '%s%s' "$prefix" "$(openssl rand -hex 32)" > "$path"
  ) 2>/dev/null || [[ -e "$path" ]] || {
    echo "secrets: cannot create $path" >&2
    return 1
  }
  chmod 600 "$path"
}

# Move one KEY=value line from <env_file> into <target> (bare value), once.
# Runs only when <target> is missing. Only the migrated line is deleted.
_migrate_env_secret() {
  local env_file="$1" key="$2" target="$3" line value
  [[ -f "$env_file" && ! -e "$target" ]] || return 0
  line="$(grep -m1 "^${key}=" "$env_file" || true)"
  [[ -n "$line" ]] || return 0
  value="${line#"${key}="}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  if [[ -n "$value" ]]; then
    (umask 077; printf '%s' "$value" > "$target")
    chmod 600 "$target"
  fi
  sed -i "/^${key}=/d" "$env_file"
  echo "secrets: moved $key from $env_file to $target" >&2
}

# Create <path> as an empty file with mode 0600 when it is missing. Used for
# user-provided files that compose mounts: compose fails if the file is absent.
# An existing file is never changed.
ensure_empty_file() {
  local path="$1"
  [[ -e "$path" ]] && return 0
  (umask 077; : > "$path")
  chmod 600 "$path"
}

# Create the secrets directory (0700), any missing generated secret file, and an
# empty placeholder for each user-provided file (litellm.env, github-app.pem).
ensure_stack_secrets() {
  local dir="$1"
  # Secret files belong to the invoking user; compose runs the broker as that user.
  export OPENCODE_UID="${OPENCODE_UID:-$(id -u)}" OPENCODE_GID="${OPENCODE_GID:-$(id -g)}"
  mkdir -p "$dir" "$dir/services"
  chmod 700 "$dir" "$dir/services"

  _migrate_env_secret "$dir/stack.env" BROKER_ADMIN_TOKEN "$dir/broker-admin.token"
  _migrate_env_secret "$dir/stack.env" LITELLM_MASTER_KEY "$dir/litellm-master.key"

  ensure_secret_file "$dir/broker-admin.token" ''
  ensure_secret_file "$dir/litellm-master.key" 'sk-'
  ensure_secret_file "$dir/litellm-keygen.key" 'sk-'
  ensure_secret_file "$dir/postgres-password" ''
  ensure_secret_file "$dir/llama-api-key" 'sk-'
  ensure_empty_file "$dir/litellm.env"
  ensure_empty_file "$dir/github-app.pem"
}

# Refuse an OPENCODE_EGRESS_SUBNET that is not inside 10/8, 172.16/12 or
# 192.168/16. An unset value is accepted: compose uses its default.
validate_egress_subnet() {
  local subnet="${OPENCODE_EGRESS_SUBNET:-}" ip len a b c d n net
  [[ -n "$subnet" ]] || return 0
  if [[ ! "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
    echo "OPENCODE_EGRESS_SUBNET must look like 172.31.250.0/24, got: $subnet" >&2
    return 1
  fi
  a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
  d="${BASH_REMATCH[4]}" len="${BASH_REMATCH[5]}"
  for n in "$a" "$b" "$c" "$d"; do
    ((10#$n <= 255)) || { echo "OPENCODE_EGRESS_SUBNET has an invalid octet: $subnet" >&2; return 1; }
  done
  ((10#$len <= 32)) || { echo "OPENCODE_EGRESS_SUBNET has an invalid prefix: $subnet" >&2; return 1; }
  ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
  # range start, range prefix length: 10/8, 172.16/12, 192.168/16
  local start plen
  for net in "167772160 8" "2886729728 12" "3232235520 16"; do
    read -r start plen <<<"$net"
    if ((10#$len >= plen)) && (( (ip >> (32 - plen)) == (start >> (32 - plen)) )); then
      return 0
    fi
  done
  echo "OPENCODE_EGRESS_SUBNET must be inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16, got: $subnet" >&2
  return 1
}

# Register the broker's scoped key-generation key with LiteLLM, once. LiteLLM
# runs the check and the registration inside its own container. The master key
# is read from LiteLLM's secret file there. The keygen key is sent on stdin from
# the host file, so neither value appears in any argv.
register_keygen_key() {
  local keygen_file="$1"
  [[ -s "$keygen_file" ]] || { echo "secrets: missing $keygen_file" >&2; return 1; }
  local code
  read -r -d '' code <<'PY' || true
import json, sys, urllib.error, urllib.request

BASE = 'http://127.0.0.1:4000'
ROUTES = ['/key/generate', '/key/delete', '/key/info']
keygen = sys.stdin.read().strip()
master = open('/run/secrets/litellm_master_key').read().strip()


def call(method, path, key, body=None):
    req = urllib.request.Request(
        BASE + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status
    except urllib.error.HTTPError as err:
        return err.code


if call('GET', '/key/info', keygen) == 200:
    sys.exit(0)
# 401 or 404: not registered yet. The owner user may already exist, so its
# creation result is not checked.
call('POST', '/user/new', master, {'user_id': 'opencode-broker-keygen', 'user_role': 'proxy_admin'})
status = call('POST', '/key/generate', master, {
    'key': keygen,
    'key_alias': 'opencode-broker-keygen',
    'user_id': 'opencode-broker-keygen',
    'allowed_routes': ROUTES,
})
if status != 200:
    print('keygen registration failed: HTTP %d' % status, file=sys.stderr)
    sys.exit(1)
PY
  docker exec -i opencode-litellm python -c "$code" < "$keygen_file"
}
