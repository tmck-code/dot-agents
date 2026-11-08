"""Host-only lease administration endpoints.

The admin listener is published to ``127.0.0.1`` only and is not attached to
the internal agent network. Every request needs the admin token.
"""

from __future__ import annotations

import hmac
import re
from datetime import timedelta
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from . import litellm
from .settings import Settings
from .store import Store, is_active, parse_iso, utcnow

SERVICES = {"github", "litellm", "all"}
RESERVED_SERVICES = frozenset({"github", "litellm", "all"})
SERVICE_NAME = re.compile(r"^[a-z][a-z0-9-]{1,31}$")


class LeaseRequest(BaseModel):
    session: str = Field(min_length=1, max_length=200)
    service: str = "all"
    resources: list[str] = Field(default_factory=list)
    actions: list[str] = Field(default_factory=lambda: ["contents:read"])
    ttl_seconds: int | None = None
    models: list[str] = Field(default_factory=list)
    budget_usd: float | None = None


class GrantRequest(BaseModel):
    service: str
    ttl_seconds: int | None = None
    values: dict[str, str] = Field(default_factory=dict)


def _view(
    lease: dict[str, Any], grants: list[dict[str, Any]] | None = None
) -> dict[str, Any]:
    view = {
        key: lease[key]
        for key in (
            "lease_id",
            "session",
            "service",
            "resources",
            "actions",
            "models",
            "budget_usd",
            "created_at",
            "expires_at",
            "status",
            "last_used_at",
        )
    }
    view["grants"] = [
        {"service": grant["service"], "expires_at": grant["expires_at"]}
        for grant in grants or []
    ]
    return view


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    store = Store(settings.db_path)
    app = FastAPI(
        title="OpenCode lease broker (admin)",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = settings
    store.component = "broker-admin"
    app.state.store = store

    def require_admin(x_admin_token: str | None = Header(default=None)) -> None:
        if not settings.admin_token:
            raise HTTPException(status_code=503, detail="admin token is not configured")
        supplied = (x_admin_token or "").encode()
        if not x_admin_token or not hmac.compare_digest(
            supplied, settings.admin_token.encode()
        ):
            store.event(None, "admin.auth", "deny", {})
            raise HTTPException(status_code=401, detail="invalid admin token")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/v1/leases", dependencies=[Depends(require_admin)])
    def create_lease(body: LeaseRequest) -> dict[str, Any]:
        if body.service not in SERVICES:
            raise HTTPException(
                status_code=422,
                detail=f"service must be one of {sorted(SERVICES)}",
            )
        if body.service in {"github", "all"} and not body.resources:
            raise HTTPException(
                status_code=422, detail="github leases need at least one owner/repo"
            )
        if any("/" not in item for item in body.resources):
            raise HTTPException(
                status_code=422, detail="resources must be owner/repo"
            )
        models = body.models or list(settings.litellm_models)
        if body.service in {"litellm", "all"} and not models:
            raise HTTPException(
                status_code=422, detail="litellm leases need at least one model"
            )
        ttl = body.ttl_seconds or settings.default_ttl_seconds
        if ttl <= 0 or ttl > settings.max_ttl_seconds:
            raise HTTPException(
                status_code=422,
                detail=f"ttl_seconds must be between 1 and {settings.max_ttl_seconds}",
            )
        lease = store.create(
            session=body.session,
            service=body.service,
            resources=body.resources,
            actions=body.actions,
            ttl_seconds=ttl,
            models=models,
            budget_usd=body.budget_usd,
        )
        if body.service in {"litellm", "all"}:
            try:
                key = litellm.create_virtual_key(
                    base_url=settings.litellm_url,
                    keygen_key=settings.litellm_keygen_key,
                    lease_id=lease["lease_id"],
                    models=models,
                    budget_usd=body.budget_usd,
                    duration_seconds=ttl,
                    timeout=settings.request_timeout_seconds,
                )
            except litellm.LiteLLMError as exc:
                store.revoke(lease["lease_id"])
                store.event(
                    lease["lease_id"],
                    "litellm.key",
                    "error",
                    {"reason": str(exc)},
                )
                raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
            store.set_litellm_key(lease["lease_id"], key)
            store.event(lease["lease_id"], "litellm.key", "ok")
            lease["litellm_key"] = key
        return lease

    @app.get("/v1/leases", dependencies=[Depends(require_admin)])
    def list_leases() -> dict[str, Any]:
        return {
            "leases": [
                _view(lease, store.list_grants(lease["lease_id"]))
                for lease in store.list_active()
            ]
        }

    @app.get("/v1/leases/{lease_id}", dependencies=[Depends(require_admin)])
    def get_lease(lease_id: str) -> dict[str, Any]:
        lease = store.get(lease_id)
        if not lease:
            raise HTTPException(status_code=404, detail="lease not found")
        return _view(lease, store.list_grants(lease_id))

    @app.post("/v1/leases/{lease_id}/revoke", dependencies=[Depends(require_admin)])
    def revoke_lease(lease_id: str) -> dict[str, Any]:
        lease = store.get(lease_id)
        if not lease:
            raise HTTPException(status_code=404, detail="lease not found")
        if lease.get("litellm_key"):
            litellm.delete_virtual_key(
                base_url=settings.litellm_url,
                keygen_key=settings.litellm_keygen_key,
                key=lease["litellm_key"],
                timeout=settings.request_timeout_seconds,
            )
        lease = store.revoke(lease_id)
        store.clear_credentials(lease_id)

        assert lease is not None
        return _view(lease, [])

    @app.post(
        "/v1/leases/{lease_id}/grants", dependencies=[Depends(require_admin)]
    )
    def create_grant(lease_id: str, body: GrantRequest) -> dict[str, Any]:
        if body.service in RESERVED_SERVICES or not SERVICE_NAME.match(body.service):
            raise HTTPException(
                status_code=422,
                detail="service must match ^[a-z][a-z0-9-]{1,31}$ and not be reserved",
            )
        if not body.values:
            raise HTTPException(status_code=422, detail="values must not be empty")
        lease = store.get(lease_id)
        if not lease:
            raise HTTPException(status_code=404, detail="lease not found")
        if not is_active(lease):
            raise HTTPException(status_code=409, detail="lease is not active")
        requested = body.ttl_seconds or settings.default_grant_ttl_seconds
        if requested <= 0:
            raise HTTPException(status_code=422, detail="ttl_seconds must be positive")
        now = utcnow()
        remaining = (parse_iso(lease["expires_at"]) - now).total_seconds()
        ttl = min(requested, settings.max_grant_ttl_seconds, int(remaining))
        grant = store.grant(
            lease_id,
            body.service,
            body.values,
            now + timedelta(seconds=ttl),
            now=now,
        )
        store.event(
            lease_id,
            "lease.grant",
            "ok",
            {
                "service": body.service,
                "grant_id": grant["grant_id"],
                "expires_at": grant["expires_at"],
            },
        )
        return grant

    @app.delete(
        "/v1/leases/{lease_id}/grants/{service}",
        dependencies=[Depends(require_admin)],
    )
    def delete_grant(lease_id: str, service: str) -> dict[str, Any]:
        if not store.get(lease_id):
            raise HTTPException(status_code=404, detail="lease not found")
        if not store.revoke_grant(lease_id, service):
            raise HTTPException(status_code=404, detail="grant not found")
        store.event(lease_id, "lease.ungrant", "ok", {"service": service})
        return {"lease_id": lease_id, "service": service, "status": "revoked"}

    return app
