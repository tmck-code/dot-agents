# syntax=docker/dockerfile:1.7
#
# The broker runs with a read-only rootfs and a dedicated state volume. Both
# the agent-facing and admin-facing services use this image with different
# uvicorn modules and compose networks.
FROM python:3.12-slim@sha256:12316debbfb86890f6b2d825820612741ba527ad5a44e3902759141d572bfe8f

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY . /app/broker

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin broker \
 && mkdir -p /state \
 && chown broker:broker /state

USER 10001
EXPOSE 8080 8081

CMD ["uvicorn", "broker.agent_app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
