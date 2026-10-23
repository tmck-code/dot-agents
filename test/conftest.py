'''Fixtures shared by the hook tests.'''
import pytest

from helper import BASH_READ_RULE, Env, make_file


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


@pytest.fixture
def big(env):
    env.rules([BASH_READ_RULE])
    return make_file(env.root, 'big.txt', 150)


@pytest.fixture
def small(env):
    env.rules([BASH_READ_RULE])
    return make_file(env.root, 'small.txt', 20)
