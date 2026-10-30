# syntax=docker/dockerfile:1.7
#
# Excalidraw renderer sidecar. Based on the same Playwright image as the
# upstream skill, with a tiny FastAPI wrapper so the agent can POST a document
# and receive PNG/SVG bytes without a Docker socket.
FROM mcr.microsoft.com/playwright/python:v1.61.0-noble@sha256:a9731514f24121d1dcd25d58d0a38146646d290a5998fd80d3e533e7b5e21c69

ENV HOME=/tmp \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install --no-cache-dir --break-system-packages \
      fastapi==0.115.6 \
      uvicorn==0.34.0 \
      playwright==1.61.0

WORKDIR /app
COPY server.py render_excalidraw.py render_template.html /app/

USER 1000:1000
EXPOSE 8080
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
