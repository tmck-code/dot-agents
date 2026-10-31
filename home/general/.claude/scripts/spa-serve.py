#!/usr/bin/env python3
'''Serve the newest SPA over the LAN so a phone or laptop can open it.

A session that runs over ssh cannot hand out `file:///` URLs. This starts a
detached `python3 -m http.server` bound to 0.0.0.0, serving the directory that
holds the SPA, and prints the LAN URL.

    spa-serve.py [FILE] [-p PORT] [-r ROOT] [--bind ADDR]
    spa-serve.py --list
    spa-serve.py --stop [PORT|all]

FILE   html file to serve. Default: the newest *.html under the cwd,
       /tmp/opencode and ~/.claude. A directory is served as-is.
ROOT   directory to serve. Default: FILE's directory. Pass the parent when the
       html loads assets from outside its own directory.
PORT   preferred port, default $SPA_SERVE_PORT or 8000. The next free port is
       used when it is taken.

Registry: <tmp>/spa-serve-<uid>/<port>.json, one file per running server. A run
for a directory that is already served reuses that server.
'''
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_PORT = int(os.environ.get('SPA_SERVE_PORT', '8000'))
PORT_TRIES   = 20
SEARCH_DEPTH = 5
READY_SECS   = 5.0
STOP_SECS    = 3.0
HTM_SUFFIXES = {'.html', '.htm'}
SKIP_DIRS    = {
    '.git', '.hg', '.svn', '.cache', '.venv', 'venv', '__pycache__',
    'site-packages', 'node_modules', 'htmlcov',
}
REGISTRY = Path(tempfile.gettempdir()) / f'spa-serve-{os.getuid()}'


def search_roots():
    return (
        Path.cwd(),
        Path(tempfile.gettempdir()) / 'opencode',
        Path.home() / '.claude',
    )


def find_html(roots, depth=SEARCH_DEPTH):
    '''Newest .html file under the roots, by mtime. None when there is none.'''
    newest_mtime, newest_path = 0.0, None
    for root in roots:
        if not root.is_dir():
            continue
        base = len(root.resolve().parts)
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda _: None):
            here = Path(dirpath)
            if len(here.parts) - base >= depth:
                dirnames[:] = []
            else:
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if Path(name).suffix.lower() not in HTM_SUFFIXES:
                    continue
                path = here / name
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime > newest_mtime:
                    newest_mtime, newest_path = mtime, path
    return newest_path


def lan_ip():
    '''Local address a peer on the same network can reach. Sends no packets.'''
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(('192.0.2.1', 9))
            ip = sock.getsockname()[0]
        except OSError:
            ip = ''
    if ip and not ip.startswith('127.'):
        return ip
    for cmd in (['ipconfig', 'getifaddr', 'en0'], ['hostname', '-I']):
        try:
            words = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=2,
            ).stdout.split()
        except (OSError, subprocess.SubprocessError):
            continue
        for word in words:
            if word and not word.startswith('127.'):
                return word.split('%')[0]
    return '127.0.0.1'


def is_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(('', port))
        except OSError:
            return False
    return True


def pick_port(preferred):
    for port in range(preferred, preferred + PORT_TRIES):
        if is_free(port):
            return port
    raise SystemExit(f'no free port in {preferred}-{preferred + PORT_TRIES - 1}')


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except (OSError, ValueError, TypeError):
        return False
    return True


def entry_path(port):
    return REGISTRY / f'{port}.json'


def read_entries():
    '''Live servers from the registry. Dead entries are removed.'''
    entries = []
    for path in sorted(REGISTRY.glob('*.json')):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not pid_alive(entry.get('pid')):
            path.unlink(missing_ok=True)
            continue
        entries.append(entry)
    return entries


def find_server(root, bind):
    '''A live server already serving this directory, or None.'''
    wanted = root.resolve()
    for entry in read_entries():
        if Path(entry['root']).resolve() != wanted:
            continue
        if entry.get('bind', '0.0.0.0') != bind:
            continue
        return entry
    return None


def urls(port, rel, bind='0.0.0.0'):
    path = urllib.parse.quote(rel, safe='/')
    ip = '127.0.0.1' if bind == '127.0.0.1' else lan_ip()
    return (
        f'http://127.0.0.1:{port}/{path}',
        f'http://{ip}:{port}/{path}',
    )


