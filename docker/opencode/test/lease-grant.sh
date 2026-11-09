#!/usr/bin/env bash
# lease grant / ungrant with stub curl and keepassxc-cli on PATH.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/bin"
mkdir -p "$fakebin" "$tmp/services" "$tmp/state"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The stub records argv and the body file; it answers 200 with a grant.
cat > "$fakebin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_DIR/argv"
out=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; esac
  case "$a" in @*) ;; esac
  prev="$a"
done
for a in "$@"; do
  case "$a" in @*) cp "${a#@}" "$STUB_DIR/body" ;; esac
done
printf '{"lease_id":"lse_1","service":"excalidraw","values":{"TOKEN":"leak"}}' > "$out"
printf '%s' "${STUB_CODE:-200}"
STUB
cat > "$fakebin/keepassxc-cli" <<'STUB'
#!/usr/bin/env bash
cat > "$STUB_DIR/kp-stdin"
printf '%s\n' "$@" > "$STUB_DIR/kp-argv"
echo "kp-secret-value"
STUB
chmod +x "$fakebin/curl" "$fakebin/keepassxc-cli"
: > "$tmp/db.kdbx"

export STUB_DIR="$tmp"
export PATH="$fakebin:$PATH"
export LEASE_ADMIN_TOKEN="admin-tok"
export LEASE_SERVICES_DIR="$tmp/services"
export XDG_STATE_HOME="$tmp/state"
export KEEPASSXC_DB="$tmp/db.kdbx"
export KEEPASSXC_PASSWORD="dbpass-value"
lease="$root/bin/lease"

# --file path
printf 'TOKEN=file-secret-abc\n# comment\nOTHER=a=b\n' > "$tmp/custom.env"
out="$("$lease" grant lse_1 excalidraw --ttl 30m --file "$tmp/custom.env")"
[[ "$(jq -r .service "$tmp/body")" == excalidraw ]] || fail "body service"
[[ "$(jq -r .ttl_seconds "$tmp/body")" == 1800 ]] || fail "ttl_seconds"
[[ "$(jq -r .values.TOKEN "$tmp/body")" == file-secret-abc ]] || fail "TOKEN value"
[[ "$(jq -r .values.OTHER "$tmp/body")" == a=b ]] || fail "OTHER value"
grep -q 'leases/lse_1/grants' "$tmp/argv" || fail "grant URL"
! grep -q 'file-secret-abc' "$tmp/argv" || fail "value leaked into argv"
! grep -q 'a=b' "$tmp/argv" || fail "value leaked into argv"
! grep -q 'leak' <<<"$out" || fail "value printed on stdout"

# default services/<service>.env
printf 'TOKEN=default-secret\n' > "$tmp/services/excalidraw.env"
"$lease" grant lse_1 excalidraw >/dev/null
[[ "$(jq -r .values.TOKEN "$tmp/body")" == default-secret ]] || fail "default file"
[[ "$(jq -r .ttl_seconds "$tmp/body")" == 900 ]] || fail "default ttl"

# --keepassxc path
"$lease" grant lse_1 excalidraw --keepassxc excalidraw/api-key >/dev/null
[[ "$(jq -r .values.TOKEN "$tmp/body")" == kp-secret-value ]] || fail "keepassxc TOKEN"
! grep -q 'kp-secret-value' "$tmp/argv" || fail "keepassxc value in curl argv"
! grep -q 'dbpass-value' "$tmp/argv" "$tmp/kp-argv" || fail "db password in argv"
grep -q 'dbpass-value' "$tmp/kp-stdin" || fail "db password not on stdin"

# missing file
rm "$tmp/services/excalidraw.env"
if err="$("$lease" grant lse_1 excalidraw 2>&1)"; then fail "missing file accepted"; fi
grep -q "excalidraw.env" <<<"$err" || fail "missing-file error does not name the file"

# reserved names
for s in github litellm all; do
  if "$lease" grant lse_1 "$s" --file "$tmp/custom.env" >/dev/null 2>&1; then fail "reserved $s accepted"; fi
done

# ungrant
"$lease" ungrant lse_1 excalidraw >/dev/null
grep -qx 'DELETE' "$tmp/argv" || fail "ungrant method"
grep -q 'leases/lse_1/grants/excalidraw' "$tmp/argv" || fail "ungrant URL"

# audit log: schema, no values
audit="$tmp/state/opencode/audit.jsonl"
jq -e 'keys == ["component","detail","event","lease_id","outcome","repo","ts"]' "$audit" >/dev/null \
  || fail "audit schema"
jq -e 'select(.event=="lease.grant" and .detail.service=="excalidraw" and .component=="lease-cli")' "$audit" >/dev/null \
  || fail "no lease.grant record"
jq -e 'select(.event=="lease.ungrant")' "$audit" >/dev/null || fail "no lease.ungrant record"
! grep -q 'secret' "$audit" || fail "secret in audit log"

# failed HTTP status
if STUB_CODE=409 "$lease" grant lse_1 excalidraw --file "$tmp/custom.env" >/dev/null 2>&1; then fail "409 accepted"; fi
tail -1 "$audit" | jq -e '.outcome == "error"' >/dev/null || fail "error outcome"

echo "lease-grant: ok"
