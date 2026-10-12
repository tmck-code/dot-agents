#!/usr/bin/env python3
'''Run an npm dependency mutation inside a throwaway Docker container.

Total host isolation: NO bind mounts. The container sees ONLY package.json (and
package-lock.json if present), copied in with `docker cp`. npm runs there; on success
the mutated package.json + package-lock.json are copied back out. node_modules is
NEVER materialized on the host — the agent re-syncs via the project's docker flow.

Standalone CLI (also called by the ban-host-npm.py PreToolUse hook):

    npm-in-docker.py --dir <workdir> -- <npm args...>

Exit code is npm's exit code (or non-zero for our own preflight refusals).

Node MAJOR version precedence:
  1. Concrete pins (top tier, equal): package.json volta.node, .nvmrc, .node-version.
     MAJOR only. If concrete sources disagree, warn and pick the first found in that
     order.
  2. package.json engines.node semver range -> floor major.
  3. Dockerfile `FROM node:<major>...` -> its major.
  4. Default major 22 (loud warning that nothing was declared).

libc flavor (the ONLY axis the Dockerfile is authoritative for): a Dockerfile with a
`FROM node:...-alpine` line -> musl/alpine; otherwise -> glibc/bookworm-slim. Image tag
is always the MAJOR tag so it stays security-patched:
  glibc -> node:<major>-bookworm-slim ;  musl -> node:<major>-alpine
'''
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_MAJOR = 22
DOCKERFILE_SPOTS = ['.', 'ops', 'docker']
FROM_NODE_RE = re.compile(r'^\s*FROM\s+node:([0-9]+)[^\s]*', re.IGNORECASE | re.MULTILINE)
FROM_NODE_ALPINE_RE = re.compile(r'^\s*FROM\s+node:[^\s]*-alpine', re.IGNORECASE | re.MULTILINE)


def warn(msg: str) -> None:
    print(f'[npm-in-docker] WARNING: {msg}', file=sys.stderr)


def note(msg: str) -> None:
    print(f'[npm-in-docker] {msg}')


def fail(msg: str, rc: int = 1) -> int:
    print(f'[npm-in-docker] ERROR: {msg}', file=sys.stderr)
    return rc


def find_package_dir(start: Path) -> Path | None:
    cur = start.resolve()
    for d in [cur, *cur.parents]:
        if (d / 'package.json').is_file():
            return d
    return None


def load_package_json(pkgdir: Path) -> dict:
    try:
        return json.loads((pkgdir / 'package.json').read_text())
    except (OSError, json.JSONDecodeError, ValueError):
        return {}


def major_from_concrete(text: str) -> str | None:
    m = re.search(r'v?(\d+)', text or '')
    return m.group(1) if m else None


def detect_major(pkgdir: Path, pkg: dict, dockerfile_text: str) -> tuple[str, str]:
    '''Return (major, source-description). Implements the precedence above.'''
    concrete = []  # (label, major)

    volta = (pkg.get('volta') or {}).get('node')
    if volta:
        mj = major_from_concrete(str(volta))
        if mj:
            concrete.append(('package.json volta.node', mj))

    for fname in ('.nvmrc', '.node-version'):
        fp = pkgdir / fname
        if fp.is_file():
            mj = major_from_concrete(fp.read_text())
            if mj:
                concrete.append((fname, mj))

    if concrete:
        majors = {mj for _, mj in concrete}
        if len(majors) > 1:
            warn(
                'conflicting concrete Node pins: '
                + ', '.join(f'{lbl}={mj}' for lbl, mj in concrete)
                + f' — using {concrete[0][1]} (from {concrete[0][0]})'
            )
        return concrete[0][1], concrete[0][0]

    engines = (pkg.get('engines') or {}).get('node')
    if engines:
        m = re.search(r'(\d+)', str(engines))
        if m:
            return m.group(1), f'package.json engines.node ({engines})'

    if dockerfile_text:
        m = FROM_NODE_RE.search(dockerfile_text)
        if m:
            return m.group(1), 'Dockerfile FROM node:<major>'

    warn(
        f'no Node version declared (no volta/.nvmrc/.node-version/engines/Dockerfile) '
        f'— defaulting to Node {DEFAULT_MAJOR}'
    )
    return str(DEFAULT_MAJOR), f'default ({DEFAULT_MAJOR})'


