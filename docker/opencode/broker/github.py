"""GitHub App authentication and installation-token minting.

The App private key stays on the host-side broker. The agent only ever sees the
short-lived installation token returned from an agent-facing endpoint.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import jwt


class GitHubError(RuntimeError):
    def __init__(self, message: str, status: int = 502) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class GitHubApp:
    app_id: str
    private_key_pem: str

    @classmethod
    def from_file(cls, app_id: str, path: str) -> "GitHubApp":
        try:
            pem = Path(path).read_text(encoding="utf-8")
        except OSError as exc:
            raise GitHubError(f"cannot read GitHub App private key: {exc}", 503) from exc
        if "PRIVATE KEY" not in pem:
            raise GitHubError("GitHub App private key file is not a PEM key", 503)
        return cls(app_id=app_id, private_key_pem=pem)

    def sign(self, now: int | None = None) -> str:
        now = now or int(time.time())
        payload = {"iat": now - 60, "exp": now + 540, "iss": self.app_id}
        return jwt.encode(payload, self.private_key_pem, algorithm="RS256")


def repo_permissions(actions: list[str]) -> dict[str, str]:
    """Map lease actions such as ``contents:read`` to GitHub permissions."""
    permissions: dict[str, str] = {}
    for action in actions:
        if ":" not in action:
            continue
        name, level = action.split(":", 1)
        if level not in {"read", "write", "admin"}:
            continue
        permissions[name] = level
    return permissions or {"contents": "read"}


def find_installation(
    app: GitHubApp,
    owner: str,
    repo: str,
    *,
    api_url: str,
    timeout: float,
) -> str:
    token = app.sign()
    url = f"{api_url.rstrip('/')}/repos/{owner}/{repo}/installation"
    try:
        response = httpx.get(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            timeout=timeout,
        )
    except httpx.HTTPError as exc:
        raise GitHubError(f"GitHub installation lookup failed: {exc}") from exc
    if response.status_code != 200:
        raise GitHubError(
            f"GitHub installation lookup returned {response.status_code}", 502
        )
    return str(response.json()["id"])


def mint_installation_token(
    *,
    app_id: str,
    private_key_pem: str,
    installation_id: str,
    repositories: list[str],
    permissions: dict[str, str],
    api_url: str = "https://api.github.com",
    timeout: float = 15.0,
) -> dict[str, Any]:
    """Mint a token scoped to the listed repositories and permissions."""
    app = GitHubApp(app_id=app_id, private_key_pem=private_key_pem)
    token = app.sign()
    body: dict[str, Any] = {"permissions": permissions}
    names = [item.split("/", 1)[1] for item in repositories if "/" in item]
    if names:
        body["repositories"] = names
    url = f"{api_url.rstrip('/')}/app/installations/{installation_id}/access_tokens"
    try:
        response = httpx.post(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            json=body,
            timeout=timeout,
        )
    except httpx.HTTPError as exc:
        raise GitHubError(f"GitHub token request failed: {exc}") from exc
    if response.status_code not in {200, 201}:
        raise GitHubError(
            f"GitHub token request returned {response.status_code}", 502
        )
    payload = response.json()
    if "token" not in payload or "expires_at" not in payload:
        raise GitHubError("GitHub token response was missing token or expiry", 502)
    return payload
