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
        litellm_keygen_key="keygen-key",
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


ADMIN = {"X-Admin-Token": ADMIN_TOKEN}


def _grant(admin, lease, service="excalidraw", **overrides):
    body = {"service": service, "ttl_seconds": 600, "values": {"TOKEN": "sekret-xyz"}}
    body.update(overrides)
    return admin.post(
        f"/v1/leases/{lease['lease_id']}/grants", json=body, headers=ADMIN
    )


def test_settings_read_secrets_from_files(tmp_path, monkeypatch):
    admin_file = tmp_path / "admin"
    admin_file.write_text("  admin-from-file \n")
    key_file = tmp_path / "key"
    key_file.write_text("sk-keygen\n")
    monkeypatch.setenv("BROKER_ADMIN_TOKEN_FILE", str(admin_file))
    monkeypatch.setenv("LITELLM_KEYGEN_KEY_FILE", str(key_file))
    loaded = Settings.from_env()
    assert loaded.admin_token == "admin-from-file"
    assert loaded.litellm_keygen_key == "sk-keygen"


def test_events_are_streamed_as_json(clients, monkeypatch, capsys):
    admin, agent, _ = clients
    lease = _create(admin)
    monkeypatch.setattr(
        github,
        "mint_installation_token",
        lambda **_: {
            "token": "ghs_stream_secret",
            "expires_at": iso(utcnow() + timedelta(hours=1)),
        },
    )
    agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    out = capsys.readouterr().out
    lines = [line for line in out.splitlines() if line.strip()]
    assert len(lines) >= 2
    keys = ["component", "detail", "event", "lease_id", "outcome", "repo", "ts"]
    records = [json.loads(line) for line in lines]
    for record in records:
        assert sorted(record) == keys
        assert record["outcome"] in {"ok", "deny", "error", "warn"}
    assert {r["event"] for r in records} >= {"lease.create", "github.mint"}
    assert records[0]["repo"] == "owner/repo"
    assert "ghs_stream_secret" not in out
    assert lease["lease_token"] not in out


def test_admin_token_mismatch_records_event(clients):
    admin, _, store = clients
    response = admin.get("/v1/leases", headers={"X-Admin-Token": "wrong"})
    assert response.status_code == 401
    events = [e for e in store.events() if e["action"] == "admin.auth"]
    assert events and events[0]["result"] == "deny"


def test_grant_adds_service_to_running_lease(clients):
    admin, agent, _ = clients
    lease = _create(admin)
    response = _grant(admin, lease)
    assert response.status_code == 200
    assert "values" not in response.json()
    assert "sekret-xyz" not in response.text
    fetched = agent.get("/v1/token/excalidraw", headers=_auth(lease["lease_token"]))
    assert fetched.status_code == 200
    assert fetched.json()["values"] == {"TOKEN": "sekret-xyz"}
    view = admin.get(f"/v1/leases/{lease['lease_id']}", headers=ADMIN).json()
    assert [g["service"] for g in view["grants"]] == ["excalidraw"]
    assert "sekret-xyz" not in json.dumps(view)


def test_grant_ttl_is_clamped_to_lease(clients):
    admin, _, _ = clients
    lease = _create(admin, ttl_seconds=600)
    grant = _grant(admin, lease, ttl_seconds=1800).json()
    remaining = (
        datetime.fromisoformat(grant["expires_at"].replace("Z", "+00:00"))
        - datetime.now(timezone.utc)
    ).total_seconds()
    assert 500 < remaining <= 600


def test_grant_ttl_is_clamped_to_max(clients):
    admin, _, _ = clients
    lease = _create(admin, ttl_seconds=86400)
    grant = _grant(admin, lease, ttl_seconds=86400).json()
    remaining = (
        datetime.fromisoformat(grant["expires_at"].replace("Z", "+00:00"))
        - datetime.now(timezone.utc)
    ).total_seconds()
    assert 3500 < remaining <= 3600


@pytest.mark.parametrize("name", ["github", "litellm", "all", "Bad", "x"])
def test_reserved_service_name_is_rejected(clients, name):
    admin, _, _ = clients
    lease = _create(admin)
    assert _grant(admin, lease, service=name).status_code == 422


def test_grant_on_revoked_lease_conflicts(clients):
    admin, _, store = clients
    lease = _create(admin)
    admin.post(f"/v1/leases/{lease['lease_id']}/revoke", headers=ADMIN)
    assert _grant(admin, lease).status_code == 409
    assert store.list_grants(lease["lease_id"]) == []


def test_expired_grant_is_denied_and_cleared(clients, settings):
    admin, agent, store = clients
    lease = _create(admin)
    store.grant(
        lease["lease_id"],
        "excalidraw",
        {"TOKEN": "old-secret"},
        utcnow() - timedelta(seconds=1),
    )
    response = agent.get("/v1/token/excalidraw", headers=_auth(lease["lease_token"]))
    assert response.status_code == 403
    import sqlite3

    conn = sqlite3.connect(settings.db_path)
    row = conn.execute("SELECT secret_json, status FROM grants").fetchone()
    assert row == (None, "expired")


def test_revoke_clears_grants(clients, settings):
    admin, agent, _ = clients
    lease = _create(admin)
    _grant(admin, lease)
    admin.post(f"/v1/leases/{lease['lease_id']}/revoke", headers=ADMIN)
    response = agent.get("/v1/token/excalidraw", headers=_auth(lease["lease_token"]))
    assert response.status_code == 403
    import sqlite3

    conn = sqlite3.connect(settings.db_path)
    assert conn.execute("SELECT secret_json FROM grants").fetchone() == (None,)


def test_ungrant_only_removes_one(clients):
    admin, agent, _ = clients
    lease = _create(admin)
    _grant(admin, lease, service="excalidraw")
    _grant(admin, lease, service="other-svc", values={"TOKEN": "two"})
    removed = admin.delete(
        f"/v1/leases/{lease['lease_id']}/grants/excalidraw", headers=ADMIN
    )
    assert removed.status_code == 200
    headers = _auth(lease["lease_token"])
    assert agent.get("/v1/token/excalidraw", headers=headers).status_code == 403
    assert agent.get("/v1/token/other-svc", headers=headers).status_code == 200


def test_generic_route_does_not_shadow_github(clients, monkeypatch):
    admin, agent, _ = clients
    lease = _create(admin)
    monkeypatch.setattr(
        github,
        "mint_installation_token",
        lambda **_: {
            "token": "ghs_literal",
            "expires_at": iso(utcnow() + timedelta(hours=1)),
        },
    )
    response = agent.get("/v1/token/github", headers=_auth(lease["lease_token"]))
    assert response.status_code == 200
    assert response.json()["token"] == "ghs_literal"


def test_grant_values_never_in_events(clients, capsys):
    admin, agent, store = clients
    lease = _create(admin)
    _grant(admin, lease)
    agent.get("/v1/token/excalidraw", headers=_auth(lease["lease_token"]))
    assert "sekret-xyz" not in json.dumps(store.events())
    assert "sekret-xyz" not in capsys.readouterr().out
    issued = [e for e in store.events() if e["action"] == "token.issue"]
    assert issued and json.loads(issued[0]["detail"]) == {"service": "excalidraw"}
