"""LiteLLM virtual-key management.

Provider root keys live in LiteLLM. The broker asks LiteLLM for a per-lease
key with a model allowlist, budget and duration, and revokes it when the lease
is revoked.
"""

from __future__ import annotations

from typing import Any

import httpx


class LiteLLMError(RuntimeError):
    def __init__(self, message: str, status: int = 503) -> None:
        super().__init__(message)
        self.status = status


def _url(base: str, path: str) -> str:
    return f"{base.rstrip('/')}/{path.lstrip('/')}"


def create_virtual_key(
    *,
    base_url: str,
    master_key: str,
    lease_id: str,
    models: list[str],
    budget_usd: float | None,
    duration_seconds: int,
    timeout: float = 15.0,
) -> str:
    if not master_key:
        raise LiteLLMError("LITELLM_MASTER_KEY is not configured", 503)
    body: dict[str, Any] = {
        "key_alias": f"lease-{lease_id}",
        "duration": f"{max(60, duration_seconds)}s",
        "metadata": {"lease_id": lease_id},
        "models": models or [],
    }
    if budget_usd is not None:
        body["max_budget"] = float(budget_usd)
    try:
        response = httpx.post(
            _url(base_url, "/key/generate"),
            headers={"Authorization": f"Bearer {master_key}"},
            json=body,
            timeout=timeout,
        )
    except httpx.HTTPError as exc:
        raise LiteLLMError(f"LiteLLM key request failed: {exc}") from exc
    if response.status_code not in {200, 201}:
        raise LiteLLMError(
            f"LiteLLM key request returned {response.status_code}", 503
        )
    key = response.json().get("key")
    if not key:
        raise LiteLLMError("LiteLLM key response was missing the key", 503)
    return str(key)


def delete_virtual_key(
    *,
    base_url: str,
    master_key: str,
    key: str,
    timeout: float = 15.0,
) -> bool:
    if not master_key or not key:
        return False
    try:
        response = httpx.post(
            _url(base_url, "/key/delete"),
            headers={"Authorization": f"Bearer {master_key}"},
            json={"keys": [key]},
            timeout=timeout,
        )
    except httpx.HTTPError:
        return False
    return response.status_code in {200, 201, 204}
