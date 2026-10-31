# Excalidraw renderer sidecar

Small FastAPI wrapper around the `excalidraw-diagram` skill's Playwright
renderer. The agent posts an `.excalidraw` document and receives PNG or SVG
bytes, without a Docker socket and without direct internet access.

`render_excalidraw.py` and `render_template.html` are vendored from the local
skill at `~/.claude/skills/excalidraw-diagram/references/`; keep them in sync
when the skill changes. The sidecar adds a proxy-aware Chromium launch and
`--no-sandbox` for the read-only, capability-dropped container.

Build and run through the stack:

```bash
make excalidraw-up
make excalidraw-down
test-excalidraw
```

API:

```text
GET  /healthz
POST /render?format=png|svg&scale=1&width=1920&transparent=false&dark=false
Body: an Excalidraw JSON document
```

`esm.sh` is the only external dependency and is allowlisted in Squid.
