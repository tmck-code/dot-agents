#!/usr/bin/env bash
# Launcher defaults: safe mode is the default. --unsafe is fenced: it needs
# OPENCODE_I_ACCEPT_UNSAFE=1, a terminal on stdin and stderr, and the typed word
# `unsafe`. Every outcome writes an audit line. A fake docker records the run
# arguments so the test does not need a live stack.
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
      echo 60917
    fi
    exit 0
    ;;
  info)
    case "$*" in
      *OperatingSystem*) printf '%s\n' "${FAKE_OS:-Fake Linux}" ;;
      *SecurityOptions*) printf '%s\n' "${FAKE_SECURITY:-[\"name=seccomp,profile=builtin\",\"name=rootless\"]}" ;;
    esac
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
    printf '%s\n' '{"lease_id":"L1","key":"sk-test-virtual","base_url":"http://litellm:4000"}'
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
mkdir -p "$home/.ssh" "$home/.config/gh" "$repo" "$tmp/state" "$tmp/claude"
printf 'private key placeholder\n' > "$home/.ssh/id_rsa"
printf 'hosts: {}\n' > "$home/.config/gh/hosts.yml"
git -C "$repo" init -q -b main
git -C "$repo" config user.name "Test"
git -C "$repo" config user.email "test@example.invalid"
git -C "$repo" commit -q --allow-empty -m init
audit="$tmp/state/opencode/audit.jsonl"

# Runs a command with the fake docker first on PATH and temporary state.
run() {
  PATH="$fakebin:$PATH" FAKE_LOG="$tmp/log" HOME="$home" REPO_ROOT="$repo" \
    XDG_STATE_HOME="$tmp/state" CLAUDE_CONFIG_DIR="$tmp/claude" \
    LEASE_TOKEN="lst_test.abc" "$@"
}

# Runs ./run.sh and records its exit status in $status without stopping.
launch() {
  : > "$tmp/log"
  set +e
  run "$@" >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
  set -e
}

fail() { echo "unsafe-mode: $*" >&2; exit 1; }

# --- safe mode is the default -------------------------------------------------
launch env ANTHROPIC_API_KEY="sk-ant-do-not-leak" ./run.sh --shell -c true
[[ $status -eq 0 ]] || { cat "$tmp/err" >&2; fail "safe mode exited $status"; }
grep -q -- '--network opencode-agent' "$tmp/log"
grep -q -- '--cap-drop=ALL' "$tmp/log"
grep -q -- '--security-opt=no-new-privileges' "$tmp/log"
grep -q -- '--pids-limit=2048' "$tmp/log"
grep -q -- 'HTTP_PROXY=http://squid:3128' "$tmp/log"
grep -q -- 'LITELLM_API_KEY=sk-test-virtual' "$tmp/log"
if grep -q -- 'ANTHROPIC_API_KEY' "$tmp/log"; then
  fail "safe mode forwarded a provider root key"
fi
if grep -q -- "$home/.ssh" "$tmp/log" || grep -q -- "$home/.config/gh" "$tmp/log"; then
  fail "safe mode mounted host credentials"
fi
if grep -q -- 'host.docker.internal' "$tmp/log"; then
  fail "safe mode added a host gateway"
fi

# --- --read-only is opt-in and adds tmpfs + named writable volumes ------------
launch ./run.sh --read-only --shell -c true
grep -q -- '--read-only' "$tmp/log"
grep -q -- '--tmpfs /tmp' "$tmp/log"
grep -q -- 'opencode-home-local:/home/agent/.local' "$tmp/log"

# --- safe mode fails closed without the stack ---------------------------------
launch env FAKE_NO_STACK=1 ./run.sh --shell -c true
[[ $status -ne 0 ]] || fail "safe mode started without the stack"
grep -qi 'opencode-agent network does not exist' "$tmp/err"

