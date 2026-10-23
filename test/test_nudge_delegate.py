'''Tests for nudge-delegate.py, run as a subprocess with JSON on stdin.'''
import pytest

from helper import (
    BASH_READ_RULE,
    BUDGET_RULE,
    REGEX_RULE,
    decision,
    make_file,
    run_raw,
    shipped_rules,
    text,
)


def orchestrate(env, command='ls', session='s1', agent_id='a1'):
    return env.bash(
        command,
        session_id=session,
        agent_id=agent_id,
        agent_type='orchestrator',
    )


class TestCallerIdentity:
    def test_main_matches_default_rule(self, env):
        env.rules([REGEX_RULE])
        result = decision(env.bash('pytest -q'))
        expected = 'allow'
        assert result == expected

    @pytest.mark.parametrize(
        'agent_type',
        ['worker', 'general-purpose', 'Explore', 'orchestrator'],
    )
    def test_subagent_silent_without_applies_to(self, env, agent_type):
        env.rules([REGEX_RULE])
        result = env.bash('pytest -q', agent_id='a1', agent_type=agent_type)
        expected = {}
        assert result == expected

    def test_orchestrator_matches_when_listed(self, env):
        env.rules([{**REGEX_RULE, 'appliesTo': ['orchestrator']}])
        result = decision(env.bash('pytest', agent_id='a1', agent_type='orchestrator'))
        expected = 'allow'
        assert result == expected
        assert env.bash('pytest') == {}
        assert env.bash('pytest', agent_id='a1', agent_type='worker') == {}

    def test_unknown_agent_type_matches_nothing(self, env):
        env.rules([{**REGEX_RULE, 'appliesTo': ['main', 'orchestrator']}])
        result = env.bash('pytest', agent_id='a1', agent_type='')
        expected = {}
        assert result == expected
        assert env.bash('pytest', agent_id='a1') == {}


class TestDenyRules:
    def test_regex_rule_denies(self, env):
        env.rules([{**REGEX_RULE, 'action': 'deny'}])
        out = env.bash('pytest -q')
        result = decision(out)
        expected = 'deny'
        assert result == expected
        assert out['hookSpecificOutput']['hookEventName'] == 'PreToolUse'
        assert 'run tests elsewhere' in text(out)

    def test_orchestrator_scratch_write_allowed_and_code_denied(self, env):
        rules = [r for r in shipped_rules() if r.get('tool') != 'Read']
        env.rules(rules)
        agent = {'agent_id': 'a1', 'agent_type': 'orchestrator'}

        allowed = env.run(
            {'tool_name': 'Write', 'tool_input': {'file_path': '/r/.scratch/master/plan.md'}, **agent},
        )
        denied = env.run(
            {'tool_name': 'Write', 'tool_input': {'file_path': 'src/x.py'}, **agent},
        )
        denied_edit = env.run(
            {'tool_name': 'Edit', 'tool_input': {'file_path': '/r/src/x.py'}, **agent},
        )

        assert decision(allowed) == ''
        assert decision(denied) == 'deny'
        assert decision(denied_edit) == 'deny'
        assert 'worker' in text(denied)

    def test_main_write_not_denied_by_orchestrator_rule(self, env):
        env.rules(shipped_rules())
        out = env.run({'tool_name': 'Write', 'tool_input': {'file_path': 'src/x.py'}})
        result = decision(out)
        expected = 'allow'
        assert result == expected


