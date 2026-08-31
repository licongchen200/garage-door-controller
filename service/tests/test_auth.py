from datetime import datetime, timedelta, timezone

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

from app.auth import AppleTokenError, AppleTokenVerifier, AppJWT
from app.config import Settings


def test_app_jwt_round_trip_and_expiry():
    token, expires_in = AppJWT("x" * 32).issue("apple-user")
    assert expires_in == 30 * 24 * 60 * 60
    assert AppJWT("x" * 32).verify(token) == "apple-user"

    expired = jwt.encode(
        {"sub": "apple-user", "iat": 1, "exp": 1}, "x" * 32, algorithm="HS256"
    )
    with pytest.raises(ValueError):
        AppJWT("x" * 32).verify(expired)


def test_apple_verifier_checks_issuer_audience_and_expiry(monkeypatch):
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key = private_key.public_key()
    token = jwt.encode(
        {
            "iss": "https://appleid.apple.com",
            "aud": "com.example.garagedoor",
            "sub": "apple-user",
            "exp": datetime.now(timezone.utc) + timedelta(minutes=5),
        },
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )

    class FakeKey:
        key = public_key

    class FakeJWKClient:
        def __init__(self, url):
            assert url == "https://mocked.example/keys"

        def get_signing_key_from_jwt(self, supplied):
            return FakeKey()

    monkeypatch.setattr("app.auth.PyJWKClient", FakeJWKClient)
    verifier = AppleTokenVerifier(
        Settings(apple_bundle_id="com.example.garagedoor", apple_jwks_url="https://mocked.example/keys")
    )
    assert verifier.verify(token)["sub"] == "apple-user"

    bad_audience = jwt.encode(
        {
            "iss": "https://appleid.apple.com",
            "aud": "wrong.bundle.id",
            "sub": "apple-user",
            "exp": datetime.now(timezone.utc) + timedelta(minutes=5),
        },
        private_key,
        algorithm="RS256",
        headers={"kid": "test-key"},
    )
    with pytest.raises(AppleTokenError):
        verifier.verify(bad_audience)
