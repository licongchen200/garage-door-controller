"""PostgreSQL persistence for users, devices, and door operation history."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol

import psycopg


MAC_RE = re.compile(r"^[0-9a-f]{12}$")


def normalize_mac_address(value: str) -> str:
    """Return the canonical lower-case, separator-free MAC representation."""
    normalized = value.replace(":", "").replace("-", "").lower()
    if not MAC_RE.fullmatch(normalized):
        raise ValueError("MAC address must contain exactly 12 hexadecimal characters")
    return normalized


@dataclass(frozen=True)
class DeviceRecord:
    mac_address: str
    owner_apple_user_id: str
    display_name: str | None
    registered_at: datetime


@dataclass(frozen=True)
class EventRecord:
    id: int
    mac_address: str
    kind: str
    actor_apple_user_id: str | None
    command: str | None
    outcome: str | None
    state: str | None
    occurred_at: datetime


class DeviceAlreadyOwnedError(ValueError):
    """The device is registered to a different Apple user."""


class Database(Protocol):
    def ensure_schema(self) -> None: ...

    def record_user_once(self, apple_user_id: str, email: str | None, full_name: str | None) -> None: ...

    def register_device(self, user_id: str, mac_address: str, display_name: str | None) -> DeviceRecord: ...

    def first_owned_device(self, user_id: str) -> DeviceRecord | None: ...

    def owned_device(self, user_id: str, mac_address: str) -> DeviceRecord | None: ...

    def record_command(self, user_id: str, mac_address: str, command: str, outcome: str) -> None: ...

    def record_state_change(self, mac_address: str, state: str, occurred_at: Any = None) -> None: ...

    def list_events(self, user_id: str, mac_address: str, limit: int, offset: int) -> list[EventRecord]: ...


class PostgresDatabase:
    def __init__(self, database_url: str):
        self.database_url = database_url

    def _connect(self) -> psycopg.Connection[Any]:
        return psycopg.connect(self.database_url)

    def ensure_schema(self) -> None:
        schema = Path(__file__).with_name("schema.sql").read_text(encoding="utf-8")
        with self._connect() as connection:
            connection.execute(schema)

    def record_user_once(self, apple_user_id: str, email: str | None, full_name: str | None) -> None:
        # Apple only provides these fields to the app on the first authorization. Do
        # not update an existing row: an older account cannot be backfilled later.
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO users (apple_user_id, email, full_name)
                VALUES (%s, %s, %s)
                ON CONFLICT (apple_user_id) DO NOTHING
                """,
                (apple_user_id, email, full_name),
            )

    def register_device(self, user_id: str, mac_address: str, display_name: str | None) -> DeviceRecord:
        mac_address = normalize_mac_address(mac_address)
        with self._connect() as connection:
            row = connection.execute(
                "SELECT owner_apple_user_id FROM devices WHERE mac_address = %s",
                (mac_address,),
            ).fetchone()
            if row is not None and row[0] != user_id:
                raise DeviceAlreadyOwnedError("device is already registered to another user")

            if row is None:
                row = connection.execute(
                    """
                    INSERT INTO devices (mac_address, owner_apple_user_id, display_name)
                    VALUES (%s, %s, %s)
                    RETURNING mac_address, owner_apple_user_id, display_name, registered_at
                    """,
                    (mac_address, user_id, display_name),
                ).fetchone()
            else:
                row = connection.execute(
                    """
                    UPDATE devices
                    SET display_name = COALESCE(%s, display_name)
                    WHERE mac_address = %s
                    RETURNING mac_address, owner_apple_user_id, display_name, registered_at
                    """,
                    (display_name, mac_address),
                ).fetchone()
            assert row is not None
            return DeviceRecord(*row)

    def first_owned_device(self, user_id: str) -> DeviceRecord | None:
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT mac_address, owner_apple_user_id, display_name, registered_at
                FROM devices
                WHERE owner_apple_user_id = %s
                ORDER BY registered_at ASC, mac_address ASC
                LIMIT 1
                """,
                (user_id,),
            ).fetchone()
        return DeviceRecord(*row) if row is not None else None

    def owned_device(self, user_id: str, mac_address: str) -> DeviceRecord | None:
        mac_address = normalize_mac_address(mac_address)
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT mac_address, owner_apple_user_id, display_name, registered_at
                FROM devices
                WHERE mac_address = %s AND owner_apple_user_id = %s
                """,
                (mac_address, user_id),
            ).fetchone()
        return DeviceRecord(*row) if row is not None else None

    def record_command(self, user_id: str, mac_address: str, command: str, outcome: str) -> None:
        mac_address = normalize_mac_address(mac_address)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO events (mac_address, kind, actor_apple_user_id, command, outcome)
                VALUES (%s, 'command', %s, %s, %s)
                """,
                (mac_address, user_id, command, outcome),
            )

    def record_state_change(self, mac_address: str, state: str, occurred_at: Any = None) -> None:
        mac_address = normalize_mac_address(mac_address)
        if occurred_at is None:
            occurred_at = datetime.now(timezone.utc)
        elif isinstance(occurred_at, (int, float)):
            occurred_at = datetime.fromtimestamp(occurred_at, timezone.utc)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO events (mac_address, kind, state, occurred_at)
                SELECT mac_address, 'state_change', %s, %s
                FROM devices
                WHERE mac_address = %s
                """,
                (state, occurred_at, mac_address),
            )

    def list_events(self, user_id: str, mac_address: str, limit: int, offset: int) -> list[EventRecord]:
        mac_address = normalize_mac_address(mac_address)
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT e.id, e.mac_address, e.kind, e.actor_apple_user_id,
                       e.command, e.outcome, e.state, e.occurred_at
                FROM events e
                JOIN devices d ON d.mac_address = e.mac_address
                WHERE e.mac_address = %s AND d.owner_apple_user_id = %s
                ORDER BY e.occurred_at DESC, e.id DESC
                LIMIT %s OFFSET %s
                """,
                (mac_address, user_id, limit, offset),
            ).fetchall()
        return [EventRecord(*row) for row in rows]