class TestBashRead:
    @pytest.mark.parametrize(
        'template, fires',
        [
            ('cat {big}', True),
            ('cat {small}', False),
            ('head -n 150 {big}', True),
            ('head -n 50 {big}', False),
            ('head -120 {big}', True),
            ('head {big}', False),
            ('tail -n 120 {big}', True),
            ('tail -n 20 {big}', False),
            ("sed -n '1,120p' {big}", True),
            ("sed -n '10,20p' {big}", False),
            ("sed -n '5,+119p' {big}", True),
            ('cat {small} {small} {small} {small} {small} {small}', True),
            ('echo hi; cat {big}', True),
            ('true && cat {big}', True),
            ('cat {big} | grep x', False),
            ('cat {big} > /tmp/out.txt', False),
            ('cat {big} >> /tmp/out.txt', False),
            ('cat {big} 2>/dev/null', True),
            ('cat > {small} <<EOF\nhello\nEOF', False),
            ('cat <<EOF\ncat {big}\nEOF', False),
            ('cat /does/not/exist', False),
            ("cat 'unterminated", False),
            ('echo $(cat {big})', False),
        ],
    )
    def test_bash_read_fires_for_large_output(self, env, big, small, template, fires):
        out = env.bash(template.format(big=big, small=small))
        result = decision(out) == 'deny'
        expected = fires
        assert result == expected

    def test_bash_read_names_file_and_size(self, env, big):
        out = env.bash(f'cat {big}')
        result = text(out)
        assert str(big) in result
        assert '150 lines' in result
        assert 'grep and read a range' in result

    def test_bash_read_byte_arm(self, env):
        env.rules([BASH_READ_RULE])
        wide = make_file(env.root, 'wide.txt', 5, width=5000)
        result = decision(env.bash(f'cat {wide}'))
        expected = 'deny'
        assert result == expected

    def test_bash_read_binary_suffix_skipped(self, env):
        env.rules([BASH_READ_RULE])
        path = env.root / 'img.png'
        path.write_bytes(b'\n' * 500)
        result = env.bash(f'cat {path}')
        expected = {}
        assert result == expected

    def test_bash_read_cd_relative(self, env):
        env.rules([BASH_READ_RULE])
        make_file(env.root, 'sub/f.txt', 150)
        result = decision(env.bash(f'cd {env.root}/sub && cat f.txt'))
        expected = 'deny'
        assert result == expected
        assert env.bash('cat f.txt') == {}

    def test_bash_read_tool_input_cwd(self, env):
        env.rules([BASH_READ_RULE])
        make_file(env.root, 'sub/f.txt', 150)
        out = env.run(
            {
                'tool_name': 'Bash',
                'tool_input': {'command': 'cat f.txt', 'cwd': str(env.root / 'sub')},
            },
        )
        result = decision(out)
        expected = 'deny'
        assert result == expected

    def test_bash_read_nudge_action(self, env, big):
        env.rules([{**BASH_READ_RULE, 'action': 'nudge'}])
        result = decision(env.bash(f'cat {big}'))
        expected = 'allow'
        assert result == expected

    def test_bash_read_applies_to_listed_subagents(self, env, big):
        result = decision(env.bash(f'cat {big}', agent_id='a', agent_type='orchestrator'))
        expected = 'deny'
        assert result == expected
        assert env.bash(f'cat {big}', agent_id='a', agent_type='worker') == {}


