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

function install_homedir() {
  local os=$1
  cd "${REPO_ROOT}/home/${os}"
  echo "- Installing ${os} agent dotfiles"

  for i in $(find ./ -maxdepth 1 -type f | cut -c3-); do
    ln -svfn "$PWD/$i" "$(dest_for "$i")"
  done

  for i in $(find . -mindepth 1 -type d | cut -c3-); do
    local dest; dest=$(dest_for "$i")
    echo "-- creating directory $dest"
    mkdir -p "$dest"
    for j in $(find "$i" -maxdepth 1 -type f); do
      ln -svfn "$PWD/$j" "$(dest_for "$j")"
    done
  done
  cd - >/dev/null
}

case ${1:-} in
  linux|osx )
    install_homedir general
    install_homedir "$1"
    git -C "$REPO_ROOT" config core.hooksPath .githooks
    ;;
  * ) echo "usage: $0 linux|osx" ; exit 1 ;;
esac
