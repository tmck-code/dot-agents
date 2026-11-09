"""Structured log lines for the broker.

One JSON object per line on standard output. Secret values are never written.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from typing import Any

SECRET_KEYS = frozenset(
    {"token", "lease_token", "litellm_key", "private_key", "values"}
)
DENY_RESULTS = frozenset(
    {"malformed", "unknown", "revoked", "expired", "unconfigured", "deny"}
)


def outcome_for(result: str) -> str:
    """Map a stored event result string to a schema outcome."""
    if result == 'ok':
        return 'ok'
    if result in DENY_RESULTS:
        return 'deny'
    if result == 'error':
        return 'error'
    return 'warn'


def strip_secrets(detail: Any) -> Any:
    if not isinstance(detail, dict):
        return detail
    return {k: v for k, v in detail.items() if k not in SECRET_KEYS}


def _timestamp() -> str:
    stamp = datetime.now(timezone.utc).isoformat(timespec='milliseconds')
    return stamp.replace('+00:00', 'Z')


def emit(
    component: str,
    event: str,
    lease_id: str | None,
    repo: str | None,
    outcome: str,
    detail: Any = None,
) -> None:
    safe = strip_secrets(detail)
    record = {
        'ts': _timestamp(),
        'component': component,
        'event': event,
        'lease_id': lease_id,
        'repo': repo,
        'outcome': outcome,
        'detail': safe if isinstance(safe, dict) else {},
    }
    line = json.dumps(record, separators=(",", ":"), default=str)
    print(line, file=sys.stdout, flush=True)
