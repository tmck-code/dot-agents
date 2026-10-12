#!/usr/bin/env python3
'''PreToolUse enforcement: host npm is banned — transparently redirect into Docker.

Model B: this hook itself drives the chain hook -> npm-in-docker.py -> docker. An
agent typing a normal `npm install foo` in a Bash tool call must NEVER run npm on
the host. We intercept the Bash call, run dependency-mutating npm subcommands inside
a throwaway Docker container (via npm-in-docker.py), copy the mutated package.json /
package-lock.json back to the host, and then DENY the original Bash command so host
npm never executes. The deny reason carries the docker runner's output + a clear
success/failure line.

Scope: this is a Claude-Code-only guard (the hook), not a machine-wide PATH change.
There is no user-facing wrapper command.

Classification:
  - non-Bash tool                         -> allow (exit 0, silent)
  - no npm-family token in command        -> allow (exit 0, silent)
  - compound command (beyond one leading  -> deny  (shape guard)
    `cd <dir> &&`)
  - non-npm pkg manager (yarn/pnpm/...)    -> deny  (only npm is dockerized)
  - npm dependency mutation                -> run npm-in-docker.py, then deny host
  - any other npm subcommand (run/test/..) -> deny  (use project docker compose)

Fail open: on malformed stdin JSON we exit 0 (allow) so a bad payload never wedges
the user's shell.
'''
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

HOOK_DIR = Path(__file__).resolve().parent
RUNNER = HOOK_DIR / 'npm-in-docker.py'

# npm-family executable tokens (bare names). Path forms (.../npm, node_modules/.bin/x)
# are handled by basename comparison below.
NPM_FAMILY = {'npm', 'npx', 'yarn', 'pnpm', 'corepack', 'bun', 'bunx'}
NON_NPM = {'npx', 'yarn', 'pnpm', 'corepack', 'bun', 'bunx'}

# npm subcommands that mutate dependencies / the lockfile.
MUTATING = {
    'install', 'i', 'add', 'uninstall', 'remove', 'rm', 'un',
    'update', 'up', 'dedupe', 'ci', 'prune',
}

# Compound-shell metacharacters that disqualify a command from the redirect (beyond
# a single leading `cd <dir> &&`).
COMPOUND_RE = re.compile(r'(\|\||&&|[;|]|\$\(|`|\n)')

# Launcher commands that prefix the real executable; we skip past them (and their
# flags / assignments) to resolve the EFFECTIVE exe.
LAUNCHERS = {'sudo', 'env', 'command', 'time', 'nice', 'nohup', 'setsid', 'stdbuf'}
ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')


def deny(reason: str) -> int:
    json.dump(
        {
            'hookSpecificOutput': {
                'hookEventName':           'PreToolUse',
                'permissionDecision':      'deny',
                'permissionDecisionReason': reason,
            }
        },
        sys.stdout,
    )
    return 0


def basename_token(tok: str) -> str:
    '''Reduce a token to the executable name we care about.

    `/usr/bin/npm` -> `npm`; `node_modules/.bin/yarn` -> `yarn`; `npm` -> `npm`.
    '''
    return tok.rsplit('/', 1)[-1]


def strip_launchers(tokens: list) -> list:
    '''Drop a leading run of env-assignments and launcher commands.

    Returns the token list starting at the effective executable. Handles:
      FOO=bar BAZ=qux <exe>           (assignments)
      sudo/env/time/nice/... <exe>    (launchers, plus their immediately-following
                                       -flags and, after env/sudo, further VAR=val)
    Conservative: it stops at the first token that is neither an assignment, a
    launcher, nor a launcher-flag — that token is the effective exe.
    '''
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        if ASSIGN_RE.match(tok):
            i += 1
            continue
        if basename_token(tok) in LAUNCHERS:
            i += 1
            # Skip this launcher's flags and (env/sudo) trailing assignments.
            while i < n and (tokens[i].startswith('-') or ASSIGN_RE.match(tokens[i])):
                i += 1
            continue
        break
    return tokens[i:]


