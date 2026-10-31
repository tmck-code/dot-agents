"""Small HTTP wrapper around the Excalidraw diagram renderer.

The renderer image is a one-shot CLI. This service lets the OpenCode container
post an `.excalidraw` document and receive a PNG or SVG without exposing the
host Docker socket or the open internet to the agent.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Request, Response
from starlette.concurrency import run_in_threadpool

from render_excalidraw import render

MAX_BODY_BYTES = 10 * 1024 * 1024

app = FastAPI(
    title="OpenCode Excalidraw renderer",
    version="0.1.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/render")
async def render_diagram(
    request: Request,
    output: str = Query("png", alias="format", pattern="^(png|svg)$"),
    scale: int = Query(1, ge=1, le=4),
    width: int = Query(1920, ge=320, le=8192),
    transparent: bool = Query(False),
    dark: bool = Query(False),
) -> Response:
    body = await request.body()
    if len(body) > MAX_BODY_BYTES:
        raise HTTPException(status_code=413, detail="document is too large")
    try:
        document = json.loads(body)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail=f"invalid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise HTTPException(status_code=400, detail="body must be an Excalidraw document")

    workdir = Path(tempfile.mkdtemp(prefix="excalidraw-"))
    try:
        input_path = workdir / "input.excalidraw"
        png_path = workdir / "diagram.png"
        svg_path = workdir / "diagram.svg"
        input_path.write_text(json.dumps(document), encoding="utf-8")
        try:
            await run_in_threadpool(
                render,
                input_path,
                png_path,
                scale=scale,
                max_width=width,
                transparent=transparent,
                dark=dark,
                svg_path=svg_path,
            )
        except SystemExit as exc:
            raise HTTPException(
                status_code=400, detail="renderer rejected the document"
            ) from exc
        if output == "svg":
            return Response(
                content=svg_path.read_bytes(),
                media_type="image/svg+xml",
                headers={"Content-Disposition": 'inline; filename="diagram.svg"'},
            )
        return Response(
            content=png_path.read_bytes(),
            media_type="image/png",
            headers={"Content-Disposition": 'inline; filename="diagram.png"'},
        )
    except HTTPException:
        raise
    except Exception as exc:  # pragma: no cover - exercised through the API
        raise HTTPException(status_code=500, detail=f"render failed: {exc}") from exc
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
