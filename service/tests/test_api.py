import time

import jwt
from fastapi.testclient import TestClient

from app.auth import AppJWT
from app.config import Settings
from app.main import create_app
from fakes import FakeDatabase


class FakeVerifier:
    def verify(self, token):
        if token != "apple-token":
            raise ValueError("bad token")
        return {"sub": "apple-user-1"}


class FakeBridge:
    def __init__(self):
        self.started = False
        self.commands = []

    def start(self):
        self.started = True

    def stop(self):
        self.started = False

    def snapshot(self, _mac_address=None):
        from app.mqtt_bridge import DoorSnapshot

        return DoorSnapshot("closed", True, "2025-01-01T00:00:00Z")

    def trigger(self, command, _mac_address=None):
        self.commands.append(command)
        return "triggered", "command-id"


def make_client(seed_device=True):
    settings = Settings(jwt_secret="s" * 32, apple_bundle_id="com.example.garagedoor")
    bridge = FakeBridge()
    database = FakeDatabase()
    if seed_device:
        database.record_user_once("apple-user-1", None, None)
        database.register_device("apple-user-1", "aabbccddeeff", None)
    client = TestClient(create_app(settings, bridge, FakeVerifier(), database))
    return client, bridge, settings, database


def test_apple_exchange_issues_application_jwt_and_door_requires_it():
    with make_client()[0] as client:
        response = client.post(
            "/auth/apple",
            json={
                "identity_token": "apple-token",
                "user_id": "apple-user-1",
                "email": "captain@example.com",
                "full_name": "Captain Garage",
            },
        )
        assert response.status_code == 200
        body = response.json()
        claims = jwt.decode(body["access_token"], "s" * 32, algorithms=["HS256"])
        assert claims["sub"] == "apple-user-1"
        assert body["expires_in"] == 30 * 24 * 60 * 60

        assert client.get("/door/state").status_code == 401
        state = client.get("/door/state", headers={"Authorization": f"Bearer {body['access_token']}"})
        assert state.json() == {"state": "closed", "online": True, "ts": "2025-01-01T00:00:00Z"}


def test_apple_identifier_mismatch_is_rejected():
    with make_client()[0] as client:
        response = client.post(
            "/auth/apple",
            json={"identity_token": "apple-token", "apple_user_id": "another-user"},
        )
        assert response.status_code == 401


def test_apple_metadata_is_captured_only_on_first_authorization():
    client, _, _, database = make_client(seed_device=False)
    with client:
        request = {
            "identity_token": "apple-token",
            "email": "first@example.com",
            "full_name": "First Name",
        }
        assert client.post("/auth/apple", json=request).status_code == 200
        assert database.users["apple-user-1"] == {
            "email": "first@example.com",
            "full_name": "First Name",
        }

        request.update(email="later@example.com", full_name="Later Name")
        assert client.post("/auth/apple", json=request).status_code == 200
        assert database.users["apple-user-1"] == {
            "email": "first@example.com",
            "full_name": "First Name",
        }


def test_expired_application_token_is_rejected():
    with make_client()[0] as client:
        token = jwt.encode(
            {"sub": "user", "iat": int(time.time()) - 100, "exp": int(time.time()) - 1},
            "s" * 32,
            algorithm="HS256",
        )
        response = client.get("/door/state", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 401


def test_commands_are_rate_limited_per_authenticated_user():
    client, bridge, settings, database = make_client(seed_device=False)
    settings = Settings(
        jwt_secret="s" * 32,
        apple_bundle_id="com.example.garagedoor",
        rate_limit_max_calls=2,
        rate_limit_window_seconds=60,
    )
    client = TestClient(create_app(settings, bridge, FakeVerifier(), database))
    with client:
        token = AppJWT("s" * 32).issue("user")[0]
        headers = {"Authorization": f"Bearer {token}"}
        database.record_user_once("user", None, None)
        database.register_device("user", "aabbccddeeff", None)
        assert client.post("/door/open", headers=headers).status_code == 200
        assert client.post("/door/close", headers=headers).status_code == 200
        limited = client.post("/door/open", headers=headers)
        assert limited.status_code == 429
        assert bridge.commands == ["open", "close"]


def test_device_registration_authorizes_commands_and_paginated_history():
    client, bridge, settings, database = make_client(seed_device=False)
    with client:
        owner = AppJWT("s" * 32).issue("owner")[0]
        other = AppJWT("s" * 32).issue("other")[0]
        owner_headers = {"Authorization": f"Bearer {owner}"}
        other_headers = {"Authorization": f"Bearer {other}"}

        registered = client.post(
            "/devices/register",
            headers=owner_headers,
            json={"mac_address": "AA:BB:CC:DD:EE:FF", "display_name": "Front garage"},
        )
        assert registered.status_code == 200
        assert registered.json()["mac_address"] == "aabbccddeeff"

        assert client.post("/door/open", headers=other_headers).status_code == 404
        assert client.get("/devices/aabbccddeeff/events", headers=other_headers).status_code == 404
        assert client.post("/door/open", headers=owner_headers).json()["result"] == "triggered"
        history = client.get("/devices/aabbccddeeff/events?limit=1", headers=owner_headers)
        assert history.status_code == 200
        assert history.json()["items"][0]["kind"] == "command"
        assert history.json()["items"][0]["command"] == "open"

        conflict = client.post(
            "/devices/register",
            headers=other_headers,
            json={"mac_address": "aabbccddeeff"},
        )
        assert conflict.status_code == 409
