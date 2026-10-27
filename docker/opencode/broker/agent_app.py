"""Agent-facing lease broker endpoints.

This listener is attached only to the internal agent network. It validates the
lease token, mints or returns short-lived credentials, and fails closed when a
lease is missing, malformed, expired or revoked.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException

from . import github, litellm
from .settings import Settings
from .store import Store, is_expired, parse_iso, utcnow

LEASE_PREFIX = "lst_"


def _litellm_base_url(settings: Settings) -> str:
    base = settings.litellm_url.rstrip("/")
    return base if base.endswith("/v1") else f"{base}/v1"


def _lease_view(lease: dict[str, Any]) -> dict[str, Any]:
    return {
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


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    store = Store(settings.db_path)
    app = FastAPI(
        title="OpenCode lease broker (agent)",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = settings
    app.state.store = store

    def require_lease(
        authorization: str | None = Header(default=None),
    ) -> dict[str, Any]:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="missing lease token")
        token = authorization.removeprefix("Bearer ").strip()
        if not token.startswith(LEASE_PREFIX) or "." not in token:
            store.event(None, "auth.reject", "malformed")
            raise HTTPException(status_code=401, detail="malformed lease token")
        lease = store.find_by_token(token)
        if not lease:
            store.event(None, "auth.reject", "unknown")
            raise HTTPException(status_code=401, detail="invalid lease token")
        if lease["status"] != "active":
            store.event(lease["lease_id"], "auth.reject", "revoked")
            raise HTTPException(status_code=403, detail="lease revoked")
        if is_expired(lease):
            store.event(lease["lease_id"], "auth.reject", "expired")
            raise HTTPException(status_code=403, detail="lease expired")
        store.touch(lease["lease_id"])
        return lease

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/leases/self")
    def lease_self(lease: dict[str, Any] = Depends(require_lease)) -> dict[str, Any]:
        return _lease_view(lease)

    @app.get("/v1/token/github")
    def github_token(
        lease: dict[str, Any] = Depends(require_lease),
    ) -> dict[str, Any]:
        if lease["service"] not in {"github", "all"}:
            raise HTTPException(status_code=403, detail="lease does not cover github")
        now = utcnow()
        cached = lease.get("github_token")
        cached_expiry = lease.get("github_token_expires_at")
        if cached and cached_expiry:
            expiry = parse_iso(cached_expiry)
            if expiry > now:
                remaining = (expiry - now).total_seconds()
                if remaining > settings.refresh_skew_seconds:
                    return {"token": cached, "expires_at": cached_expiry}
        if not settings.github_app_id:
            store.event(lease["lease_id"], "github.mint", "unconfigured")
            raise HTTPException(status_code=503, detail="GitHub App is not configured")
        resources: list[str] = lease["resources"]
        if not resources:
            raise HTTPException(status_code=403, detail="lease has no repositories")
        try:
            app = github.GitHubApp.from_file(
                settings.github_app_id, settings.github_private_key_file
            )
            installation_id = settings.github_installation_id
            if not installation_id:
                owner, repo = resources[0].split("/", 1)
                installation_id = github.find_installation(
                    app,
                    owner,
                    repo,
                    api_url=settings.github_api_url,
                    timeout=settings.request_timeout_seconds,
                )
            payload = github.mint_installation_token(
                app_id=settings.github_app_id,
                private_key_pem=app.private_key_pem,
                installation_id=installation_id,
                repositories=resources,
                permissions=github.repo_permissions(lease["actions"]),
                api_url=settings.github_api_url,
                timeout=settings.request_timeout_seconds,
            )
        except github.GitHubError as exc:
            store.event(
                lease["lease_id"], "github.mint", "error", {"reason": str(exc)}
            )
            raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
        store.set_github_token(
            lease["lease_id"], payload["token"], payload["expires_at"]
        )
        store.event(lease["lease_id"], "github.mint", "ok")
        return {"token": payload["token"], "expires_at": payload["expires_at"]}

    @app.get("/v1/token/litellm")
    def litellm_key(
        lease: dict[str, Any] = Depends(require_lease),
    ) -> dict[str, Any]:
        if lease["service"] not in {"litellm", "all"}:
            raise HTTPException(status_code=403, detail="lease does not cover litellm")
        if lease.get("litellm_key"):
            return {"key": lease["litellm_key"], "base_url": _litellm_base_url(settings)}
        models: list[str] = lease["models"] or list(settings.litellm_models)
        if not models:
            raise HTTPException(status_code=403, detail="lease has no model scope")
        try:
            key = litellm.create_virtual_key(
                base_url=settings.litellm_url,
                master_key=settings.litellm_master_key,
                lease_id=lease["lease_id"],
                models=models,
                budget_usd=lease["budget_usd"],
                duration_seconds=max(
                    60,
                    int(
                        (
                            parse_iso(lease["expires_at"]) - datetime.now(timezone.utc)
                        ).total_seconds()
                    ),
                ),
                timeout=settings.request_timeout_seconds,
            )
        except litellm.LiteLLMError as exc:
            store.event(
                lease["lease_id"], "litellm.key", "error", {"reason": str(exc)}
            )
            raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
        store.set_litellm_key(lease["lease_id"], key)
        store.event(lease["lease_id"], "litellm.key", "ok")
        return {"key": key, "base_url": _litellm_base_url(settings)}

    return app

