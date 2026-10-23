#!/usr/bin/env python3
'''PreToolUse nudge: the parent owns the subagent's report file.

Fires on the subagent-spawning tool (Agent / Task).

Convention: BEFORE spawning, the parent creates one uniquely named file on its
scratch shelf --

    .scratch/<shelf>/<agent>-<task>-<slug>.md

-- and puts that exact path in the brief. The subagent writes its findings there
and returns the path. Because the file already exists and the parent created it,
the subagent is not asking the harness to create a report file of its own, which
is what used to be refused.

The SubagentStop capture hook remains the fallback for a child that writes
nothing: it saves the final message to a scratchpad file and the PostToolUse
announce hook reports the path. If that fires, prefer the file you created.

Unlike nudge-delegate.py, this one does NOT stay silent for subagent-originated
calls: the convention must hold at EVERY nesting level, so nested children that
spawn their own grandchildren are nudged too.
'''
import json
import sys
import tempfile
from pathlib import Path


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # never block on a parse hiccup

    if data.get('tool_name', '') not in ('Agent', 'Task'):
        return 0

    # Once per session: the text never changes, so repeats only cost context.
    session_id = data.get('session_id', '')
    if session_id:
        marker = Path(tempfile.gettempdir()) / f'subagent-handoff-{session_id}.seen'
        if marker.exists():
            return 0
        try:
            marker.touch()
        except OSError:
            pass

    nudge = (
        'Subagent-handoff reminder: YOU create the report file before spawning. '
        'Pick a unique path on the scratch shelf, '
        '`.scratch/<shelf>/<agent>-<task>-<slug>.md`, create it, and put that exact '
        'path in the brief. Tell the subagent to write its findings there and return '
        'the path. Do not ask it to invent a report filename: the file already exists, '
        'so it is editing a file you own the naming of, not asking the harness to '
        'create a report. If the write is still refused, the subagent should end with '
        'its findings as its FINAL MESSAGE; the capture hook saves that and the '
        'announce hook gives you the path. Read the file you created (or the captured '
        'fallback) rather than acting on the returned message: the notification '
        'channel truncates long returns and drops some entirely. Pass the same '
        'convention down to any children it spawns. '
        'Sole-writer reminder: if this agent EDITS files, tell it that it is the only '
        'writer of the files in its brief and MUST NOT fork a child that edits those '
        'same files — a nested same-file fork is the classic silent lost-update race. '
        'Parallel children write to SEPARATE files (or their own git worktree) and the '
        'parent integrates; scope throwaway scratch to a per-agent subdir, never a '
        'shared flat namespace.'
    )
    json.dump(
        {
            'hookSpecificOutput': {
                'hookEventName':      'PreToolUse',
                'permissionDecision': 'allow',
                'additionalContext':  nudge,
            }
        },
        sys.stdout,
    )
    return 0


if __name__ == '__main__':
    sys.exit(main())
