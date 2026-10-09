# Rendering needs network access (esm.sh bundle and fonts are fetched at render time).
# Build: docker build -t excalidraw-render .   (from this directory; context = skill dir)
# Run:   docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/data" excalidraw-render in.excalidraw --output out.png
FROM mcr.microsoft.com/playwright/python:v1.61.0-noble
RUN pip install --no-cache-dir --break-system-packages playwright==1.61.0
WORKDIR /work
COPY references/render_excalidraw.py references/render_template.html ./
WORKDIR /data
ENTRYPOINT ["python3", "/work/render_excalidraw.py"]
