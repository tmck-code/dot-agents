#!/usr/bin/env bash
# Linked-worktree fidelity: git works in the worktree, and the main checkout is
# mounted read-only so a session cannot write to it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT_DIR="$PWD"

IMAGE="${IMAGE:-opencode-dev:local}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "worktree-smoke: building $IMAGE" >&2
  make build
fi

tmp="$(mktemp -d /tmp/opencode-worktree.XXXXXX)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

main="$tmp/main"
worktree="$tmp/worktree"
mkdir -p "$main"
git -C "$main" init -q -b main
git -C "$main" config user.name "Worktree Test"
git -C "$main" config user.email "worktree@example.invalid"
printf 'main\n' > "$main/README.md"
git -C "$main" add README.md
git -C "$main" commit -qm initial
git -C "$main" worktree add -q "$worktree" -b test-branch

echo "worktree-smoke: git status, commit, and read-only main checkout"
(
  cd "$worktree"
  REPO_ROOT="$worktree" "$SCRIPT_DIR/run.sh" --unsafe --shell -c '
    set -euo pipefail
    git status --porcelain >/dev/null
    printf "worktree\n" > worktree.txt
    git add worktree.txt
    git commit -qm "worktree commit"
    if touch "$0/blocked" 2>/dev/null; then
      echo "worktree-smoke: main checkout was writable" >&2
      exit 1
    fi
  ' "$main"
)

echo "worktree-smoke: ok"
