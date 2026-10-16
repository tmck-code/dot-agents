#!/usr/bin/env bash
# Stall alarm for subagents. Prints one line per newly-stale agent:
#   STALE <agent-id> idle=<min>m last-tool=<name>
# Stale = transcript mtime older than MINUTES and last line is not a text-only
# assistant turn. Exits when the directory disappears.
#
# Monitor invocation example:
#   Monitor: command="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/agent-watch.sh -m 20 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<encoded-cwd>/<session-id>/subagents/"
# Usage: agent-watch.sh [-m MINUTES] <session-subagents-dir>
set -u
mins=20
while getopts m: o; do case $o in m) mins=$OPTARG ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1))
dir=${1:?usage: agent-watch.sh [-m MINUTES] <subagents-dir>}
declare -A seen
while [ -d "$dir" ]; do
  now=$(date +%s)
  for f in "$dir"/*.jsonl; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .jsonl)
    idle=$(( (now - $(stat -c %Y "$f")) / 60 ))
    if [ "$idle" -lt "$mins" ]; then unset "seen[$id]"; continue; fi
    last=$(tail -n 1 "$f")
    final=$(printf '%s' "$last" | jq -r 'if .type=="assistant" and ((.message.content|type)=="string" or (.message.content|all(.type=="text"))) then "yes" else "no" end' 2>/dev/null || echo no)
    [ "$final" = yes ] && continue
    [ -n "${seen[$id]:-}" ] && continue
    seen[$id]=1
    tool=$(tail -n 200 "$f" | jq -r 'select(.type=="assistant") | .message.content | arrays | .[] | select(.type=="tool_use") | .name' 2>/dev/null | tail -n 1)
    printf 'STALE %s idle=%sm last-tool=%s\n' "$id" "$idle" "${tool:-none}"
  done
  read -r -t 60 <> <(:) || true
done
