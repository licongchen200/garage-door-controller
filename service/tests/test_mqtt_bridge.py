import json
from types import SimpleNamespace

from app.config import Settings
from app.mqtt_bridge import ACK_TOPIC, LWT_TOPIC, STATE_TOPIC, MqttBridge


def message(topic, payload):
    return SimpleNamespace(topic=topic, payload=json.dumps(payload).encode())


def test_state_and_lwt_messages_update_in_memory_snapshot():
    bridge = MqttBridge(Settings())
    bridge._on_message(None, None, message(STATE_TOPIC, {"state": "open", "ts": 123}))
    assert bridge.snapshot().state == "open"
    assert bridge.snapshot().online is True
    assert bridge.snapshot().ts == 123

    bridge._on_message(None, None, message(LWT_TOPIC, {"online": False}))
    assert bridge.snapshot().online is False
    assert bridge.snapshot().state == "open"


def test_command_ack_unblocks_waiting_command():
    bridge = MqttBridge(Settings(mqtt_ack_timeout_seconds=0.2))
    fake_client = SimpleNamespace(is_connected=lambda: True)

    class PublishInfo:
        rc = 0

    def publish(topic, payload):
        decoded = json.loads(payload)
        bridge._on_message(None, None, message(ACK_TOPIC, {"id": decoded["id"], "result": "triggered"}))
        return PublishInfo()

    fake_client.publish = publish
    bridge._client = fake_client
    result, command_id = bridge.trigger("open")
    assert result == "triggered"
    assert command_id


def test_command_is_error_without_broker():
    bridge = MqttBridge(Settings(mqtt_ack_timeout_seconds=0.01))
    result, command_id = bridge.trigger("close")
    assert result == "error"
    assert command_id