class TestCallBudget:
    def test_budget_fires_at_limit_and_twice_limit(self, env):
        env.rules([BUDGET_RULE])
        results = [orchestrate(env) for _ in range(7)]
        fired = [i + 1 for i, out in enumerate(results) if out]
        expected = [3, 6]
        assert fired == expected
        assert decision(results[2]) == 'allow'
        assert 'made 3 calls' in text(results[2])
        assert 'made 6 calls' in text(results[5])

    def test_budget_counters_are_per_caller(self, env):
        env.rules([BUDGET_RULE])
        orchestrate(env, agent_id='a1')
        orchestrate(env, agent_id='a1')

        result = decision(orchestrate(env, agent_id='a1'))
        expected = 'allow'
        assert result == expected
        assert orchestrate(env, agent_id='a2') == {}
        assert len(env.state_files()) == 2

    def test_budget_ignores_callers_not_listed(self, env):
        env.rules([BUDGET_RULE])
        for _ in range(5):
            assert env.bash('ls', session_id='s', agent_id='a', agent_type='worker') == {}
            assert env.bash('ls', session_id='s') == {}
        result = env.state_files()
        expected = []
        assert result == expected

    def test_budget_tolerates_corrupt_state(self, env):
        env.rules([BUDGET_RULE])
        orchestrate(env)
        state = env.state_files()[0]
        state.write_text('{not json')

        result = orchestrate(env)
        expected = {}
        assert result == expected
        assert state.read_text() == '{"count": 1}'

    def test_budget_with_nudge_combines(self, env):
        env.rules([{**REGEX_RULE, 'appliesTo': ['orchestrator']}, BUDGET_RULE])
        orchestrate(env, 'pytest')
        orchestrate(env, 'pytest')
        out = orchestrate(env, 'pytest')
        result = decision(out)
        expected = 'allow'
        assert result == expected
        assert 'run tests elsewhere' in text(out)
        assert 'made 3 calls' in text(out)

    def test_budget_with_deny_denies_and_combines(self, env):
        env.rules(
            [{**REGEX_RULE, 'action': 'deny', 'appliesTo': ['orchestrator']}, BUDGET_RULE],
        )
        orchestrate(env, 'ls')
        orchestrate(env, 'ls')
        out = orchestrate(env, 'pytest')
        result = decision(out)
        expected = 'deny'
        assert result == expected
        assert 'run tests elsewhere' in text(out)
        assert 'made 3 calls' in text(out)

    def test_budget_before_other_rule_does_not_stop_it(self, env):
        env.rules(
            [BUDGET_RULE, {**REGEX_RULE, 'action': 'deny', 'appliesTo': ['orchestrator']}],
        )
        orchestrate(env)
        orchestrate(env)
        out = orchestrate(env, 'pytest')
        result = decision(out)
        expected = 'deny'
        assert result == expected
        assert 'made 3 calls' in text(out)


class TestHookRobustness:
    def test_bad_stdin_is_silent(self, env):
        proc = run_raw('nope')
        result = (proc.returncode, proc.stdout)
        expected = (0, '')
        assert result == expected


class TestShippedTable:
    KNOWN_KEYS = {
        'tool', 'match', 'agent', 'hint', 'action', 'appliesTo', 'kind',
        'maxLines', 'maxBytes', 'maxCalls',
    }
    KNOWN_TOOLS = {'Bash', 'Edit', 'Write', 'Read', 'Grep', 'Glob'}

    def test_shipped_table_shapes(self, env):
        rules = shipped_rules()
        assert rules
        for rule in rules:
            assert set(rule) <= self.KNOWN_KEYS, rule
            assert rule.get('action', 'nudge') in ('nudge', 'deny')
            assert isinstance(rule.get('appliesTo', ['main']), list)
            tools = rule.get('tool', 'Bash')
            assert set([tools] if isinstance(tools, str) else tools) <= self.KNOWN_TOOLS
            kind = rule.get('kind')
            if kind == 'callBudget':
                assert isinstance(rule['maxCalls'], int) and rule['maxCalls'] > 0
                assert '{count}' in rule['hint']
                assert 'tool' not in rule
            elif kind == 'bashRead':
                assert rule['tool'] == 'Bash'
                assert 'maxLines' in rule or 'maxBytes' in rule
            elif kind is None:
                assert 'match' in rule or 'maxLines' in rule or 'maxBytes' in rule
            else:
                pytest.fail(f'unknown kind {kind}')

    def test_shipped_orchestrator_rules(self, env):
        rules = shipped_rules()
        kinds = [r.get('kind') for r in rules]
        assert 'bashRead' in kinds and 'callBudget' in kinds
        budget = next(r for r in rules if r.get('kind') == 'callBudget')
        result = (budget['maxCalls'], set(budget['appliesTo']))
        expected = (30, {'orchestrator', 'spec-implementer', 'spec-author'})
        assert result == expected