# --- --unsafe is refused without OPENCODE_I_ACCEPT_UNSAFE=1 -------------------
rm -f "$audit"
launch ./run.sh --unsafe --shell -c true
[[ $status -eq 2 ]] || fail "--unsafe without the variable exited $status, expected 2"
grep -q 'OPENCODE_I_ACCEPT_UNSAFE=1 is not set' "$tmp/err" || fail "no reason printed"
if grep -q '^run --rm --init' "$tmp/log"; then fail "refused --unsafe still started a container"; fi
jq -e 'select(.event == "unsafe.refused" and .outcome == "deny"
              and (.detail.reason | test("not set")))' "$audit" >/dev/null \
  || fail "no unsafe.refused audit line for the missing variable"

# --- --unsafe is refused without a terminal -----------------------------------
rm -f "$audit"
launch env OPENCODE_I_ACCEPT_UNSAFE=1 ./run.sh --unsafe --shell -c true
[[ $status -eq 2 ]] || fail "--unsafe without a TTY exited $status, expected 2"
grep -q 'must be terminals' "$tmp/err" || fail "no TTY reason printed"
if grep -q '^run --rm --init' "$tmp/log"; then fail "non-TTY --unsafe still started a container"; fi
jq -e 'select(.event == "unsafe.refused" and .outcome == "deny"
              and (.detail.reason | test("terminals")))' "$audit" >/dev/null \
  || fail "no unsafe.refused audit line for the missing TTY"

# Runs ./run.sh --unsafe on a pseudo-terminal, typing $1 as the confirmation.
# Output of both streams ends in $tmp/out.
unsafe_on_tty() {
  local typed="$1"
  : > "$tmp/log"
  set +e
  printf '%s\n' "$typed" | PATH="$fakebin:$PATH" FAKE_LOG="$tmp/log" HOME="$home" \
    REPO_ROOT="$repo" XDG_STATE_HOME="$tmp/state" CLAUDE_CONFIG_DIR="$tmp/claude" \
    LEASE_TOKEN="lst_test.abc" OPENCODE_I_ACCEPT_UNSAFE=1 ANTHROPIC_API_KEY="sk-ant-do-not-leak" \
    script -qec './run.sh --unsafe --shell -c true' /dev/null >"$tmp/out" 2>&1
  set -e
  tr -d '\r' < "$tmp/out" > "$tmp/out.clean"
}

# --- --unsafe with the wrong confirmation text is refused ---------------------
rm -f "$audit"
unsafe_on_tty nope
if grep -q '^run --rm --init' "$tmp/log"; then fail "wrong confirmation still started a container"; fi
grep -q "confirmation text was not 'unsafe'" "$tmp/out.clean" || fail "no confirmation reason printed"
jq -e 'select(.event == "unsafe.refused" and .outcome == "deny"
              and (.detail.reason | test("confirmation")))' "$audit" >/dev/null \
  || fail "no unsafe.refused audit line for the wrong text"

# --- --unsafe accepted through a pseudo-terminal feeding `unsafe` -------------
rm -f "$audit"
unsafe_on_tty unsafe
grep -q 'WARNING: --unsafe' "$tmp/out.clean" || fail "no --unsafe warning"
grep -q -- '--add-host=host.docker.internal:host-gateway' "$tmp/log" || fail "no host gateway"
grep -q -- "$home/.ssh:/home/agent/.ssh:ro" "$tmp/log" || fail "no ssh mount"
grep -q -- "$home/.config/gh:/home/agent/.config/gh:ro" "$tmp/log" || fail "no gh mount"
grep -q -- 'ANTHROPIC_API_KEY' "$tmp/log" || fail "provider key not forwarded"
if grep -q -- '--cap-drop=ALL' "$tmp/log"; then
  fail "--unsafe still dropped capabilities"
fi
jq -e 'select(.event == "unsafe.start" and .outcome == "warn"
              and (.detail.exposures | index("host_gateway")))' "$audit" >/dev/null \
  || fail "no unsafe.start audit line"
if grep -q 'sk-ant-do-not-leak' "$audit"; then fail "audit log contains a secret"; fi

echo "unsafe-mode: ok"
