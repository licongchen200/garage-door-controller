"""MQTT subscriber/publisher used by the REST layer.

The bridge is deliberately usable without a broker: it starts and keeps the initial
state as unknown/offline while paho retries in the background.
"""

from __future__ import annotations

import json
import logging
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import paho.mqtt.client as mqtt

from .config import Settings

logger = logging.getLogger(__name__)

STATE_TOPIC = "garage/door/state"
COMMAND_TOPIC = "garage/door/cmd"
ACK_TOPIC = "garage/door/cmd/ack"
LWT_TOPIC = "garage/door/lwt"
VALID_STATES = {"open", "closed", "unknown"}


@dataclass(frozen=True)
class DoorSnapshot:
    state: str
    online: bool
    ts: Any


class MqttBridge:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._lock = threading.RLock()
        self._ack_events: dict[str, tuple[threading.Event, dict[str, str]]] = {}
        self._state = DoorSnapshot("unknown", False, None)
        self._client: mqtt.Client | None = None
        self._started = False

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
            if self.settings.mqtt_username:
                client.username_pw_set(self.settings.mqtt_username, self.settings.mqtt_password)
            client.reconnect_delay_set(min_delay=1, max_delay=60)
            client.on_connect = self._on_connect
            client.on_message = self._on_message
            client.on_disconnect = self._on_disconnect
            self._client = client
            self._started = True
            try:
                # connect_async + loop_start retries without making API startup depend on
                # the broker being available during development.
                client.connect_async(
                    self.settings.mqtt_host, self.settings.mqtt_port, keepalive=60
                )
                client.loop_start()
            except Exception:
                logger.exception("unable to start MQTT client; continuing offline")

    def stop(self) -> None:
        with self._lock:
            client, self._client = self._client, None
            self._started = False
        if client is not None:
            try:
                client.disconnect()
            except Exception:
                logger.debug("MQTT disconnect failed", exc_info=True)
            client.loop_stop()

    def snapshot(self) -> DoorSnapshot:
        with self._lock:
            return self._state

    def trigger(self, command: str) -> tuple[str, str]:
        if command not in {"open", "close"}:
            raise ValueError("unsupported door command")
        command_id = str(uuid.uuid4())
        event = threading.Event()
        result: dict[str, str] = {}
        with self._lock:
            self._ack_events[command_id] = (event, result)
            client = self._client
            connected = client is not None and client.is_connected()
        try:
            if not connected or client is None:
                return "error", command_id
            try:
                info = client.publish(COMMAND_TOPIC, json.dumps({"cmd": command, "id": command_id}))
            except Exception:
                logger.exception("MQTT command publish failed")
                return "error", command_id
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                return "error", command_id
            if not event.wait(timeout=self.settings.mqtt_ack_timeout_seconds):
                return "error", command_id
            return result.get("result", "error"), command_id
        finally:
            with self._lock:
                self._ack_events.pop(command_id, None)

    def _on_connect(self, client: mqtt.Client, userdata: Any, flags: Any, reason_code: Any, properties: Any) -> None:
        if reason_code.is_failure:
            logger.warning("MQTT connection failed: %s", reason_code)
            return
        client.subscribe([(STATE_TOPIC, 0), (ACK_TOPIC, 0), (LWT_TOPIC, 0)])
        logger.info("MQTT connected to %s:%s", self.settings.mqtt_host, self.settings.mqtt_port)

    def _on_disconnect(self, client: mqtt.Client, userdata: Any, disconnect_flags: Any, reason_code: Any, properties: Any) -> None:
        if reason_code.is_failure:
            logger.info("MQTT disconnected: %s", reason_code)

    def _on_message(self, client: mqtt.Client, userdata: Any, message: mqtt.MQTTMessage) -> None:
        try:
            payload = json.loads(message.payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            logger.warning("ignoring invalid JSON on %s", message.topic)
            return
        if not isinstance(payload, dict):
            return
        if message.topic == STATE_TOPIC:
            state = payload.get("state")
            if state not in VALID_STATES:
                return
            timestamp = payload.get("ts", datetime.now(timezone.utc).isoformat())
            with self._lock:
                self._state = DoorSnapshot(state, True, timestamp)
        elif message.topic == LWT_TOPIC:
            with self._lock:
                self._state = DoorSnapshot(self._state.state, bool(payload.get("online", False)), self._state.ts)
        elif message.topic == ACK_TOPIC:
            command_id = payload.get("id")
            result = payload.get("result")
            if not isinstance(command_id, str) or result not in {"triggered", "error"}:
                return
            with self._lock:
                waiter = self._ack_events.get(command_id)
                if waiter:
                    event, result_box = waiter
                    result_box["result"] = result
                    event.set()