def read_dockerfile(pkgdir: Path) -> str:
    for spot in DOCKERFILE_SPOTS:
        df = pkgdir / spot / 'Dockerfile'
        if df.is_file():
            try:
                return df.read_text()
            except OSError:
                continue
    return ''


def refuse_non_npm(pkgdir: Path, pkg: dict) -> str | None:
    if (pkgdir / 'pnpm-lock.yaml').is_file():
        return 'pnpm-lock.yaml present — this is a pnpm repo; the npm redirect is npm-only.'
    if (pkgdir / 'yarn.lock').is_file():
        return 'yarn.lock present — this is a yarn repo; the npm redirect is npm-only.'
    pm = str(pkg.get('packageManager', ''))
    if pm.startswith(('pnpm', 'yarn')):
        return f'package.json packageManager="{pm}" — not npm; the redirect is npm-only.'
    return None


def docker(*args: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(['docker', *args], text=True, **kw)


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('--dir', required=True, help='working dir to search upward from')
    ap.add_argument('npm_args', nargs=argparse.REMAINDER,
                    help='-- then the npm args (e.g. -- install lodash)')
    ns = ap.parse_args()

    npm_args = ns.npm_args
    if npm_args and npm_args[0] == '--':
        npm_args = npm_args[1:]
    if not npm_args:
        return fail('no npm args given (usage: --dir <d> -- <npm args...>)')

    start = Path(ns.dir)
    if not start.exists():
        return fail(f'workdir does not exist: {ns.dir}')

    pkgdir = find_package_dir(start)
    if pkgdir is None:
        return fail(f'no package.json found at or above {start.resolve()}')

    pkg = load_package_json(pkgdir)

    refusal = refuse_non_npm(pkgdir, pkg)
    if refusal:
        return fail(refusal)

    dockerfile_text = read_dockerfile(pkgdir)
    major, source = detect_major(pkgdir, pkg, dockerfile_text)

    musl = bool(FROM_NODE_ALPINE_RE.search(dockerfile_text)) if dockerfile_text else False
    flavor = 'alpine' if musl else 'glibc'
    image = f'node:{major}-alpine' if musl else f'node:{major}-bookworm-slim'

    note(f'package.json dir: {pkgdir}')
    note(f'Node major: {major} (source: {source})')
    note(f'libc flavor: {flavor}; image: {image}')

    pkg_json = pkgdir / 'package.json'
    pkg_lock = pkgdir / 'package-lock.json'

    # Defensive --ignore-scripts: lifecycle scripts can't run host code, and it does
    # not affect lockfile correctness.
    create = docker(
        'create', '-w', '/work',
        '-v', f'npm-cache-{flavor}:/root/.npm',
        image, 'npm', *npm_args, '--ignore-scripts',
        capture_output=True,
    )
    if create.returncode != 0:
        return fail(f'docker create failed: {create.stderr.strip()}', create.returncode or 1)
    cid = create.stdout.strip()

    try:
        cp_in = docker('cp', str(pkg_json), f'{cid}:/work/package.json', capture_output=True)
        if cp_in.returncode != 0:
            return fail(f'docker cp package.json in failed: {cp_in.stderr.strip()}')
        if pkg_lock.is_file():
            cp_lock = docker('cp', str(pkg_lock), f'{cid}:/work/package-lock.json', capture_output=True)
            if cp_lock.returncode != 0:
                return fail(f'docker cp package-lock.json in failed: {cp_lock.stderr.strip()}')

        note(f'running: npm {" ".join(npm_args)} --ignore-scripts (in {image})')
        run = docker('start', '-a', cid)  # stream output to our stdout/stderr
        rc = run.returncode

        if rc == 0:
            out = docker('cp', f'{cid}:/work/package.json', str(pkgdir) + '/', capture_output=True)
            if out.returncode != 0:
                return fail(f'docker cp package.json out failed: {out.stderr.strip()}')
            outl = docker('cp', f'{cid}:/work/package-lock.json', str(pkgdir) + '/', capture_output=True)
            if outl.returncode != 0:
                warn(f'package-lock.json not copied back ({outl.stderr.strip()}) — '
                     'npm may not have produced one for this command')
            note('lockfile updated on host; node_modules NOT materialized — re-sync '
                 'via your project docker flow (docker compose build / npm ci in dev container)')
        else:
            warn(f'npm exited {rc}; host package.json/package-lock.json left untouched')
        return rc
    finally:
        docker('rm', '-f', cid, capture_output=True)


if __name__ == '__main__':
    sys.exit(main())
