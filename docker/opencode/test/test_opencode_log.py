from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / 'bin' / 'opencode-log'


def load_module():
    loader = SourceFileLoader('opencode_log', str(SCRIPT))
    spec   = spec_from_loader('opencode_log', loader)
    mod    = module_from_spec(spec)
    loader.exec_module(mod)
    return mod


log = load_module()


def record(**over):
    base = {
        'ts': '2026-01-01T00:00:00.000Z', 'component': 'broker', 'event': 'token.issue',
        'lease_id': 'L1', 'repo': 'o/r', 'outcome': 'ok', 'detail': {'service': 'github'},
    }
    base.update(over)
    return base


def ns(**over):
    base = {'component': None, 'lease': None, 'outcome': None, 'style': 'dracula'}
    base.update(over)
    return argparse.Namespace(**base)


class Tty(io.StringIO):
    def isatty(self):
        return True


def run(lines, args, color=False):
    out = Tty() if color else io.StringIO()
    log.render(lines, args, color, out)
    return out.getvalue()


def test_keys_are_printed_in_schema_order():
    shuffled = dict(reversed(list(record().items())))
    text     = run([json.dumps(shuffled)], ns())
    assert list(json.loads(text)) == list(log.KEYS)


def test_filters_by_lease_component_and_outcome():
    lines = [
        json.dumps(record()),
        json.dumps(record(lease_id='L2')),
        json.dumps(record(component='squid')),
        json.dumps(record(outcome='deny')),
    ]
    assert len(run(lines, ns(lease='L2')).splitlines()) == 1
    assert len(run(lines, ns(component='squid')).splitlines()) == 1
    assert len(run(lines, ns(outcome='deny')).splitlines()) == 1


def test_non_json_line_passes_through_unchanged():
    text = run(['not json at all', json.dumps(record())], ns())
    assert text.splitlines()[0] == 'not json at all'
    assert len(text.splitlines()) == 2


def test_color_is_off_for_no_color_env_flag_and_non_tty():
    assert log.use_color(Tty(), False, {}) is True
    assert log.use_color(Tty(), False, {'NO_COLOR': '1'}) is False
    assert log.use_color(Tty(), True, {}) is False
    assert log.use_color(io.StringIO(), False, {}) is False


def test_color_output_contains_escapes_and_plain_does_not():
    line = json.dumps(record())
    assert '\x1b[' in run([line], ns(), color=True)
    assert '\x1b[' not in run([line], ns(), color=False)


def test_piped_output_has_no_escape_sequences(tmp_path):
    src = tmp_path / 'audit.jsonl'
    src.write_text(json.dumps(record()) + '\nplain text\n')
    res = subprocess.run(
        [sys.executable, str(SCRIPT), 'pretty', str(src)],
        capture_output=True, text=True, check=True,
    )
    assert '\x1b' not in res.stdout
    assert 'plain text' in res.stdout


def outcome_text(outcome, color=True):
    return run([json.dumps(record(outcome=outcome))], ns(), color=color)


def test_outcome_value_is_green_for_ok():
    assert f'{log.GREEN}"ok"{log.RESET}' in outcome_text('ok')


def test_outcome_value_is_red_for_deny_and_error():
    assert f'{log.RED}"deny"{log.RESET}' in outcome_text('deny')
    assert f'{log.RED}"error"{log.RESET}' in outcome_text('error')


def test_outcome_value_is_yellow_for_warn():
    assert f'{log.YELLOW}"warn"{log.RESET}' in outcome_text('warn')


def test_each_key_has_its_fixed_column_colour():
    text = outcome_text('ok')
    for key in log.KEYS:
        assert f'{log.KEY_COLORS[key]}"{key}"{log.RESET}' in text


def test_coloured_record_strips_back_to_plain_json_content():
    import re
    text  = outcome_text('ok')
    plain = re.sub(r'\x1b\[[0-9;]*m', '', text)
    assert json.loads(plain) == record()
