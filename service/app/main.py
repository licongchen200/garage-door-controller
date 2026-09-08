"""FastAPI application for the internet-facing garage door API."""

from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Literal

from fastapi import Depends, FastAPI, Header, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from .auth import AppleTokenError, AppleTokenVerifier, AppJWT
from .config import Settings
from .database import Database, DeviceAlreadyOwnedError, DeviceRecord, PostgresDatabase, normalize_mac_address
from .mqtt_bridge import MqttBridge
from .rate_limit import RateLimiter


class AppleAuthRequest(BaseModel):
    identity_token: str = Field(min_length=1)
    # The app's credential.user is retained by iOS. It is optional here because the
    # signed token subject is authoritative; if present, it must match that subject.
    user_id: str | None = None
    apple_user_id: str | None = None
    email: str | None = None
    full_name: str | None = None


class AppAuthResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    apple_user_id: str


class DeviceRegistrationRequest(BaseModel):
    mac_address: str = Field(min_length=12, max_length=17)
    display_name: str | None = Field(default=None, max_length=80)


class DeviceResponse(BaseModel):
    mac_address: str
    display_name: str | None
    registered_at: datetime


class DeviceEventResponse(BaseModel):
    id: int
    mac_address: str
    kind: Literal["command", "state_change"]
    actor_apple_user_id: str | None
    command: Literal["open", "close"] | None
    outcome: Literal["triggered", "error"] | None
    state: Literal["open", "closed", "unknown"] | None
    occurred_at: datetime


class DeviceEventsResponse(BaseModel):
    items: list[DeviceEventResponse]
    limit: int
    offset: int


def create_app(
    settings: Settings | None = None,
    bridge: MqttBridge | None = None,
    apple_verifier: AppleTokenVerifier | Any | None = None,
    database: Database | None = None,
) -> FastAPI:
    config = settings or Settings.from_env()
    device_database = database or PostgresDatabase(config.database_url)
    mqtt_bridge = bridge or MqttBridge(config, event_store=device_database)
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
        device_database.ensure_schema()
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
    app.state.database = device_database

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
        try:
            # Apple supplies email/name to the app only on first authorization. The
            # database intentionally ignores later attempts for an existing user.
            device_database.record_user_once(apple_user_id, body.email, body.full_name)
        except Exception as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="User storage is unavailable") from exc
        return AppAuthResponse(
            access_token=access_token,
            expires_in=expires_in,
            apple_user_id=apple_user_id,
        )

    async def owned_device_or_404(user_id: str) -> DeviceRecord:
        device = await run_in_threadpool(device_database.first_owned_device, user_id)
        if device is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No registered device")
        return device

    @app.post("/devices/register", response_model=DeviceResponse)
    async def register_device(
        body: DeviceRegistrationRequest,
        user_id: str = Depends(current_user),
    ) -> DeviceResponse:
        try:
            mac_address = normalize_mac_address(body.mac_address)
            device = await run_in_threadpool(
                device_database.register_device, user_id, mac_address, body.display_name
            )
        except ValueError as exc:
            if isinstance(exc, DeviceAlreadyOwnedError):
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)) from exc
        return DeviceResponse(
            mac_address=device.mac_address,
            display_name=device.display_name,
            registered_at=device.registered_at,
        )

    @app.get("/door/state")
    async def door_state(user_id: str = Depends(current_user)) -> dict[str, Any]:
        device = await owned_device_or_404(user_id)
        snapshot = mqtt_bridge.snapshot(device.mac_address)
        return {"state": snapshot.state, "online": snapshot.online, "ts": snapshot.ts}

    async def command(command: str, user_id: str) -> dict[str, str]:
        device = await owned_device_or_404(user_id)
        if not limiter.allow(user_id):
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Too many door commands; try again later",
                headers={"Retry-After": str(int(config.rate_limit_window_seconds))},
            )
        result, command_id = await run_in_threadpool(mqtt_bridge.trigger, command, device.mac_address)
        try:
            await run_in_threadpool(device_database.record_command, user_id, device.mac_address, command, result)
        except Exception:
            # The operation still happened (or returned an MQTT error), so do not
            # turn a successful command response into a misleading server error.
            # Deployment logs retain the persistence failure for operator action.
            import logging

            logging.getLogger(__name__).exception("unable to record door command event")
        return {"result": result, "id": command_id}

    @app.post("/door/open")
    async def open_door(user_id: str = Depends(current_user)) -> dict[str, str]:
        return await command("open", user_id)

    @app.post("/door/close")
    async def close_door(user_id: str = Depends(current_user)) -> dict[str, str]:
        return await command("close", user_id)

    @app.get("/devices/{mac_address}/events", response_model=DeviceEventsResponse)
    async def device_events(
        mac_address: str,
        limit: int = 50,
        offset: int = 0,
        user_id: str = Depends(current_user),
    ) -> DeviceEventsResponse:
        if not 1 <= limit <= 100 or offset < 0:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="limit must be 1..100 and offset must be non-negative")
        try:
            normalized_mac = normalize_mac_address(mac_address)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)) from exc
        device = await run_in_threadpool(device_database.owned_device, user_id, normalized_mac)
        if device is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device not found")
        events = await run_in_threadpool(device_database.list_events, user_id, normalized_mac, limit, offset)
        return DeviceEventsResponse(
            items=[DeviceEventResponse(**event.__dict__) for event in events],
            limit=limit,
            offset=offset,
        )

    return app


# Importing this module is safe without secrets; startup validation prevents an
# accidentally insecure process from serving requests.
app = create_app()