def wait_ready(url, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                return response.status < 400
        except (urllib.error.URLError, OSError):
            time.sleep(0.1)
    return False


def last_log_lines(path, count=10):
    try:
        lines = path.read_text(errors='replace').splitlines()
    except OSError:
        return ''
    return '\n'.join(lines[-count:])


def report(entry, reused):
    print(f'root:  {entry["root"]}')
    print(f'file:  {entry["rel"] or "directory listing"}')
    print(f'pid:   {entry["pid"]}')
    print(f'log:   {entry["log"]}')
    print(f'local: {entry["local"]}')
    print(f'lan:   {entry["url"]}')
    if reused:
        print('note: reused the server already serving this directory')


def expose_note(root):
    '''Warn when the served directory holds more than the artifact.'''
    try:
        crowded = sum(1 for _ in root.iterdir()) > 25
    except OSError:
        crowded = False
    if root == Path.home() or (root / '.git').exists() or crowded:
        print(
            f'note: {root} is exposed on the LAN; every file in it is reachable '
            'and directory listing is on, with no auth'
        )


def serve(args):
    if args.file:
        target = Path(args.file).expanduser().resolve()
        if not target.exists():
            raise SystemExit(f'no such file or directory: {target}')
    else:
        target = find_html(search_roots())
        if target is None:
            roots = ', '.join(str(r) for r in search_roots())
            raise SystemExit(f'no .html found under {roots}; pass a path')

    if target.is_dir():
        root = target
        rel = 'index.html' if (root / 'index.html').is_file() else ''
    else:
        root = Path(args.root).expanduser().resolve() if args.root else target.parent
        try:
            rel = target.relative_to(root).as_posix()
        except ValueError:
            raise SystemExit(
                f'{target} is outside {root}; pass -r with a directory that holds it'
            )

    entry = find_server(root, args.bind)
    if entry:
        local, lan = urls(entry['port'], rel, entry.get('bind', '0.0.0.0'))
        entry = {**entry, 'rel': rel, 'local': local, 'url': lan}
        entry_path(entry['port']).write_text(json.dumps(entry, indent=2) + '\n')
        report(entry, reused=True)
        return 0

    REGISTRY.mkdir(parents=True, exist_ok=True)
    port = pick_port(args.port)
    log_path = REGISTRY / f'{port}.log'
    with log_path.open('ab') as log:
        proc = subprocess.Popen(
            [
                sys.executable, '-m', 'http.server', str(port),
                '--bind', args.bind, '--directory', str(root),
            ],
            cwd=root,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    local, lan = urls(port, rel, args.bind)
    ip = urllib.parse.urlsplit(lan).hostname
    entry = {
        'pid':   proc.pid,
        'port':  port,
        'root':  str(root),
        'rel':   rel,
        'local': local,
        'url':   lan,
        'bind':  args.bind,
        'log':   str(log_path),
        'file':  str(target),
    }
    entry_path(port).write_text(json.dumps(entry, indent=2) + '\n')

    if not wait_ready(entry['local'], READY_SECS):
        if not pid_alive(proc.pid):
            entry_path(port).unlink(missing_ok=True)
            raise SystemExit(
                f'server exited at once:\n{last_log_lines(log_path)}'
            )
        print(f'note: {entry["local"]} did not answer within {READY_SECS:.0f}s')

    report(entry, reused=False)
    if port != args.port:
        print(f'note: port {args.port} was taken; using {port}')
    expose_note(root)
    if args.bind == '127.0.0.1':
        print('note: bound to 127.0.0.1; only this machine can reach it')
    elif ip.startswith('127.'):
        print('note: no LAN address found; use ssh -L to forward the port')
    elif not wait_ready(entry['url'], 2.0):
        print('note: the LAN URL did not answer from this host; a firewall may block it')
    print('note: the server keeps running after this turn; stop it with --stop ' + str(port))
    return 0


def list_servers():
    entries = read_entries()
    if not entries:
        print('no servers')
        return 0
    for entry in sorted(entries, key=lambda e: e['port']):
        print(
            f'{entry["port"]:>5}  pid {entry["pid"]:<7} {entry["url"]}  '
            f'({entry["root"]})'
        )
    return 0


def stop_servers(target):
    entries = read_entries()
    if target not in ('', 'all', None):
        try:
            port = int(target)
        except ValueError:
            raise SystemExit(f'not a port: {target}')
        entries = [e for e in entries if e['port'] == port]
    if not entries:
        print('nothing to stop')
        return 0
    for entry in entries:
        pid = entry['pid']
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + STOP_SECS
        while time.monotonic() < deadline and pid_alive(pid):
            time.sleep(0.1)
        if pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        entry_path(entry['port']).unlink(missing_ok=True)
        print(f'stopped port {entry["port"]} (pid {pid})')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog='spa-serve.py',
        description='Serve the newest SPA over the LAN and print its URL.',
    )
    parser.add_argument('file', nargs='?', help='html file or directory to serve')
    parser.add_argument(
        '-p', '--port',
        type=int,
        default=DEFAULT_PORT,
        help=f'preferred port (default {DEFAULT_PORT})',
    )
    parser.add_argument(
        '-r', '--root',
        help="directory to serve (default: the html file's directory)",
    )
    parser.add_argument(
        '--bind',
        default='0.0.0.0',
        help='address to bind (default 0.0.0.0)',
    )
    parser.add_argument(
        '-l', '--list',
        action='store_true',
        help='list servers started by this script',
    )
    parser.add_argument(
        '-s', '--stop',
        nargs='?',
        const='all',
        metavar='PORT',
        help='stop one server, or every server with no port',
    )
    args = parser.parse_args(argv)
    if args.list:
        return list_servers()
    if args.stop is not None:
        return stop_servers(args.stop)
    return serve(args)


if __name__ == '__main__':
    sys.exit(main())
