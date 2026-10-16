#!/usr/bin/env python3
'''PreToolUse(Bash): block a foreground `sleep` of 30s or more run as a command.

The harness only blocks commands that *start* with `sleep`; `cd x; sleep 570; cat *.status`
slipped through and stalled an orchestrator for ~10 minutes. Background commands are allowed.

`sleep` only counts when it is the first word of a shell command segment (after `;` `&&` `||`
`|` `(` `$(` backtick, newline, `do`/`then`/`else`, or behind `timeout N`/`nice`/`env`).
Heredoc bodies and single-quoted strings are ignored. If stripping them fails, the old
match-anywhere regex is used.
'''
import json
import re
import sys

LIMIT_SECS = 30
UNIT_SECS  = {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}
OLD_SLEEP_RE = re.compile(
    r'(?:^|[;&|(`\n]|\b(?:do|then|else|timeout\s+\S+))\s*sleep\s+(\d+(?:\.\d+)?)([smhd]?)\b'
)
SLEEP_RE   = re.compile(
    r'(?:^|[;&|(`\n]|\b(?:do|then|else)\b)\s*'
    r'(?:(?:timeout\s+\S+|nice(?:\s+-n\s*-?\d+)?|env(?:\s+\w+=\S*)*)\s+)*'
    r'sleep\s+(\d+(?:\.\d+)?)([smhd]?)\b'
)
HEREDOC_RE = re.compile(
    r'(<<-?[ \t]*(["\']?)(\w+)\2[^\n]*\n)(.*?)(^[ \t]*\3[ \t]*$)', re.S | re.M
)
SQUOTE_RE  = re.compile(r"'[^']*'")


def sleep_secs(command: str) -> float:
    try:
        stripped = HEREDOC_RE.sub(lambda m: m.group(1) + m.group(5), command)
        stripped = SQUOTE_RE.sub("''", stripped)
        pattern = SLEEP_RE
    except (re.error, IndexError, TypeError):
        stripped, pattern = command, OLD_SLEEP_RE
    return max((float(n) * UNIT_SECS[u] for n, u in pattern.findall(stripped)), default=0)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    tool_input = data.get('tool_input') or {}
    if tool_input.get('run_in_background'):
        return 0
    command = tool_input.get('command') or ''
    secs = sleep_secs(command)
    if secs < LIMIT_SECS:
        return 0
    print(
        f'BLOCKED: foreground `sleep {secs:g}s` (limit {LIMIT_SECS}s). '
        'To wait for a gate, run it with `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/gate.sh"` and run_in_background, '
        'then end your turn: the completion notification re-invokes you. '
        'To wait on a file or condition, use the Monitor tool with an until-loop.',
        file=sys.stderr,
    )
    return 2


if __name__ == '__main__':
    sys.exit(main())
