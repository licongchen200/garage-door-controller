"""Environment-backed configuration for the garage API."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Runtime settings. Secrets are intentionally never given code defaults."""

    jwt_secret: str | None = None
    apple_bundle_id: str | None = None
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    jwt_ttl_days: int = 30
    mqtt_host: str = "mosquitto"
    mqtt_port: int = 8883
    mqtt_ca_file: str = "/run/mqtt-certs/ca.crt"
    mqtt_cert_file: str = "/run/mqtt-certs/client.crt"
    mqtt_key_file: str = "/run/mqtt-certs/client.key"
    mqtt_ack_timeout_seconds: float = 3.0
    database_url: str = "postgresql://garage:garage@postgres:5432/garage"
    rate_limit_max_calls: int = 5
    rate_limit_window_seconds: float = 60.0

    @classmethod
    def from_env(cls) -> "Settings":
        def optional(name: str) -> str | None:
            value = os.getenv(name)
            return value if value else None

        return cls(
            jwt_secret=optional("JWT_SECRET"),
            apple_bundle_id=optional("APPLE_BUNDLE_ID"),
            apple_jwks_url=os.getenv("APPLE_JWKS_URL", cls.apple_jwks_url),
            jwt_ttl_days=int(os.getenv("JWT_TTL_DAYS", "30")),
            mqtt_host=os.getenv("MQTT_HOST", "mosquitto"),
            mqtt_port=int(os.getenv("MQTT_PORT", "8883")),
            mqtt_ca_file=os.getenv("MQTT_CA_FILE", cls.mqtt_ca_file),
            mqtt_cert_file=os.getenv("MQTT_CERT_FILE", cls.mqtt_cert_file),
            mqtt_key_file=os.getenv("MQTT_KEY_FILE", cls.mqtt_key_file),
            mqtt_ack_timeout_seconds=float(os.getenv("MQTT_ACK_TIMEOUT_SECONDS", "3")),
            database_url=os.getenv("DATABASE_URL", cls.database_url),
            rate_limit_max_calls=int(os.getenv("RATE_LIMIT_MAX_CALLS", "5")),
            rate_limit_window_seconds=float(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60")),
        )

    def validate(self) -> None:
        """Fail startup instead of running with an accidentally insecure config."""
        if not self.jwt_secret or len(self.jwt_secret) < 32:
            raise RuntimeError("JWT_SECRET must be set to at least 32 characters")
        if not self.apple_bundle_id:
            raise RuntimeError("APPLE_BUNDLE_ID must be set")
        if self.jwt_ttl_days <= 0:
            raise RuntimeError("JWT_TTL_DAYS must be positive")
        if self.rate_limit_max_calls <= 0 or self.rate_limit_window_seconds <= 0:
            raise RuntimeError("rate limit settings must be positive")
