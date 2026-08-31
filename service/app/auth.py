"""Apple identity-token verification and application JWTs."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
from jwt import PyJWKClient

from .config import Settings

APPLE_ISSUER = "https://appleid.apple.com"


class AppleTokenError(ValueError):
    """The supplied token is not a valid Sign in with Apple token."""


class AppleTokenVerifier:
    def __init__(self, settings: Settings):
        if not settings.apple_bundle_id:
            raise ValueError("APPLE_BUNDLE_ID is required")
        self.bundle_id = settings.apple_bundle_id
        self.jwks_client = PyJWKClient(settings.apple_jwks_url)

    def verify(self, identity_token: str) -> dict[str, Any]:
        try:
            signing_key = self.jwks_client.get_signing_key_from_jwt(identity_token)
            claims = jwt.decode(
                identity_token,
                signing_key.key,
                algorithms=["RS256"],
                audience=self.bundle_id,
                issuer=APPLE_ISSUER,
                options={"require": ["iss", "aud", "exp", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise AppleTokenError("invalid Apple identity token") from exc
        if not claims.get("sub"):
            raise AppleTokenError("Apple identity token has no subject")
        return claims


class AppJWT:
    """The API's own bearer token, signed with a server-only HS256 secret."""

    algorithm = "HS256"

    def __init__(self, secret: str | None, ttl_days: int = 30):
        self.secret = secret
        self.ttl_days = ttl_days

    def _require_secret(self) -> str:
        if not self.secret:
            raise RuntimeError("JWT_SECRET is not configured")
        return self.secret

    def issue(self, apple_user_id: str) -> tuple[str, int]:
        now = datetime.now(timezone.utc)
        expires_at = now + timedelta(days=self.ttl_days)
        payload = {
            "sub": apple_user_id,
            "iat": int(now.timestamp()),
            "exp": int(expires_at.timestamp()),
        }
        return jwt.encode(payload, self._require_secret(), algorithm=self.algorithm), int(
            expires_at.timestamp() - now.timestamp()
        )

    def verify(self, token: str) -> str:
        try:
            claims = jwt.decode(
                token,
                self._require_secret(),
                algorithms=[self.algorithm],
                options={"require": ["sub", "iat", "exp"]},
            )
        except jwt.PyJWTError as exc:
            raise ValueError("invalid application token") from exc
        subject = claims.get("sub")
        if not isinstance(subject, str) or not subject:
            raise ValueError("invalid application token subject")
        return subject
