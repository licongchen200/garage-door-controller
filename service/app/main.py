"""FastAPI application for the internet-facing garage door API."""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from .auth import AppleTokenError, AppleTokenVerifier, AppJWT
from .config import Settings
from .mqtt_bridge import MqttBridge
from .rate_limit import RateLimiter


class AppleAuthRequest(BaseModel):
    identity_token: str = Field(min_length=1)
    # The app's credential.user is retained by iOS. It is optional here because the
    # signed token subject is authoritative; if present, it must match that subject.
    user_id: str | None = None
    apple_user_id: str | None = None


class AppAuthResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    apple_user_id: str


def create_app(
    settings: Settings | None = None,
    bridge: MqttBridge | None = None,
    apple_verifier: AppleTokenVerifier | Any | None = None,
) -> FastAPI:
    config = settings or Settings.from_env()
    mqtt_bridge = bridge or MqttBridge(config)
    # Keep module import safe for tooling; lifespan validation prevents serving without this.
    verifier = (
        apple_verifier
        if apple_verifier is not None
        else (AppleTokenVerifier(config) if config.apple_bundle_id else None)
    )
    app_jwt = AppJWT(config.jwt_secret, config.jwt_ttl_days)
    limiter = RateLimiter(config.rate_limit_max_calls, config.rate_limit_window_seconds)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        config.validate()
        mqtt_bridge.start()
        try:
            yield
        finally:
            mqtt_bridge.stop()

    app = FastAPI(title="Garage Door API", version="1.0.0", lifespan=lifespan)
    app.state.bridge = mqtt_bridge
    app.state.app_jwt = app_jwt
    app.state.apple_verifier = verifier
    app.state.rate_limiter = limiter

    async def current_user(
        authorization: str | None = Header(default=None),
    ) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Bearer token required",
                headers={"WWW-Authenticate": "Bearer"},
            )
        token = authorization[7:].strip()
        if not token:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Bearer token required",
                headers={"WWW-Authenticate": "Bearer"},
            )
        try:
            return app_jwt.verify(token)
        except (ValueError, RuntimeError) as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid or expired token",
                headers={"WWW-Authenticate": "Bearer"},
            ) from exc

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/auth/apple", response_model=AppAuthResponse)
    async def sign_in_with_apple(body: AppleAuthRequest) -> AppAuthResponse:
        if verifier is None:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Authentication is not configured",
            )
        try:
            claims = verifier.verify(body.identity_token)
        except (AppleTokenError, ValueError) as exc:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid Apple identity token") from exc
        apple_user_id = claims["sub"]
        supplied_id = body.apple_user_id or body.user_id
        if supplied_id is not None and supplied_id != apple_user_id:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Apple user identifier mismatch")
        try:
            access_token, expires_in = app_jwt.issue(apple_user_id)
        except RuntimeError as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Authentication is not configured") from exc
        return AppAuthResponse(
            access_token=access_token,
            expires_in=expires_in,
            apple_user_id=apple_user_id,
        )

    @app.get("/door/state")
    async def door_state(user_id: str = Depends(current_user)) -> dict[str, Any]:
        snapshot = mqtt_bridge.snapshot()
        return {"state": snapshot.state, "online": snapshot.online, "ts": snapshot.ts}

    async def command(command: str, user_id: str) -> dict[str, str]:
        if not limiter.allow(user_id):
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Too many door commands; try again later",
                headers={"Retry-After": str(int(config.rate_limit_window_seconds))},
            )
        result, command_id = await run_in_threadpool(mqtt_bridge.trigger, command)
        return {"result": result, "id": command_id}

    @app.post("/door/open")
    async def open_door(user_id: str = Depends(current_user)) -> dict[str, str]:
        return await command("open", user_id)

    @app.post("/door/close")
    async def close_door(user_id: str = Depends(current_user)) -> dict[str, str]:
        return await command("close", user_id)

    return app


# Importing this module is safe without secrets; startup validation prevents an
# accidentally insecure process from serving requests.
app = create_app()
