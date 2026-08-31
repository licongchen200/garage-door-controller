import time

import jwt
from fastapi.testclient import TestClient

from app.auth import AppJWT
from app.config import Settings
from app.main import create_app


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

    def snapshot(self):
        from app.mqtt_bridge import DoorSnapshot

        return DoorSnapshot("closed", True, "2025-01-01T00:00:00Z")

    def trigger(self, command):
        self.commands.append(command)
        return "triggered", "command-id"


def make_client():
    settings = Settings(jwt_secret="s" * 32, apple_bundle_id="com.example.garagedoor")
    bridge = FakeBridge()
    client = TestClient(create_app(settings, bridge, FakeVerifier()))
    return client, bridge, settings


def test_apple_exchange_issues_application_jwt_and_door_requires_it():
    with make_client()[0] as client:
        response = client.post("/auth/apple", json={"identity_token": "apple-token", "user_id": "apple-user-1"})
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
    client, bridge, settings = make_client()
    settings = Settings(
        jwt_secret="s" * 32,
        apple_bundle_id="com.example.garagedoor",
        rate_limit_max_calls=2,
        rate_limit_window_seconds=60,
    )
    client = TestClient(create_app(settings, bridge, FakeVerifier()))
    with client:
        token = AppJWT("s" * 32).issue("user")[0]
        headers = {"Authorization": f"Bearer {token}"}
        assert client.post("/door/open", headers=headers).status_code == 200
        assert client.post("/door/close", headers=headers).status_code == 200
        limited = client.post("/door/open", headers=headers)
        assert limited.status_code == 429
        assert bridge.commands == ["open", "close"]
