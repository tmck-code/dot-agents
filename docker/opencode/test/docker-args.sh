#!/usr/bin/env bash
# OPENCODE_DOCKER_ARGS must not widen isolation. Each rejected flag is tried in
# every accepted form. A fake docker records calls, so the test can assert that
# a rejection happens before any docker command. OPENCODE_I_ACCEPT_UNSAFE=1
# turns a rejection into a warning and an audit line.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d /tmp/opencode-docker-args.XXXXXX)"
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

fail() { echo "docker-args: $*" >&2; exit 1; }

# Each entry is one OPENCODE_DOCKER_ARGS value that must be rejected.
rejected=(
  '--privileged' '--privileged=true'
  '--network host' '--network=host' '--net host' '--net=host'
  '--pid host' '--pid=host' '--ipc host' '--ipc=host' '--uts host' '--uts=host'
  '--userns host' '--userns=host' '--cgroupns host' '--cgroupns=host'
  '--cap-add ALL' '--cap-add=SYS_ADMIN'
  '--security-opt seccomp=unconfined' '--security-opt=apparmor=unconfined'
  '--device /dev/kmsg' '--device=/dev/kmsg'
  '--user 0' '--user=0:0' '-u 0' '-u0' '-itu0'
  '--volume /:/h' '--volume=/:/h' '-v /:/h' '-v/:/h' '-itv /:/x' '-dv /:/x'
  '--mount type=bind,src=/,dst=/h' '--mount=type=bind,src=/,dst=/h'
  '--volumes-from other'
  '--env FOO=bar --network=host'
)

for value in "${rejected[@]}"; do
  launch env OPENCODE_DOCKER_ARGS="$value" ./run.sh --shell -c true
  [[ $status -eq 2 ]] || fail "'$value' exited $status, expected 2"
  grep -q 'OPENCODE_DOCKER_ARGS' "$tmp/err" || fail "'$value' gave no explanation"
  [[ ! -s "$tmp/log" ]] || fail "'$value' reached docker: $(head -1 "$tmp/log")"
done

# --- harmless flags are accepted and passed through ---------------------------------
for value in '--env FOO=bar' '-e FOO=bar' '--name hoi-test-args' '--env FOO=bar --env BAZ=1'; do
  launch env OPENCODE_DOCKER_ARGS="$value" ./run.sh --shell -c true
  [[ $status -eq 0 ]] || { cat "$tmp/err" >&2; fail "'$value' exited $status, expected 0"; }
  grep -q '^run --rm --init' "$tmp/log" || fail "'$value' did not start the container"
  run_line="$(grep '^run --rm --init' "$tmp/log")"
  [[ "$run_line" == *"$value"* ]] || fail "'$value' was not passed to docker run"
done

# --- override path ------------------------------------------------------------------
: > "$audit" 2>/dev/null || true
launch env OPENCODE_DOCKER_ARGS='--network=host' OPENCODE_I_ACCEPT_UNSAFE=1 \
  ./run.sh --shell -c true
[[ $status -eq 0 ]] || { cat "$tmp/err" >&2; fail "override exited $status, expected 0"; }
grep -q 'WARNING: OPENCODE_DOCKER_ARGS' "$tmp/err" || fail "override printed no warning"
grep -q -- '--network=host' "$tmp/log" || fail "overridden flag was not passed to docker run"
jq -e 'select(.event == "docker_args.override" and .outcome == "warn"
              and .detail.flag == "--network=host")' "$audit" >/dev/null \
  || fail "no docker_args.override audit line"

echo "docker-args: ok"
