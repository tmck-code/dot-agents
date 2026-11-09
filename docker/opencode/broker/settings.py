"""Runtime configuration for the lease broker.

Configuration is read from the environment. Secrets are read from files named
by the environment. The same image runs as the agent-facing broker and as the
host-only admin service.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _secret(file_var: str, env_var: str) -> str:
    """Read a secret from the file named by file_var, else from env_var."""
    path = os.getenv(file_var, "")
    if path:
        return Path(path).read_text(encoding="utf-8").strip()
    return os.getenv(env_var, "").strip()


@dataclass(frozen=True)
class Settings:
    db_path: str = "/state/broker.db"
    admin_token: str = ""
    github_app_id: str = ""
    github_installation_id: str = ""
    github_private_key_file: str = "/run/secrets/github-app.pem"
    github_api_url: str = "https://api.github.com"
    litellm_url: str = "http://litellm:4000"
    litellm_keygen_key: str = ""
    litellm_models: tuple[str, ...] = ()
    default_ttl_seconds: int = 8 * 60 * 60
    max_ttl_seconds: int = 24 * 60 * 60
    refresh_skew_seconds: int = 5 * 60
    max_grant_ttl_seconds: int = 3600
    default_grant_ttl_seconds: int = 900
    request_timeout_seconds: float = 15.0
    public_url: str = "http://broker:8080"
    extra: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_env(cls) -> "Settings":
        models = tuple(
            item.strip()
            for item in os.getenv("LITELLM_MODELS", "").split(",")
            if item.strip()
        )
        return cls(
            db_path=os.getenv("BROKER_DB", cls.db_path),
            admin_token=_secret("BROKER_ADMIN_TOKEN_FILE", "BROKER_ADMIN_TOKEN"),
            github_app_id=os.getenv("GITHUB_APP_ID", ""),
            github_installation_id=os.getenv("GITHUB_INSTALLATION_ID", ""),
            github_private_key_file=os.getenv(
                "GITHUB_APP_PRIVATE_KEY_FILE", cls.github_private_key_file
            ),
            github_api_url=os.getenv("GITHUB_API_URL", cls.github_api_url),
            litellm_url=os.getenv("LITELLM_URL", cls.litellm_url).rstrip("/"),
            litellm_keygen_key=_secret(
                "LITELLM_KEYGEN_KEY_FILE", "LITELLM_KEYGEN_KEY"
            ),
            litellm_models=models,
            default_ttl_seconds=int(
                os.getenv("BROKER_DEFAULT_TTL_SECONDS", cls.default_ttl_seconds)
            ),
            max_ttl_seconds=int(
                os.getenv("BROKER_MAX_TTL_SECONDS", cls.max_ttl_seconds)
            ),
            refresh_skew_seconds=int(
                os.getenv("BROKER_REFRESH_SKEW_SECONDS", cls.refresh_skew_seconds)
            ),
            max_grant_ttl_seconds=int(
                os.getenv("BROKER_MAX_GRANT_TTL_SECONDS", cls.max_grant_ttl_seconds)
            ),
            default_grant_ttl_seconds=int(
                os.getenv(
                    "BROKER_DEFAULT_GRANT_TTL_SECONDS", cls.default_grant_ttl_seconds
                )
            ),
            request_timeout_seconds=float(
                os.getenv("BROKER_REQUEST_TIMEOUT_SECONDS", cls.request_timeout_seconds)
            ),
            public_url=os.getenv("BROKER_PUBLIC_URL", cls.public_url).rstrip("/"),
        )
