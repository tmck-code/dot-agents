#!/usr/bin/env bash
# Launcher defaults: safe mode is the default, --unsafe warns and restores the
# legacy mounts/network. A fake docker records the run arguments so the test
# does not need a live stack.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d /tmp/opencode-unsafe.XXXXXX)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat > "$fakebin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  image)
    if [[ "${2:-}" == "inspect" && "${3:-}" == "--format" ]]; then
      id -u
    fi
    exit 0
    ;;
  network)
    if [[ -n "${FAKE_NO_STACK:-}" ]]; then exit 1; fi
    exit 0
    ;;
  inspect)
    echo healthy
    exit 0
    ;;
  exec)
    printf '%s\n' '{"key":"sk-test-virtual","base_url":"http://litellm:4000"}'
    exit 0
    ;;
  run)
    printf 'RUN %s\n' "$*"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE
chmod +x "$fakebin/docker"

home="$tmp/home"
repo="$tmp/repo"
mkdir -p "$home/.ssh" "$home/.config/gh" "$repo"
printf 'private key placeholder\n' > "$home/.ssh/id_rsa"
printf 'hosts: {}\n' > "$home/.config/gh/hosts.yml"
git -C "$repo" init -q -b main
git -C "$repo" config user.name "Unsafe Test"
git -C "$repo" config user.email "unsafe@example.invalid"

run() {
  PATH="$fakebin:$PATH" FAKE_LOG="$tmp/log" HOME="$home" REPO_ROOT="$repo" \
    LEASE_TOKEN="lst_test.abc" "$@"
}

# --- safe mode is the default -------------------------------------------------
: > "$tmp/log"
run env ANTHROPIC_API_KEY="sk-ant-do-not-leak" ./run.sh --shell -c true >/dev/null
grep -q -- '--network opencode-agent' "$tmp/log"
grep -q -- '--cap-drop=ALL' "$tmp/log"
grep -q -- '--security-opt=no-new-privileges' "$tmp/log"
grep -q -- '--pids-limit=2048' "$tmp/log"
grep -q -- 'HTTP_PROXY=http://squid:3128' "$tmp/log"
grep -q -- 'LITELLM_API_KEY=sk-test-virtual' "$tmp/log"
if grep -q -- 'ANTHROPIC_API_KEY' "$tmp/log"; then
  echo "unsafe-mode: safe mode forwarded a provider root key" >&2
  exit 1
fi
if grep -q -- "$home/.ssh" "$tmp/log" || grep -q -- "$home/.config/gh" "$tmp/log"; then
  echo "unsafe-mode: safe mode mounted host credentials" >&2
  exit 1
fi
if grep -q -- 'host.docker.internal' "$tmp/log"; then
  echo "unsafe-mode: safe mode added a host gateway" >&2
  exit 1
fi

# --- --read-only is opt-in and adds tmpfs + named writable volumes ------------
: > "$tmp/log"
run ./run.sh --read-only --shell -c true >/dev/null
grep -q -- '--read-only' "$tmp/log"
grep -q -- '--tmpfs /tmp' "$tmp/log"
grep -q -- 'opencode-home-local:/home/agent/.local' "$tmp/log"

# --- safe mode fails closed without the stack ---------------------------------
: > "$tmp/log"
set +e
FAKE_NO_STACK=1 run ./run.sh --shell -c true >"$tmp/out" 2>"$tmp/err"
status=$?
set -e
[[ $status -ne 0 ]]
grep -qi 'opencode-agent network does not exist' "$tmp/err"

# --- --unsafe warns and restores legacy behaviour -----------------------------
: > "$tmp/log"
run env ANTHROPIC_API_KEY="sk-ant-do-not-leak" ./run.sh --unsafe --shell -c true \
  >"$tmp/out" 2>"$tmp/err"
grep -q 'WARNING: --unsafe' "$tmp/err"
grep -q -- '--add-host=host.docker.internal:host-gateway' "$tmp/log"
grep -q -- "$home/.ssh:/home/agent/.ssh:ro" "$tmp/log"
grep -q -- "$home/.config/gh:/home/agent/.config/gh:ro" "$tmp/log"
grep -q -- 'ANTHROPIC_API_KEY' "$tmp/log"
if grep -q -- '--cap-drop=ALL' "$tmp/log"; then
  echo "unsafe-mode: --unsafe still dropped capabilities" >&2
  exit 1
fi

echo "unsafe-mode: ok"
