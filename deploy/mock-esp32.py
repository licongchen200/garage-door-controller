#!/usr/bin/env python3
"""Stand-in for the real ESP32 while it isn't wired up yet.

Connects to the MQTT broker as an ordinary certificate-bearing client and
behaves the way the real ESP32 is expected to: publishes a retained door state
on startup and on every state change, and answers every command on the device's
MAC-scoped command topic with an ack after a short simulated delay.

Usage:
    pip install paho-mqtt
    MQTT_DEVICE_MAC=aabbccddeeff MQTT_HOST=... MQTT_PORT=8883 \
    MQTT_CA_FILE=... MQTT_CERT_FILE=... MQTT_KEY_FILE=... \
        python3 mock-esp32.py

Reads the MQTT TLS variables from deploy/.env or the environment. Use a separate
client certificate for this mock (issued under the same MAC passed as
`MQTT_DEVICE_MAC`) when testing alongside the API.
"""
from __future__ import annotations

import json
import os
import ssl
import time

import paho.mqtt.client as mqtt

SIMULATED_TRANSITION_SECONDS = 2.0

door_state = "closed"


def publish_state(client: mqtt.Client, topics: dict[str, str]) -> None:
    payload = json.dumps({"state": door_state, "ts": int(time.time())})
    client.publish(topics["state"], payload, retain=True)
    print(f"-> state: {door_state}")


def on_connect(client: mqtt.Client, userdata, flags, reason_code, properties) -> None:
    if reason_code.is_failure:
        print(f"connect failed: {reason_code}")
        return
    topics = userdata["topics"]
    print("connected - subscribing to", topics["cmd"])
    client.subscribe(topics["cmd"])
    client.will_set(topics["lwt"], json.dumps({"online": False}), retain=True)
    client.publish(topics["lwt"], json.dumps({"online": True}), retain=True)
    publish_state(client, topics)


def on_message(client: mqtt.Client, userdata, message: mqtt.MQTTMessage) -> None:
    global door_state
    try:
        payload = json.loads(message.payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print("ignoring invalid JSON command")
        return

    cmd = payload.get("cmd")
    command_id = payload.get("id")
    if cmd not in ("open", "close") or not command_id:
        print(f"ignoring malformed command: {payload}")
        return

    print(f"<- command: {cmd} (id={command_id})")
    time.sleep(SIMULATED_TRANSITION_SECONDS)

    door_state = "open" if cmd == "open" else "closed"
    topics = userdata["topics"]
    client.publish(topics["ack"], json.dumps({"id": command_id, "result": "triggered"}))
    publish_state(client, topics)


def main() -> None:
    host = os.environ.get("MQTT_HOST", "localhost")
    port = int(os.environ.get("MQTT_PORT", "8883"))
    ca_file = os.path.expanduser(os.environ.get("MQTT_CA_FILE", "~/mqtt/certs/ca/ca.crt"))
    device_mac = os.environ.get("MQTT_DEVICE_MAC", "000000000001").replace(":", "").lower()
    if len(device_mac) != 12 or any(character not in "0123456789abcdef" for character in device_mac):
        raise SystemExit("MQTT_DEVICE_MAC must be 12 hexadecimal characters")
    topics = {
        "state": f"garage/door/{device_mac}/state",
        "cmd": f"garage/door/{device_mac}/cmd",
        "ack": f"garage/door/{device_mac}/cmd/ack",
        "lwt": f"garage/door/{device_mac}/lwt",
    }
    cert_file = os.path.expanduser(
        os.environ.get("MQTT_CERT_FILE", f"~/mqtt/certs/devices/{device_mac}/client.crt")
    )
    key_file = os.path.expanduser(
        os.environ.get("MQTT_KEY_FILE", f"~/mqtt/certs/devices/{device_mac}/client.key")
    )

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"mock-esp32-{device_mac}",
        userdata={"topics": topics},
    )
    client.tls_set(
        ca_certs=ca_file,
        certfile=cert_file,
        keyfile=key_file,
        tls_version=ssl.PROTOCOL_TLS_CLIENT,
    )
    client.on_connect = on_connect
    client.on_message = on_message

    print(f"connecting to {host}:{port} as mock device {device_mac} with client certificate ...")
    client.connect(host, port, keepalive=30)
    client.loop_forever()


if __name__ == "__main__":
    main()
