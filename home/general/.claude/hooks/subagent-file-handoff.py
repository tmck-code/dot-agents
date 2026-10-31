#!/usr/bin/env python3
'''PreToolUse nudge: the parent owns the subagent's report file.

Fires on the subagent-spawning tool (Agent / Task).

Convention: BEFORE spawning, the parent creates one uniquely named file on its
scratch shelf --

    .scratch/<shelf>/<agent>-<task>-<slug>.md

-- and puts that exact path in the brief on a `REPORT FILE: <abs path>` line. The
subagent returns its findings as its final message. The SubagentStop capture hook
(subagent-report-capture.py) writes that message to the file, unless the subagent
already wrote content there. The hook also saves a copy to a scratchpad file and the
PostToolUse announce hook reports that path.

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
        'path in the brief on a line `REPORT FILE: <abs path>`. The subagent returns its '
        'full findings as its FINAL MESSAGE; the SubagentStop hook writes that message '
        'to the file (unless the subagent already wrote content there). Do not ask it '
        'to invent a report filename. Read the file you created '
        'rather than acting on the returned message: the notification '
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
