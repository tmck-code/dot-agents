#!/usr/bin/env python3
"""Static file server with HTTP Range support (single byte range).

Same command line as `python3 -m http.server`: PORT [--bind ADDR] [--directory DIR].
Browsers need Range responses (206) to seek <video> elements.
POST /_feedback (any path ending in it) stores gallery feedback under <root>/_feedback/.
"""
import argparse
import functools
import json
import os
import re
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

RANGE_RE = re.compile(r'bytes=(\d*)-(\d*)$')
FEEDBACK_MAX = 256 * 1024
FEEDBACK_DIR = "_feedback"
GALLERY_BAD = re.compile(r"[^a-z0-9._-]")
_feedback_lock = threading.Lock()


class RangeHandler(SimpleHTTPRequestHandler):
    def send_head(self):
        self._range = None
        header = self.headers.get('Range')
        path = self.translate_path(self.path)
        if not header or os.path.isdir(path):
            return super().send_head()
        match = RANGE_RE.match(header.strip())
        if not match:
            return super().send_head()
        try:
            f = open(path, 'rb')
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND, 'File not found')
            return None
        size = os.fstat(f.fileno()).st_size
        first, last = match.groups()
        if first == '':
            if last == '':
                f.close()
                return super().send_head()
            start, end = max(0, size - int(last)), size - 1
        else:
            start = int(first)
            end = min(int(last), size - 1) if last else size - 1
        if start >= size or start > end:
            f.close()
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self.send_header('Content-Range', f'bytes */{size}')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return None
        self._range = (start, end)
        self.send_response(HTTPStatus.PARTIAL_CONTENT)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        f.seek(start)
        return f

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        """Only POST <any path>/_feedback is accepted; it writes under <root>/_feedback/ only."""
        if self.path.split("?", 1)[0].split("#", 1)[0].rstrip("/").rsplit("/", 1)[-1] != "_feedback":
            self.send_response(HTTPStatus.METHOD_NOT_ALLOWED)
            self.send_header("Allow", "GET, HEAD")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            return self._json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "Content-Type must be application/json"})
        try:
            length = int(self.headers.get("Content-Length") or "")
        except ValueError:
            return self._json(HTTPStatus.LENGTH_REQUIRED, {"error": "Content-Length required"})
        if length < 0 or length > FEEDBACK_MAX:
            return self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "body over %d bytes" % FEEDBACK_MAX})
        raw = self.rfile.read(length)
        try:
            doc = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "body is not valid JSON"})
        if not isinstance(doc, dict) or not isinstance(doc.get("gallery"), str):
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "need a JSON object with a string gallery"})
        gallery = GALLERY_BAD.sub("_", doc["gallery"].lower()).lstrip(".")[:64]
        if not gallery:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "gallery is empty after sanitising"})
        root = os.path.realpath(self.directory)
        gdir = os.path.join(root, FEEDBACK_DIR, gallery)
        if not os.path.realpath(gdir).startswith(os.path.join(root, FEEDBACK_DIR) + os.sep):
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "bad gallery"})
        stamp = datetime.now(timezone.utc)
        data = json.dumps(doc, indent=2, ensure_ascii=False).encode("utf-8")
        with _feedback_lock:
            os.makedirs(gdir, exist_ok=True)
            name = stamp.strftime("%Y%m%dT%H%M%S.%fZ") + ".json"
            rel = "%s/%s/%s" % (FEEDBACK_DIR, gallery, name)
            for fname in (name, "latest.json"):
                with open(os.path.join(gdir, fname), "wb") as f:
                    f.write(data)
            issue = doc.get("issue")
            issue = issue if isinstance(issue, (int, str)) and not isinstance(issue, bool) else "?"
            line = "%s %s issue=%s %s\n" % (stamp.strftime("%Y-%m-%dT%H:%M:%SZ"), gallery, str(issue).replace("\n", " ")[:20], rel)
            with open(os.path.join(root, FEEDBACK_DIR, "events.log"), "a", encoding="utf-8") as f:
                f.write(line)
            count = len([n for n in os.listdir(gdir) if n.endswith(".json") and n != "latest.json"])
        self._json(HTTPStatus.CREATED, {"saved": rel, "count": count})

    def end_headers(self):
        if not getattr(self, '_range', None):
            self.send_header('Accept-Ranges', 'bytes')
        super().end_headers()

    def copyfile(self, source, outputfile):
        rng = getattr(self, '_range', None)
        if not rng:
            return super().copyfile(source, outputfile)
        remaining = rng[1] - rng[0] + 1
        while remaining > 0:
            chunk = source.read(min(64 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('port', type=int)
    parser.add_argument('--bind', default='0.0.0.0')
    parser.add_argument('--directory', default=os.getcwd())
    args = parser.parse_args()
    handler = functools.partial(RangeHandler, directory=args.directory)
    with ThreadingHTTPServer((args.bind, args.port), handler) as server:
        print(f'Serving {args.directory} on {args.bind}:{args.port} (Range enabled)', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
