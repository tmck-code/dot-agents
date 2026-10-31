'''Shared helpers for the nudge-delegate hook tests.'''
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HOOK = REPO_ROOT / 'home' / 'general' / '.claude' / 'hooks' / 'nudge-delegate.py'
SHIPPED = REPO_ROOT / 'home' / 'general' / '.claude' / 'delegate-routing.json'

FOUR_CALLERS = ['main', 'orchestrator', 'spec-implementer', 'spec-author']
BASH_READ_RULE = {
    'tool': 'Bash', 'kind': 'bashRead', 'maxLines': 100, 'maxBytes': 20000,
    'action': 'deny', 'appliesTo': FOUR_CALLERS, 'hint': 'grep and read a range',
}
REGEX_RULE = {'tool': 'Bash', 'match': 'pytest', 'hint': 'run tests elsewhere'}
BUDGET_RULE = {
    'kind': 'callBudget', 'appliesTo': ['orchestrator'], 'maxCalls': 3,
    'hint': 'made {count} calls',
}


class Env:
    '''A throwaway config dir + project dir for one hook invocation.'''

    def __init__(self, root: Path) -> None:
        self.root = root
        self.config = root / 'config'
        self.project = root / 'project'
        (self.project / '.claude').mkdir(parents=True)
        self.config.mkdir()

    def rules(self, rules: list) -> None:
        (self.project / '.claude' / 'delegate-routing.json').write_text(
            json.dumps({'rules': rules}),
        )

    def run(self, payload: dict, cwd: Path | None = None) -> dict:
        proc = subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            cwd=cwd or self.root,
            env={
                'HOME': str(self.root),
                'CLAUDE_CONFIG_DIR': str(self.config),
                'CLAUDE_PROJECT_DIR': str(self.project),
                'PATH': '/usr/bin:/bin',
            },
        )
        assert proc.returncode == 0, proc.stderr
        return json.loads(proc.stdout) if proc.stdout.strip() else {}

    def bash(self, command: str, **extra) -> dict:
        payload = {'tool_name': 'Bash', 'tool_input': {'command': command}, **extra}
        return self.run(payload)

    def state_files(self) -> list:
        return sorted((self.config / 'hooks' / 'state').glob('calls-*.json'))


def decision(out: dict) -> str:
    return out.get('hookSpecificOutput', {}).get('permissionDecision', '')


def text(out: dict) -> str:
    spec = out.get('hookSpecificOutput', {})
    return spec.get('permissionDecisionReason') or spec.get('additionalContext', '')


def make_file(root: Path, name: str, lines: int, width: int = 10) -> Path:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join('x' * width + '\n' for _ in range(lines)))
    return path


def shipped_rules() -> list:
    return json.loads(SHIPPED.read_text())['rules']


def run_raw(stdin: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(HOOK)],
        input=stdin,
        capture_output=True,
        text=True,
    )
