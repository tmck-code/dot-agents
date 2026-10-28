"""Broker behaviour: scope, expiry, revocation, refresh and log hygiene."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from broker import github, litellm
from broker.admin_app import create_app as create_admin_app
from broker.agent_app import create_app as create_agent_app
from broker.settings import Settings
from broker.store import Store, iso, utcnow

ADMIN_TOKEN = "test-admin-token"


@pytest.fixture()
def settings(tmp_path):
    pem = tmp_path / "app.pem"
    pem.write_text("-----BEGIN " + "PRIVATE KEY-----\nfake\n-----END " + "PRIVATE KEY-----\n")
    return Settings(
        db_path=str(tmp_path / "broker.db"),
        admin_token=ADMIN_TOKEN,
        github_app_id="1234",
        github_installation_id="99",
        github_private_key_file=str(pem),
        litellm_url="http://litellm.test:4000",
        litellm_master_key="master-key",
        litellm_models=("claude-sonnet",),
        refresh_skew_seconds=300,
    )


@pytest.fixture()
def clients(settings):
    admin = TestClient(create_admin_app(settings))
    agent = TestClient(create_agent_app(settings))
    return admin, agent, Store(settings.db_path)


def _create(admin: TestClient, **overrides):
    body = {
        "session": "ses_test",
        "service": "github",
        "resources": ["owner/repo"],
        "actions": ["contents:read"],
        "ttl_seconds": 3600,
        "models": [],
    }
    body.update(overrides)
    response = admin.post(
        "/v1/leases", json=body, headers={"X-Admin-Token": ADMIN_TOKEN}
    )
    assert response.status_code == 200, response.text
    return response.json()


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_lease_creation_records_scope(clients):
    admin, _, store = clients
    lease = _create(admin)
    assert lease["lease_id"].startswith("lease_")
    assert lease["lease_token"].startswith("lst_")
    stored = store.get(lease["lease_id"])
    assert stored["session"] == "ses_test"
    assert stored["resources"] == ["owner/repo"]
    assert stored["actions"] == ["contents:read"]
    assert stored["status"] == "active"
    listed = admin.get(
        "/v1/leases", headers={"X-Admin-Token": ADMIN_TOKEN}
    ).json()["leases"]
    assert [item["lease_id"] for item in listed] == [lease["lease_id"]]


def test_revocation_is_immediate(clients, monkeypatch):
    admin, agent, _ = clients
    lease = _create(admin)
    monkeypatch.setattr(
        github,
        "mint_installation_token",
        lambda **_: {"token": "ghs_one", "expires_at": iso(utcnow() + timedelta(hours=1))},
    )
    assert agent.get("/v1/token/github", headers=_auth(lease["lease_token"])).status_code == 200
    response = admin.post(
        f"/v1/leases/{lease['lease_id']}/revoke",
        headers={"X-Admin-Token": ADMIN_TOKEN},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "revoked"
    after = agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    assert after.status_code == 403
    assert "token" not in after.json()


def test_expiry_is_enforced(clients):
    admin, agent, store = clients
    lease = _create(admin)
    with store._session() as conn:
        conn.execute(
            "UPDATE leases SET expires_at = ? WHERE lease_id = ?",
            ("2000-01-01T00:00:00Z", lease["lease_id"]),
        )
    response = agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    assert response.status_code == 403
    assert "expired" in response.json()["detail"]


def test_missing_and_malformed_tokens_are_rejected(clients):
    _, agent, _ = clients
    assert agent.get("/v1/token/github").status_code == 401
    assert (
        agent.get("/v1/token/github", headers={"Authorization": "Bearer nope"}).status_code
        == 401
    )
    assert (
        agent.get(
            "/v1/token/github", headers={"Authorization": "Bearer lst_missing.abc"}
        ).status_code
        == 401
    )


def test_installation_token_refreshes_for_long_job(clients, monkeypatch):
    admin, agent, _ = clients
    lease = _create(admin)
    calls: list[int] = []

    def fake_mint(**_):
        calls.append(1)
        # Shorter than the refresh skew, so the second call must mint again.
        return {
            "token": f"ghs_{len(calls)}",
            "expires_at": iso(utcnow() + timedelta(seconds=60)),
        }

    monkeypatch.setattr(github, "mint_installation_token", fake_mint)
    first = agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    second = agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    assert first.json()["token"] == "ghs_1"
    assert second.json()["token"] == "ghs_2"
    assert len(calls) == 2


def test_github_scope_is_enforced(clients):
    admin, agent, _ = clients
    lease = _create(admin, service="github", resources=["owner/repo"])
    response = agent.get("/v1/token/litellm", headers=_auth(lease["lease_token"]))
    assert response.status_code == 403


def test_litellm_key_is_issued_and_revoked(clients, monkeypatch):
    admin, agent, _ = clients
    monkeypatch.setattr(
        litellm, "create_virtual_key", lambda **_: "sk-lease-virtual-key"
    )
    deleted: list[str] = []
    monkeypatch.setattr(
        litellm,
        "delete_virtual_key",
        lambda **kwargs: deleted.append(kwargs["key"]) is None,
    )
    lease = _create(
        admin,
        service="all",
        resources=["owner/repo"],
        models=["claude-sonnet"],
        budget_usd=2.5,
    )
    response = agent.get("/v1/token/litellm", headers=_auth(lease["lease_token"]))
    assert response.status_code == 200
    assert response.json()["key"] == "sk-lease-virtual-key"
    admin.post(
        f"/v1/leases/{lease['lease_id']}/revoke",
        headers={"X-Admin-Token": ADMIN_TOKEN},
    )
    assert deleted == ["sk-lease-virtual-key"]
    after = agent.get("/v1/token/litellm", headers=_auth(lease["lease_token"]))
    assert after.status_code == 403


def test_events_never_contain_token_values(clients, monkeypatch):
    admin, agent, store = clients
    lease = _create(admin)
    monkeypatch.setattr(
        github,
        "mint_installation_token",
        lambda **_: {
            "token": "ghs_super_secret_value",
            "expires_at": iso(utcnow() + timedelta(hours=1)),
        },
    )
    agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    serialised = json.dumps(store.events())
    assert "ghs_super_secret_value" not in serialised
    assert lease["lease_token"] not in serialised
    assert lease["lease_id"] in serialised


def test_invalid_admin_token_is_rejected(clients):
    admin, _, _ = clients
    response = admin.get("/v1/leases", headers={"X-Admin-Token": "wrong"})
    assert response.status_code == 401
    assert admin.get("/v1/leases").status_code == 401


def test_ttl_is_clamped(settings):
    admin = TestClient(create_admin_app(settings))
    body = {
        "session": "ses_test",
        "service": "github",
        "resources": ["owner/repo"],
        "ttl_seconds": 10**9,
    }
    response = admin.post(
        "/v1/leases", json=body, headers={"X-Admin-Token": ADMIN_TOKEN}
    )
    assert response.status_code == 422


def test_scope_metadata_reflects_expiry(clients):
    admin, agent, store = clients
    lease = _create(admin)
    now = datetime.now(timezone.utc)
    assert datetime.fromisoformat(
        store.get(lease["lease_id"])["expires_at"].replace("Z", "+00:00")
    ) > now
    self_view = agent.get("/v1/leases/self", headers=_auth(lease["lease_token"]))
    assert self_view.status_code == 200
    assert self_view.json()["service"] == "github"


def test_qwen_local_lease_passes_model_allowlist(clients, monkeypatch):
    admin, _, _ = clients
    calls: list[dict] = []

    def fake_create(**kwargs):
        calls.append(kwargs)
        return "sk-qwen-local"

    monkeypatch.setattr(litellm, "create_virtual_key", fake_create)
    lease = _create(
        admin,
        service="litellm",
        resources=[],
        models=["qwen-local"],
    )
    assert lease["models"] == ["qwen-local"]
    assert calls and calls[0]["models"] == ["qwen-local"]
    assert calls[0]["lease_id"] == lease["lease_id"]
