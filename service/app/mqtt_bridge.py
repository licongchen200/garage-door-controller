"""MQTT subscriber/publisher used by the REST layer.

The bridge is deliberately usable without a broker: it starts and keeps the initial
state as unknown/offline while paho retries in the background.
"""

from __future__ import annotations

import json
import logging
import os
import ssl
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import paho.mqtt.client as mqtt

from .config import Settings

try:
    from .database import Database, normalize_mac_address
except ImportError:  # pragma: no cover - keeps isolated tooling imports usable
    Database = Any

    def normalize_mac_address(value: str) -> str:
        return value

logger = logging.getLogger(__name__)

TOPIC_PREFIX = "garage/door"
STATE_TOPIC = f"{TOPIC_PREFIX}/{{mac}}/state"
COMMAND_TOPIC = f"{TOPIC_PREFIX}/{{mac}}/cmd"
ACK_TOPIC = f"{TOPIC_PREFIX}/{{mac}}/cmd/ack"
LWT_TOPIC = f"{TOPIC_PREFIX}/{{mac}}/lwt"
STATE_TOPIC_WILDCARD = f"{TOPIC_PREFIX}/+/state"
ACK_TOPIC_WILDCARD = f"{TOPIC_PREFIX}/+/cmd/ack"
LWT_TOPIC_WILDCARD = f"{TOPIC_PREFIX}/+/lwt"
VALID_STATES = {"open", "closed", "unknown"}


@dataclass(frozen=True)
class DoorSnapshot:
    state: str
    online: bool
    ts: Any


def topic_for_device(mac_address: str, suffix: str) -> str:
    return f"{TOPIC_PREFIX}/{normalize_mac_address(mac_address)}/{suffix}"


class MqttBridge:
    def __init__(self, settings: Settings, event_store: Database | None = None):
        self.settings = settings
        self.event_store = event_store
        self._lock = threading.RLock()
        self._ack_events: dict[str, tuple[threading.Event, dict[str, str]]] = {}
        self._states: dict[str, DoorSnapshot] = {}
        self._client: mqtt.Client | None = None
        self._started = False

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            for name, path in (
                ("MQTT_CA_FILE", self.settings.mqtt_ca_file),
                ("MQTT_CERT_FILE", self.settings.mqtt_cert_file),
                ("MQTT_KEY_FILE", self.settings.mqtt_key_file),
            ):
                if not path or not os.path.isfile(path):
                    raise RuntimeError(f"{name} must point to an existing TLS file")
            client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
            client.tls_set(
                ca_certs=self.settings.mqtt_ca_file,
                certfile=self.settings.mqtt_cert_file,
                keyfile=self.settings.mqtt_key_file,
                tls_version=ssl.PROTOCOL_TLS_CLIENT,
            )
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

    def snapshot(self, mac_address: str) -> DoorSnapshot:
        mac_address = normalize_mac_address(mac_address)
        with self._lock:
            return self._states.get(mac_address, DoorSnapshot("unknown", False, None))

    def trigger(self, command: str, mac_address: str) -> tuple[str, str]:
        if command not in {"open", "close"}:
            raise ValueError("unsupported door command")
        command_topic = topic_for_device(mac_address, "cmd")
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
                info = client.publish(command_topic, json.dumps({"cmd": command, "id": command_id}))
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
        client.subscribe([(STATE_TOPIC_WILDCARD, 0), (ACK_TOPIC_WILDCARD, 0), (LWT_TOPIC_WILDCARD, 0)])
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
        device_id, kind = self._parse_device_topic(message.topic)
        if device_id is None:
            return
        if kind == "state":
            state = payload.get("state")
            if state not in VALID_STATES:
                return
            timestamp = payload.get("ts", datetime.now(timezone.utc).isoformat())
            with self._lock:
                previous = self._states.get(device_id)
                self._states[device_id] = DoorSnapshot(state, True, timestamp)
            if previous is None or previous.state != state:
                if self.event_store is not None:
                    try:
                        self.event_store.record_state_change(device_id, state, timestamp)
                    except Exception:
                        logger.exception("unable to record state event for %s", device_id)
        elif kind == "lwt":
            with self._lock:
                previous = self._states.get(device_id, DoorSnapshot("unknown", False, None))
                self._states[device_id] = DoorSnapshot(previous.state, bool(payload.get("online", False)), previous.ts)
        elif kind == "cmd/ack":
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

    @staticmethod
    def _parse_device_topic(topic: str) -> tuple[str | None, str | None]:
        parts = topic.split("/")
        if len(parts) not in {4, 5} or parts[:2] != ["garage", "door"]:
            return None, None
        try:
            device_id = normalize_mac_address(parts[2])
        except ValueError:
            return None, None
        if parts[3] == "state":
            return device_id, "state"
        if parts[3] == "lwt":
            return device_id, "lwt"
        # Ack topics have five segments: garage/door/<mac>/cmd/ack.
        if len(parts) == 5 and parts[3:] == ["cmd", "ack"]:
            return device_id, "cmd/ack"
        return None, None
