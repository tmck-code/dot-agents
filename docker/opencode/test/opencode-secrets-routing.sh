#!/usr/bin/env bash
# Routing of scripts/opencode-secrets.sh with a stub keepassxc-cli on PATH.
# Uses temp dirs only. Asserts file names, bare values, modes, that other files
# are untouched, that --pem is rejected with sops, and that no secret value
# appears in any argv recorded by the stub.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
script="$PWD/scripts/opencode-secrets.sh"

tmp="$(mktemp -d /tmp/opencode-secrets-routing.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/keepassxc-cli" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"
read -r pw || true
[[ "$pw" == "stub-db-password" ]] || exit 1
cmd="$1"
case "$cmd" in
  show)
    entry="${*: -1}"
    case "$entry" in
      litellm/master) printf '%s\n' 'SECRET-master-value' ;;
      providers/openrouter) printf '%s\n' 'SECRET-openrouter-value' ;;
      github/app-id) printf '%s\n' '12345' ;;
      *) exit 1 ;;
    esac
    ;;
  attachment-export)
    out="${*: -1}"
    printf -- '-----BEGIN %s-----\nFAKE-pem-body\n-----END %s-----\n' 'TEST KEY' 'TEST KEY' > "$out"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$fakebin/keepassxc-cli"

export PATH="$fakebin:$PATH"
export FAKE_LOG="$tmp/argv.log"
export KEEPASSXC_PASSWORD="stub-db-password"
: > "$FAKE_LOG"
db="$tmp/stub.kdbx"
: > "$db"
out="$tmp/out"

fail() { echo "FAIL: $*" >&2; exit 1; }
mode_of() { stat -c '%a' "$1"; }
check_mode() { [[ "$(mode_of "$1")" == 600 ]] || fail "mode of $1 is $(mode_of "$1")"; }

# Pre-existing file that a non-merge run must not truncate.
mkdir -p "$out"
printf 'KEEP=me\n' > "$out/stack.env"

"$script" --source keepassxc --db "$db" --out "$out" \
  --entry LITELLM_MASTER_KEY=litellm/master \
  --entry OPENROUTER_API_KEY=providers/openrouter \
  --pem github/app:key.pem 2>/dev/null

[[ "$(cat "$out/litellm-master.key")" == "SECRET-master-value" ]] || fail 'litellm-master.key is not the bare value'
check_mode "$out/litellm-master.key"
[[ "$(cat "$out/litellm.env")" == "OPENROUTER_API_KEY=SECRET-openrouter-value" ]] || fail 'litellm.env content wrong'
check_mode "$out/litellm.env"
grep -q 'FAKE-pem-body' "$out/github-app.pem" || fail 'github-app.pem not written'
check_mode "$out/github-app.pem"
[[ "$(cat "$out/stack.env")" == "KEEP=me" ]] || fail 'stack.env was truncated or changed'
grep -rq 'SECRET-master-value' "$out/litellm.env" "$out/stack.env" && fail 'master key leaked into env file'
[[ ! -e "$out/broker-admin.token" ]] || fail 'unrequested broker-admin.token written'

grep -q 'attachment-export -q .*stub.kdbx github/app key.pem .*/github-app.pem' "$FAKE_LOG" || fail 'attachment-export argv wrong'

# Default attachment name.
: > "$FAKE_LOG"
"$script" --source keepassxc --db "$db" --out "$out" --pem github/app 2>/dev/null
grep -q 'github/app github-app.pem ' "$FAKE_LOG" || fail 'default attachment name not used'

# BROKER_ADMIN_TOKEN and a stack.env key route correctly.
"$script" --source keepassxc --db "$db" --out "$out" --merge \
  --entry BROKER_ADMIN_TOKEN=litellm/master --entry GITHUB_APP_ID=github/app-id 2>/dev/null
[[ "$(cat "$out/broker-admin.token")" == "SECRET-master-value" ]] || fail 'broker-admin.token wrong'
check_mode "$out/broker-admin.token"
grep -qx 'GITHUB_APP_ID=12345' "$out/stack.env" || fail 'GITHUB_APP_ID not in stack.env'
grep -qx 'KEEP=me' "$out/stack.env" || fail 'merge lost existing stack.env line'

# No secret value in any argv.
if grep -Eq 'SECRET|stub-db-password' "$FAKE_LOG"; then
  fail 'secret value found in recorded argv'
fi

# --pem with sops is rejected.
rc=0
"$script" --source sops --pem github/app --out "$tmp/out2" 2>/dev/null || rc=$?
[[ "$rc" -ne 0 ]] || fail '--pem with --source sops was accepted'

echo "opencode-secrets-routing: ok"