def npm_family_tokens(tokens: list) -> list:
    '''Return the npm-family executable tokens that look like INVOCATIONS.

    Heuristic: a token is an npm-family invocation if its basename is in NPM_FAMILY,
    OR it is `node <...>/npm` style (a node interpreter running an npm cli path).
    Tokens that only appear as arguments/values to non-pkg-manager commands are not
    perfectly excluded, but the command-shape guard + first-meaningful-token logic
    below keeps false positives to commands that genuinely START with npm/cd.
    '''
    hits = []
    for i, tok in enumerate(tokens):
        base = basename_token(tok)
        if base in NPM_FAMILY:
            hits.append(base)
        elif base == 'node' and i + 1 < len(tokens):
            # `node /path/to/npm-cli.js ...` — only if a following token looks npm-ish.
            for nxt in tokens[i + 1:]:
                nb = basename_token(nxt)
                if nb in NPM_FAMILY or 'npm' in nb:
                    hits.append('npm')
                    break
                if not nxt.startswith('-'):
                    break
    return hits


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # fail open

    if data.get('tool_name', '') != 'Bash':
        return 0

    tool_input = data.get('tool_input') or {}
    command = tool_input.get('command', '') or ''
    cwd = data.get('cwd') or os.getcwd()

    # Tokenise for detection. shlex respects quotes, so npm inside a quoted string
    # (e.g. git commit -m "npm install notes") becomes a single token whose basename
    # is the whole quoted phrase, not `npm` -> no false positive.
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()

    if not npm_family_tokens(tokens):
        return 0  # allow — the overwhelmingly common case

    # --- An npm-family invocation is present. Apply the command-shape guard. ---
    # Strip an optional single leading `cd <dir> &&`; whatever metachars remain after
    # that trip the guard below.
    workdir = cwd
    rest = command.strip()
    lead = re.match(r'^cd\s+(?P<dir>(?:\'[^\']*\'|"[^"]*"|[^\s&|;]+))\s+&&\s+(?P<rest>.*)$', rest, re.DOTALL)
    if lead:
        raw_dir = lead.group('dir')
        try:
            raw_dir = shlex.split(raw_dir)[0]
        except ValueError:
            pass
        p = Path(raw_dir)
        workdir = str(p if p.is_absolute() else Path(cwd) / p)
        rest = lead.group('rest').strip()

    # After removing the optional single leading cd, no shell metachars may remain.
    if COMPOUND_RE.search(rest):
        return deny(
            'Host npm is banned and auto-redirected into Docker, but this command is '
            'too compound to redirect safely. Run the npm command on its own, '
            'optionally prefixed by a single `cd <dir> &&` — no extra `&&`, `||`, '
            '`;`, `|`, newlines, or `$(...)`/backtick subshells.'
        )

    try:
        rest_tokens = shlex.split(rest)
    except ValueError:
        rest_tokens = rest.split()
    if not rest_tokens:
        return 0

    # Skip a leading run of env-assignments and launcher commands so the EFFECTIVE
    # executable is resolved — closes routine, non-adversarial host-npm bypasses like
    # `NODE_ENV=production npm install`, `sudo npm install`, `env FOO=bar npm ci`,
    # `time npm run build`. We do NOT try to defeat exotic wrappers (xargs etc.) — the
    # threat model is hook-only / non-adversarial.
    rest_tokens = strip_launchers(rest_tokens)
    if not rest_tokens:
        return 0

    exe = basename_token(rest_tokens[0])

    # node <npm-cli> form -> treat as npm, drop the interpreter + cli path.
    if exe == 'node':
        rest_tokens = rest_tokens[1:]
        exe = basename_token(rest_tokens[0]) if rest_tokens else ''
        if 'npm' in exe:
            exe = 'npm'

    if exe in NON_NPM:
        return deny(
            f'Host JS package managers are banned. The Claude-Code npm redirect only '
            f'dockerizes plain `npm` (it rewrites package.json/package-lock.json in a '
            f'throwaway container); it does NOT handle `{exe}`. For build/test/run use '
            f'your project\'s docker compose. If you need {exe} for dependency work, '
            f'add the dependency with `npm install` instead, or run it in your dev '
            f'container.'
        )

    if exe != 'npm':
        # The detector fired on an npm-family token that is not the leading executable
        # (e.g. npm appears as an argument). Be conservative: allow.
        return 0

    # --- It's npm. Parse the subcommand (first non-flag arg after `npm`). ---
    subcmd = ''
    for tok in rest_tokens[1:]:
        if not tok.startswith('-'):
            subcmd = tok
            break

    if subcmd in MUTATING:
        npm_args = rest_tokens[1:]
        try:
            proc = subprocess.run(
                ['python3', str(RUNNER), '--dir', workdir, '--', *npm_args],
                capture_output=True,
                text=True,
            )
        except Exception as exc:  # noqa: BLE001 — surface any spawn failure to the agent
            return deny(
                f'Host npm is banned; the Docker redirect could not be launched: {exc}. '
                f'No host files were changed.'
            )

        output = (proc.stdout or '') + (proc.stderr or '')
        if proc.returncode == 0:
            return deny(
                'HOST NPM BLOCKED — ran in Docker instead, SUCCESS.\n'
                f'{output}\n'
                f'package.json/package-lock.json updated in {workdir}; node_modules was '
                'NOT materialized on the host. Re-sync via your project\'s docker flow '
                '(e.g. docker compose build, or `npm ci` inside your dev container).'
            )
        return deny(
            'HOST NPM BLOCKED — ran in Docker instead, but it FAILED '
            f'(exit code {proc.returncode}).\n{output}\n'
            'Host files were left untouched. Fix the error above and retry the same '
            'npm command (it will be re-dockerized).'
        )

    # Any other / unknown npm subcommand.
    return deny(
        f'Host npm is banned. `npm {subcmd or "(no subcommand)"}` is not a dependency '
        'mutation, so it is not auto-dockerized. Only dependency mutations '
        '(install/i/add/uninstall/remove/rm/un/update/up/dedupe/ci/prune) are '
        'transparently redirected into a container. For build/test/run/exec use your '
        'project\'s docker compose.'
    )


if __name__ == '__main__':
    sys.exit(main())
