#!/usr/bin/env bash
# Run one of the installed yet-another-statusline (YAS) entry points.
#
#   yas.sh prompt       # UserPromptSubmit hook
#   yas.sh statusline   # statusLine command
#
# YAS ships its own Python under
#   $CLAUDE_CONFIG_DIR/plugins/cache/yet-another-statusline/yas/<version>/.python/
# The version directory changes on every plugin update, so resolve the newest one
# instead of hardcoding a version or a machine-specific path. Missing plugin is not
# an error: exit 0 with no output, so a fresh machine still starts.
set -eu

mode=${1:-}
root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/yet-another-statusline/yas"

case $mode in
  prompt|statusline) ;;
  *) echo "usage: yas.sh prompt|statusline" >&2; exit 2 ;;
esac

[ -d "$root" ] || exit 0

# Newest numeric version directory (0.9.10 > 0.9.9). POSIX-safe numeric sort.
version=$(ls -1 "$root" 2>/dev/null \
  | awk '/^[0-9]+(\.[0-9]+)*$/' \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -n 1)
[ -n "$version" ] || exit 0

dir="$root/$version"
py_dir=$(find "$dir/.python" -mindepth 1 -maxdepth 1 -type d -name 'cpython-*' 2>/dev/null | head -n 1)
[ -n "$py_dir" ] || exit 0
python="$py_dir/bin/python3"
[ -x "$python" ] || exit 0

case $mode in
  prompt)     script="$dir/hooks/yas-prompt-hook.py" ;;
  statusline) script="$dir/claude/statusline_command.py" ;;
esac
[ -f "$script" ] || exit 0

exec "$python" "$script"
