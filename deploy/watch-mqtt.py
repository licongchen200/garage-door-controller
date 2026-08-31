#!/usr/bin/env python3
"""Watch every garage/# message live, over the network - works from any
machine with network access to the broker (your laptop, the server itself,
anywhere), not just the server itself.

Run this while testing from the iOS app (or curl, or mock-esp32.py) to see
exactly what hits the broker.

Usage:
    pip install paho-mqtt
    python3 watch-mqtt.py

Reads MQTT_HOST/MQTT_PORT/MQTT_USERNAME/MQTT_PASSWORD from deploy/.env next to
this script (same file deploy.sh and mock-esp32.py use), or from the
environment - environment variables win if both are set.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import paho.mqtt.client as mqtt


def load_env_file() -> dict[str, str]:
    env_path = Path(__file__).resolve().parent / ".env"
    values: dict[str, str] = {}
    if not env_path.exists():
        return values
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def setting(env_file: dict[str, str], key: str, default: str = "") -> str:
    return os.environ.get(key) or env_file.get(key, default)


def on_connect(client: mqtt.Client, userdata, flags, reason_code, properties) -> None:
    if reason_code.is_failure:
        print(f"connect failed: {reason_code}")
        return
    print("connected - subscribing to garage/# ...")
    client.subscribe("garage/#")


def on_message(client: mqtt.Client, userdata, message: mqtt.MQTTMessage) -> None:
    ts = time.strftime("%H:%M:%S")
    try:
        payload = json.loads(message.payload.decode("utf-8"))
        payload_str = json.dumps(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload_str = message.payload.decode("utf-8", errors="replace")
    print(f"[{ts}] {message.topic}  {payload_str}")


def main() -> None:
    env_file = load_env_file()
    host = setting(env_file, "MQTT_HOST", "localhost")
    port = int(setting(env_file, "MQTT_PORT", "1883"))
    username = setting(env_file, "MQTT_USERNAME") or None
    password = setting(env_file, "MQTT_PASSWORD") or None

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="watch-mqtt")
    if username:
        client.username_pw_set(username, password)
    client.on_connect = on_connect
    client.on_message = on_message

    print(f"connecting to {host}:{port} ... (ctrl-c to stop)")
    client.connect(host, port, keepalive=30)
    try:
        client.loop_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
