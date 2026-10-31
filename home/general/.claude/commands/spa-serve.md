---
description: Serve the newest SPA over the LAN and hand back an http:// URL for a phone or laptop.
argument-hint: [html file] [port]
allowed-tools: Bash(python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/spa-serve.py":*)
---

Serve the SPA over HTTP so the user can open it from another device in the house. The session runs over ssh, so a `file:///` URL does not reach that device.

## Pick the file

- `$ARGUMENTS` may name the html file (or a directory) and a port. Pass them through.
- With no argument, serve the most recent SPA you made in this session. Name the file you chose.
- If this session made none, run without a file: the script picks the newest `.html` under the cwd, `/tmp/opencode` and `~/.claude`, and prints it.

## Run

```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/spa-serve.py" [FILE] [-p PORT]
```

The script does the rest:

- starts a detached `python3 -m http.server` bound to `0.0.0.0`, serving the file's directory;
- reuses a server it already started for that directory;
- walks up from port 8000 when the port is taken;
- prints `lan:`, `local:`, `root:`, `file:`, `pid:` and `log:`.

## Report

- Give the `lan:` URL in a fenced code block, on its own. That URL is the deliverable.
- Name the served file and directory. `local:` works on this machine only.
- Give the stop command: `python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/spa-serve.py" --stop <port>`.
- Say the server keeps running after this turn and after the ssh session ends.

## When it does not work

- A `note: ... did not answer` line, or the device cannot load the URL: the host firewall is the likely cause. Linux: `sudo ufw allow <port>/tcp`. macOS: allow incoming connections for `python3`.
- No LAN address was found: say so, and give `ssh -L <port>:localhost:<port> <host>` instead.
- The page loads assets from outside the html's own directory: rerun with `-r <parent directory>`.
- A `note:` says the directory is exposed on the LAN: say plainly that every file in it is reachable, with no auth and directory listing on. Offer to copy the html into a clean directory and serve that.
- A repo hook blocks `python3` on the host: the script lives under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, which `host-exec-guard.py` allows as user tooling. Run it as written; do not fall back to a Docker or nginx server.
- The requested file is outside the chosen root: the script exits with the fix; pass `-r` with a directory that holds the file.

Done when the user has the `lan:` URL in a code block, knows which file is served, and knows how to stop the server.
