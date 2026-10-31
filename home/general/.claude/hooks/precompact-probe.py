#!/usr/bin/env python3
'''PreCompact probe: log every compaction event to learn what the hook sees.

Fires on PreCompact (manual + auto). Appends one JSON line per event to
$CLAUDE_CONFIG_DIR (default ~/.claude)/hooks/state/precompact-log.jsonl capturing the FULL raw stdin payload
plus a wall-clock stamp, so we can empirically confirm:
  - whether subagent compactions fire this hook at all;
  - whether agent_id / agent_type are populated for subagent events
    (they are only set for subagent-originated calls elsewhere in this setup);
  - the `trigger` (manual vs auto) and transcript_path of each event.

Non-blocking and fail-safe: any parse/IO hiccup exits cleanly, emits nothing.
'''
import json
import os
import sys
import time
from pathlib import Path

LOG = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude') / 'hooks' / 'state' / 'precompact-log.jsonl'


def main() -> int:
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0

    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        data = {'_unparsed_stdin': raw[:4000]}

    record = {
        'wall':        time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'epoch':       time.time(),
        # promoted fields for quick scanning; raw carries whatever else is present
        'agent_id':    data.get('agent_id'),
        'agent_type':  data.get('agent_type'),
        'trigger':     data.get('trigger'),
        'session_id':  data.get('session_id'),
        'transcript':  data.get('transcript_path'),
        'raw':         data,
    }

    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open('a') as fh:
            fh.write(json.dumps(record) + '\n')
    except OSError:
        pass  # best-effort; never block a compaction on logging

    return 0


if __name__ == '__main__':
    sys.exit(main())
