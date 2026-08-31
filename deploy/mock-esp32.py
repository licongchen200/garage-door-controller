#!/usr/bin/env python3
"""Stand-in for the real ESP32 while it isn't wired up yet.

Connects to the MQTT broker as an ordinary client and behaves the way the
real ESP32 is expected to: publishes a retained door state on startup and on
every state change, and answers every command on garage/door/cmd with an ack
on garage/door/cmd/ack after a short simulated delay - so the iOS app and the
Python API service can be exercised end-to-end before real hardware exists.

Usage:
    pip install paho-mqtt
    MQTT_HOST=... MQTT_PORT=1883 MQTT_USERNAME=... MQTT_PASSWORD=... \
        python3 mock-esp32.py

Reads the same MQTT_* variables as service/.env.example, so on the server
you can just run this with deploy/.env sourced.
"""
from __future__ import annotations

import json
import os
import time

import paho.mqtt.client as mqtt

STATE_TOPIC = "garage/door/state"
CMD_TOPIC = "garage/door/cmd"
ACK_TOPIC = "garage/door/cmd/ack"
LWT_TOPIC = "garage/door/lwt"

SIMULATED_TRANSITION_SECONDS = 2.0

door_state = "closed"


def publish_state(client: mqtt.Client) -> None:
    payload = json.dumps({"state": door_state, "ts": int(time.time())})
    client.publish(STATE_TOPIC, payload, retain=True)
    print(f"-> state: {door_state}")


def on_connect(client: mqtt.Client, userdata, flags, reason_code, properties) -> None:
    if reason_code.is_failure:
        print(f"connect failed: {reason_code}")
        return
    print("connected - subscribing to", CMD_TOPIC)
    client.subscribe(CMD_TOPIC)
    client.will_set(LWT_TOPIC, json.dumps({"online": False}), retain=True)
    client.publish(LWT_TOPIC, json.dumps({"online": True}), retain=True)
    publish_state(client)


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
    client.publish(ACK_TOPIC, json.dumps({"id": command_id, "result": "triggered"}))
    publish_state(client)


def main() -> None:
    host = os.environ.get("MQTT_HOST", "localhost")
    port = int(os.environ.get("MQTT_PORT", "1883"))
    username = os.environ.get("MQTT_USERNAME") or None
    password = os.environ.get("MQTT_PASSWORD") or None

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="mock-esp32")
    if username:
        client.username_pw_set(username, password)
    client.on_connect = on_connect
    client.on_message = on_message

    print(f"connecting to {host}:{port} as mock-esp32 ...")
    client.connect(host, port, keepalive=30)
    client.loop_forever()


if __name__ == "__main__":
    main()
