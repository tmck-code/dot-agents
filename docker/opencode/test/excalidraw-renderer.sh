#!/usr/bin/env bash
# Exercise the optional Excalidraw renderer sidecar through the agent network.
# Builds the Playwright-heavy image and needs network access to esm.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${IMAGE:-opencode-dev:local}"
COMPOSE=(docker compose -f stack/docker-compose.yml --profile tools)
tmp="$(mktemp -d /tmp/excalidraw-renderer.XXXXXX)"
squid_before="$(docker ps -q -f name=opencode-squid || true)"

cleanup() {
  "${COMPOSE[@]}" rm -sf excalidraw >/dev/null 2>&1 || true
  if [[ -z "$squid_before" ]]; then
    "${COMPOSE[@]}" stop squid >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || ! docker run --rm --entrypoint bash "$IMAGE" -lc 'command -v excalidraw-render' >/dev/null 2>&1; then
  echo "excalidraw-renderer: building $IMAGE" >&2
  make build
fi

cat > "$tmp/in.excalidraw" <<'EOF'
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [
    {
      "type": "rectangle", "id": "box", "x": 0, "y": 0, "width": 240, "height": 90,
      "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "#d3f9d8",
      "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
      "roughness": 0, "opacity": 100, "groupIds": [], "frameId": null,
      "roundness": {"type": 3}, "seed": 1, "version": 1, "versionNonce": 1,
      "isDeleted": false, "boundElements": null, "updated": 1, "link": null,
      "locked": false
    },
    {
      "type": "text", "id": "label", "x": 20, "y": 30, "width": 200, "height": 24,
      "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": "transparent",
      "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
      "roughness": 0, "opacity": 100, "groupIds": [], "frameId": null,
      "roundness": null, "seed": 2, "version": 1, "versionNonce": 2,
      "isDeleted": false, "boundElements": null, "updated": 1, "link": null,
      "locked": false, "text": "renderer ok", "originalText": "renderer ok",
      "fontSize": 20, "fontFamily": 8, "textAlign": "center",
      "verticalAlign": "middle", "containerId": null, "lineHeight": 1.25
    }
  ],
  "appState": {"viewBackgroundColor": "#ffffff", "gridSize": 20},
  "files": {}
}
EOF

echo "excalidraw-renderer: starting squid and the renderer"
"${COMPOSE[@]}" up -d --build --wait excalidraw

echo "excalidraw-renderer: checking the agent can reach the service"
docker run --rm --init --network opencode-agent \
  --entrypoint bash "$IMAGE" -lc \
  'curl -fsS http://excalidraw:8080/healthz >/dev/null'

echo "excalidraw-renderer: rendering PNG and SVG through the CLI"
docker run --rm --init --network opencode-agent \
  -v "$tmp:/work" --entrypoint bash "$IMAGE" -lc '
    set -euo pipefail
    excalidraw-render /work/in.excalidraw -o /work/out.png --transparent
    excalidraw-render /work/in.excalidraw -o /work/out.svg
  '

python3 - "$tmp/out.png" <<'PY'
import sys
from pathlib import Path
data = Path(sys.argv[1]).read_bytes()
if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) < 1000:
    raise SystemExit("renderer did not return a PNG")
PY
grep -q '<svg' "$tmp/out.svg" || { echo "excalidraw-renderer: SVG output missing" >&2; exit 1; }

echo "excalidraw-renderer: ok"
