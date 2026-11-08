#!/usr/bin/env bash
# Session workspace fidelity, from a plain repository and from a linked
# worktree. Safe mode runs against a fake stack: a `docker` wrapper answers the
# stack checks and rewrites only the final `docker run` (no stack network, no
# named volumes, agent uid) before passing it to the real docker.
#
# Per case it checks that git works in the session clone, that a commit made
# inside the container leaves the host branch and working tree unchanged, that
# the commit is reachable through `run.sh review`, that the host hooks path is
# absent, and that the objects mount is read-only.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT_DIR="$PWD"

IMAGE="${IMAGE:-opencode-dev:local}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "worktree-smoke: building $IMAGE" >&2
  make build
fi

REAL_DOCKER="$(command -v docker)"
tmp="$(mktemp -d /tmp/opencode-worktree.XXXXXX)"
export XDG_STATE_HOME="$tmp/state"
sessions=()
cleanup() {
  local entry
  for entry in "${sessions[@]}"; do
    # entry is <repo-dir>:<session-id>; clean runs from that repository.
    (cd "${entry%%:*}" && unset REPO_ROOT && PATH="$tmp/bin:$PATH" \
      "$SCRIPT_DIR/run.sh" clean "${entry#*:}" >/dev/null 2>&1) || true
  done
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

fail() { echo "worktree-smoke: FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/claude" "$XDG_STATE_HOME"
printf '{}\n' > "$tmp/claude/settings.json"
chmod 0755 "$tmp/claude"
chmod 0644 "$tmp/claude/settings.json"

cat > "$tmp/bin/docker" <<FAKE
#!/usr/bin/env bash
REAL=$REAL_DOCKER
case "\$1 \$2" in
  "image inspect") [[ "\$*" == *Labels* ]] && echo 60917; exit 0 ;;
  "info --format") [[ "\$3" == *Security* ]] && echo '[name=seccomp name=rootless]'; exit 0 ;;
  "volume inspect") exit 1 ;;
  "network inspect") exit 0 ;;
  "inspect --format") echo healthy; exit 0 ;;
  "exec --env")
    if [[ "\$*" == *leases/self* ]]; then echo '{"lease_id":"L1"}'; else echo '{"key":"sk-test"}'; fi
    exit 0 ;;
esac
if [[ "\$1" == run && "\$*" == *"--entrypoint bash"* && "\$*" == *"--network opencode-agent"* ]]; then
  shift
  args=(--user 60917:60917 --name "hoi-test-\$\$")
  while (( \$# )); do
    case "\$1" in
      --network) args+=(--network none); shift 2 ;;
      --add-host=*) shift ;;
      -v)
        if [[ "\$2" == /* ]]; then args+=(-v "\$2"); fi
        shift 2 ;;
      *) args+=("\$1"); shift ;;
    esac
  done
  exec "\$REAL" run "\${args[@]}"
fi
exec "\$REAL" "\$@"
FAKE
chmod +x "$tmp/bin/docker"

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Worktree Test"
  git -C "$dir" config user.email "worktree@example.invalid"
  printf 'main\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm initial
}

# run_case <name> <repo-dir> <expected-file>
# <repo-dir> is the working directory run.sh is started from.
run_case() {
  local name="$1" repo="$2" expect_file="$3"
  local id common head_before status_before head_after review_ref
  id="$(date +%Y%m%dT%H%M%S)-$(printf "%06x" $((RANDOM * 256 + RANDOM % 256)))"
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
  head_before="$(git -C "$repo" rev-parse HEAD)"
  printf 'dirty\n' > "$repo/dirty.txt"
  status_before="$(git -C "$repo" status --porcelain)"
  sessions+=("$repo:$id")

  echo "worktree-smoke: [$name] commit inside the session container"
  (
    cd "$repo"
    unset REPO_ROOT
    export PATH="$tmp/bin:$PATH" OPENCODE_SESSION_ID="$id" LEASE_TOKEN=test-lease
    export CLAUDE_CONFIG_DIR="$tmp/claude"
    "$SCRIPT_DIR/run.sh" --shell -c '
      set -euo pipefail
      repo=$1 common=$2 expect=$3
      git status --porcelain >/dev/null
      [ -f "$expect" ] || { echo "base file $expect missing" >&2; exit 1; }
      [ ! -e dirty.txt ] || { echo "uncommitted host file was carried" >&2; exit 1; }
      [ ! -e "$common/hooks" ] || { echo "host hooks path visible" >&2; exit 1; }
      [ ! -e "$repo/.git/hooks" ] || { echo "host .git/hooks visible" >&2; exit 1; }
      if touch "$common/objects/blocked" 2>/dev/null; then
        echo "objects mount was writable" >&2
        exit 1
      fi
      printf "from-container\n" > container.txt
      git add container.txt
      git -c user.name=agent -c user.email=agent@example.invalid commit -qm "container commit"
    ' bash "$repo" "$common" "$expect_file"
  ) || fail "[$name] container checks"

  echo "worktree-smoke: [$name] host branch and working tree unchanged"
  head_after="$(git -C "$repo" rev-parse HEAD)"
  [[ "$head_after" == "$head_before" ]] || fail "[$name] host HEAD moved"
  [[ "$(git -C "$repo" status --porcelain)" == "$status_before" ]] \
    || fail "[$name] host working tree changed"
  [[ ! -e "$repo/container.txt" ]] || fail "[$name] container file reached the host tree"
  if git -C "$repo" rev-parse -q --verify "refs/heads/opencode/$id" >/dev/null; then
    fail "[$name] session branch exists in the host repo before review"
  fi

  echo "worktree-smoke: [$name] commit reachable through run.sh review"
  (
    cd "$repo"
    unset REPO_ROOT
    PATH="$tmp/bin:$PATH" NO_COLOR=1 "$SCRIPT_DIR/run.sh" review "$id" > "$tmp/review-$name.out"
  ) || fail "[$name] run.sh review failed"
  review_ref="$(git -C "$repo" rev-parse -q --verify "refs/opencode/review/$id")" \
    || fail "[$name] review ref missing"
  [[ "$(git -C "$repo" log -1 --format=%s "$review_ref")" == "container commit" ]] \
    || fail "[$name] review ref does not point at the container commit"
  grep -q 'container.txt' "$tmp/review-$name.out" || fail "[$name] review diff stat lacks container.txt"
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$head_before" ]] || fail "[$name] review moved host HEAD"
  rm -f "$repo/dirty.txt"
}

make_repo "$tmp/plain"
run_case plain "$tmp/plain" README.md

make_repo "$tmp/main"
git -C "$tmp/main" worktree add -q "$tmp/worktree" -b test-branch
printf 'linked\n' > "$tmp/worktree/linked.txt"
git -C "$tmp/worktree" add linked.txt
git -C "$tmp/worktree" commit -qm "linked base"
run_case worktree "$tmp/worktree" linked.txt

echo "worktree-smoke: ok"
