#!/bin/bash
# Symlink the Claude Code config tree for one OS into $CLAUDE_CONFIG_DIR.
#
#   ./deploy.sh linux          # installs home/general + home/linux
#   ./deploy.sh osx            # installs home/general + home/osx
#   CLAUDE_CONFIG_DIR=~/.claude.personal ./deploy.sh osx
#
# Files are symlinked (not copied), so edits in this repo take effect
# immediately. Layout mirrors the tree under the config dir:
#   home/<os>/.claude/<path>  ->  $CLAUDE_CONFIG_DIR/<path>
#
# Shared config lives in home/general; only genuinely OS-specific files live in
# home/linux or home/osx. Caches and scratch dirs are never installed, and stale
# symlinks that point into this repo are pruned after each install.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR%/}"

# Map a repo-relative path (under home/<os>/) to its install destination.
function dest_for() {
  case "$1" in
    .claude )    echo "$CLAUDE_CONFIG_DIR" ;;
    .claude/* )  echo "${CLAUDE_CONFIG_DIR}/${1#.claude/}" ;;
    * )          echo "$HOME/$1" ;;
  esac
}

# Never install generated caches or agent scratch.
function skip_path() {
  case "/$1/" in
    */__pycache__/*|*/.pytest_cache/*|*/.ruff_cache/*|*/.scratch/*|*/.git/*) return 0 ;;
  esac
  case "$1" in
    *.pyc|*.pyo|*.DS_Store) return 0 ;;
  esac
  return 1
}

# A managed top-level directory that is a symlink into this repo would make the
# per-file install below write links back into the repo source tree. Replace it
# with a real directory; the install loop repopulates it.
function ensure_real_dir() {
  local dir=$1
  [[ -L "$dir" ]] || return 0
  local target
  target=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  case "$target" in
    "$REPO_ROOT"/*)
      echo "-- replacing directory symlink $dir -> $target"
      rm -f "$dir"
      mkdir -p "$dir"
      ;;
  esac
}

function install_homedir() {
  local os=$1
  local root="$REPO_ROOT/home/$os"
  echo "- Installing $os agent dotfiles"

  local sub
  for sub in agents commands hooks scripts skills; do
    ensure_real_dir "$CLAUDE_CONFIG_DIR/$sub"
  done

  while IFS= read -r -d '' src; do
    local rel="${src#"$root"/}"
    skip_path "$rel" && continue
    local dest; dest=$(dest_for "$rel")
    local parent; parent=$(dirname "$dest")
    mkdir -p "$parent"
    # A nested directory symlink (e.g. skills/skill-overseer -> repo/.../skill-overseer)
    # already exposes the source at the destination. Never write a link back into
    # the repo from behind such a symlink.
    local parent_real
    parent_real=$(cd "$parent" 2>/dev/null && pwd -P) || parent_real=
    case "$parent_real" in
      "$REPO_ROOT"/*)
        if [[ ! -e "$dest" ]]; then
          echo "-- skipping $dest (destination directory symlinks into repo)"
        fi
        continue
        ;;
    esac
    # A file-level symlink already pointing at the source is a no-op; `ln`
    # would otherwise report "are the same file".
    if [[ -e "$dest" && "$dest" -ef "$src" ]]; then
      continue
    fi
    ln -svfn "$src" "$dest"
  done < <(find "$root" -type f -print0)
}

# Remove symlinks in the managed destinations that point into this repo and no
# longer resolve (a moved or deleted source file). User-managed links elsewhere
# are left alone.
function prune_stale() {
  local dirs=("$CLAUDE_CONFIG_DIR")
  local sub
  for sub in agents commands hooks scripts skills; do
    [[ -d "$CLAUDE_CONFIG_DIR/$sub" ]] && dirs+=("$CLAUDE_CONFIG_DIR/$sub")
  done

  local dir link target
  for dir in "${dirs[@]}"; do
    if [[ "$dir" == "$CLAUDE_CONFIG_DIR" ]]; then
      find "$dir" -maxdepth 1 -type l -print0 2>/dev/null
    else
      find "$dir" -type l -print0 2>/dev/null
    fi
  done | while IFS= read -r -d '' link; do
    target=$(readlink "$link") || continue
    case "$target" in
      "$REPO_ROOT"/home/*)
        if [[ ! -e "$link" ]]; then
          echo "-- removing stale link $link"
          rm -f "$link"
        fi
        ;;
    esac
  done
}

case ${1:-} in
  linux|osx )
    install_homedir general
    install_homedir "$1"
    prune_stale
    git -C "$REPO_ROOT" config core.hooksPath .githooks
    ;;
  * ) echo "usage: $0 linux|osx" ; exit 1 ;;
esac
