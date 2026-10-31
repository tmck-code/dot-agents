"""SQLite persistence for leases and issuance events.

The database never stores the lease token or a credential in plaintext in the
event log. The lease token is stored as a SHA-256 hash; a database leak cannot
be replayed as a lease.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS leases (
    lease_id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    session TEXT NOT NULL,
    service TEXT NOT NULL,
    resources TEXT NOT NULL,
    actions TEXT NOT NULL,
    models TEXT NOT NULL DEFAULT '[]',
    budget_usd REAL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    litellm_key TEXT,
    github_token TEXT,
    github_token_expires_at TEXT,
    last_used_at TEXT
);
CREATE INDEX IF NOT EXISTS leases_status_idx ON leases(status, expires_at);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lease_id TEXT,
    action TEXT NOT NULL,
    result TEXT NOT NULL,
    detail TEXT,
    created_at TEXT NOT NULL
);
"""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def lease_token(lease_id: str) -> str:
    return f"lst_{lease_id}.{secrets.token_urlsafe(32)}"


class Store:
    def __init__(self, path: str) -> None:
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self._session() as conn:
            conn.executescript(SCHEMA)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
        return conn

    @contextmanager
    def _session(self):
        conn = self._connect()
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def create(
        self,
        *,
        session: str,
        service: str,
        resources: list[str],
        actions: list[str],
        ttl_seconds: int,
        models: list[str] | None = None,
        budget_usd: float | None = None,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        now = now or utcnow()
        lease_id = f"lease_{secrets.token_hex(8)}"
        token = lease_token(lease_id)
        expires_at = now + timedelta(seconds=ttl_seconds)
        with self._session() as conn:
            conn.execute(
                """
                INSERT INTO leases (
                    lease_id, token_hash, session, service, resources, actions,
                    models, budget_usd, created_at, expires_at, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active')
                """,
                (
                    lease_id,
                    token_hash(token),
                    session,
                    service,
                    json.dumps(resources),
                    json.dumps(actions),
                    json.dumps(models or []),
                    budget_usd,
                    iso(now),
                    iso(expires_at),
                ),
            )
        self.event(lease_id, "lease.create", "ok", {"service": service})
        return {
            "lease_id": lease_id,
            "lease_token": token,
            "session": session,
            "service": service,
            "resources": resources,
            "actions": actions,
            "models": models or [],
            "budget_usd": budget_usd,
            "created_at": iso(now),
            "expires_at": iso(expires_at),
            "status": "active",
        }

    def find_by_token(self, token: str) -> dict[str, Any] | None:
        with self._session() as conn:
            row = conn.execute(
                "SELECT * FROM leases WHERE token_hash = ?", (token_hash(token),)
            ).fetchone()
        return _row(row) if row else None

    def get(self, lease_id: str) -> dict[str, Any] | None:
        with self._session() as conn:
            row = conn.execute(
                "SELECT * FROM leases WHERE lease_id = ?", (lease_id,)
            ).fetchone()
        return _row(row) if row else None

    def list_active(self) -> list[dict[str, Any]]:
        with self._session() as conn:
            rows = conn.execute(
                "SELECT * FROM leases WHERE status = 'active' ORDER BY expires_at"
            ).fetchall()
        return [_row(row) for row in rows]

    def revoke(self, lease_id: str) -> dict[str, Any] | None:
        with self._session() as conn:
            conn.execute(
                "UPDATE leases SET status = 'revoked' WHERE lease_id = ?", (lease_id,)
            )
        lease = self.get(lease_id)
        if lease:
            self.event(lease_id, "lease.revoke", "ok")
        return lease

    def touch(self, lease_id: str, now: datetime | None = None) -> None:
        with self._session() as conn:
            conn.execute(
                "UPDATE leases SET last_used_at = ? WHERE lease_id = ?",
                (iso(now or utcnow()), lease_id),
            )

    def set_github_token(
        self, lease_id: str, token: str, expires_at: str
    ) -> None:
        with self._session() as conn:
            conn.execute(
                "UPDATE leases SET github_token = ?, github_token_expires_at = ? "
                "WHERE lease_id = ?",
                (token, expires_at, lease_id),
            )

    def set_litellm_key(self, lease_id: str, key: str) -> None:
        with self._session() as conn:
            conn.execute(
                "UPDATE leases SET litellm_key = ? WHERE lease_id = ?",
                (key, lease_id),
            )

    def clear_credentials(self, lease_id: str) -> None:
        with self._session() as conn:
            conn.execute(
                "UPDATE leases SET github_token = NULL, "
                "github_token_expires_at = NULL, litellm_key = NULL "
                "WHERE lease_id = ?",
                (lease_id,),
            )

    def event(
        self,
        lease_id: str | None,
        action: str,
        result: str,
        detail: Any = None,
        now: datetime | None = None,
    ) -> None:
        """Record an issuance event without credential material."""
        if isinstance(detail, dict):
            detail = {
                key: value
                for key, value in detail.items()
                if key not in {"token", "lease_token", "litellm_key", "private_key"}
            }
        with self._session() as conn:
            conn.execute(
                "INSERT INTO events (lease_id, action, result, detail, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (
                    lease_id,
                    action,
                    result,
                    json.dumps(detail) if detail is not None else None,
                    iso(now or utcnow()),
                ),
            )

    def events(self, lease_id: str | None = None) -> list[dict[str, Any]]:
        query = "SELECT * FROM events"
        params: tuple[Any, ...] = ()
        if lease_id:
            query += " WHERE lease_id = ?"
            params = (lease_id,)
        query += " ORDER BY id"
        with self._session() as conn:
            rows = conn.execute(query, params).fetchall()
        return [dict(row) for row in rows]


def _row(row: sqlite3.Row) -> dict[str, Any]:
    record = dict(row)
    record["resources"] = json.loads(record["resources"])
    record["actions"] = json.loads(record["actions"])
    record["models"] = json.loads(record["models"])
    return record


def is_expired(lease: dict[str, Any], now: datetime | None = None) -> bool:
    return parse_iso(lease["expires_at"]) <= (now or utcnow())


def is_active(lease: dict[str, Any], now: datetime | None = None) -> bool:
    return lease.get("status") == "active" and not is_expired(lease, now)
