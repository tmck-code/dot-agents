#!/usr/bin/env bash
# Isolation backend detection. Safe mode needs rootless Docker, userns-remap or
# a VM-based engine (Docker Desktop, macOS). A rootful engine is refused unless
# --allow-rootful is given with OPENCODE_I_ACCEPT_UNSAFE=1. A fake docker
# answers `docker info`, so the test does not need a live stack.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d /tmp/opencode-rootless.XXXXXX)"
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

rootful_options='["name=seccomp,profile=builtin","name=cgroupns"]'

fail() { echo "rootless-check: $*" >&2; exit 1; }

# Fake uname so the Darwin case can be exercised on Linux.
cat > "$fakebin/uname" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${FAKE_UNAME:-}" ]]; then echo "$FAKE_UNAME"; else exec /usr/bin/uname "$@"; fi
FAKE
chmod +x "$fakebin/uname"

# --- rootful engine is refused ---------------------------------------------------
launch env FAKE_SECURITY="$rootful_options" ./run.sh --shell -c true
[[ $status -eq 1 ]] || fail "rootful engine exited $status, expected 1"
grep -qi 'rootful' "$tmp/err" || fail "rootful refusal did not mention rootful"
grep -q 'dockerd-rootless-setuptool' "$tmp/err" || fail "refusal lacks the setup steps"
if grep -q '^run --rm --init' "$tmp/log"; then fail "rootful refusal still started a container"; fi
[[ ! -d "$tmp/state/opencode/sessions" ]] || [[ -z "$(ls -A "$tmp/state/opencode/sessions")" ]] \
  || fail "rootful refusal created a session"

# --- rootless, userns-remap, Docker Desktop and macOS are accepted -----------------
accepted() {
  local label="$1"
  shift
  launch "$@" ./run.sh --shell -c true
  [[ $status -eq 0 ]] || { cat "$tmp/err" >&2; fail "$label exited $status, expected 0"; }
  grep -q '^run --rm --init' "$tmp/log" || fail "$label did not start the container"
}
accepted rootless env FAKE_SECURITY='["name=seccomp,profile=builtin","name=rootless"]'
accepted userns env FAKE_SECURITY='["name=seccomp,profile=builtin","name=userns"]'
accepted docker-desktop env FAKE_SECURITY="$rootful_options" FAKE_OS='Docker Desktop'
accepted darwin env FAKE_SECURITY="$rootful_options" FAKE_UNAME=Darwin

# --- --allow-rootful needs OPENCODE_I_ACCEPT_UNSAFE=1 -------------------------------
launch env FAKE_SECURITY="$rootful_options" ./run.sh --allow-rootful --shell -c true
[[ $status -eq 2 ]] || fail "--allow-rootful without the variable exited $status, expected 2"
grep -q 'OPENCODE_I_ACCEPT_UNSAFE=1' "$tmp/err" || fail "fence message lacks the variable name"
if grep -q '^run --rm --init' "$tmp/log"; then fail "fence failure still started a container"; fi

launch env FAKE_SECURITY="$rootful_options" OPENCODE_I_ACCEPT_UNSAFE=0 \
  ./run.sh --allow-rootful --shell -c true
[[ $status -eq 2 ]] || fail "--allow-rootful with the variable set to 0 exited $status"

# --- --allow-rootful with the variable proceeds, warns and is audited ----------------
: > "$audit" 2>/dev/null || true
launch env FAKE_SECURITY="$rootful_options" OPENCODE_I_ACCEPT_UNSAFE=1 \
  ./run.sh --allow-rootful --shell -c true
[[ $status -eq 0 ]] || { cat "$tmp/err" >&2; fail "--allow-rootful override exited $status"; }
grep -q 'WARNING: --allow-rootful' "$tmp/err" || fail "override printed no warning"
jq -e 'select(.event == "launcher.rootful_override" and .outcome == "warn"
              and .component == "run.sh")' "$audit" >/dev/null \
  || fail "no launcher.rootful_override audit line"

# --- the variable alone does not bypass the rootful check ----------------------------
launch env FAKE_SECURITY="$rootful_options" OPENCODE_I_ACCEPT_UNSAFE=1 ./run.sh --shell -c true
[[ $status -eq 1 ]] || fail "the variable without --allow-rootful exited $status, expected 1"

echo "rootless-check: ok"
