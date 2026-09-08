import json
from types import SimpleNamespace

from app.config import Settings
from app.mqtt_bridge import ACK_TOPIC, LWT_TOPIC, STATE_TOPIC, MqttBridge
from fakes import FakeDatabase


def message(topic, payload):
    return SimpleNamespace(topic=topic, payload=json.dumps(payload).encode())


def test_state_and_lwt_messages_update_in_memory_snapshot():
    bridge = MqttBridge(Settings())
    device_id = "aabbccddeeff"
    bridge._on_message(None, None, message(STATE_TOPIC.format(mac=device_id), {"state": "open", "ts": 123}))
    assert bridge.snapshot(device_id).state == "open"
    assert bridge.snapshot(device_id).online is True
    assert bridge.snapshot(device_id).ts == 123

    bridge._on_message(None, None, message(LWT_TOPIC.format(mac=device_id), {"online": False}))
    assert bridge.snapshot(device_id).online is False
    assert bridge.snapshot(device_id).state == "open"


def test_command_ack_unblocks_waiting_command():
    bridge = MqttBridge(Settings(mqtt_ack_timeout_seconds=0.2))
    fake_client = SimpleNamespace(is_connected=lambda: True)

    class PublishInfo:
        rc = 0

    def publish(topic, payload):
        decoded = json.loads(payload)
        bridge._on_message(
            None,
            None,
            message(ACK_TOPIC.format(mac="aabbccddeeff"), {"id": decoded["id"], "result": "triggered"}),
        )
        return PublishInfo()

    fake_client.publish = publish
    bridge._client = fake_client
    result, command_id = bridge.trigger("open", "aabbccddeeff")
    assert result == "triggered"
    assert command_id


def test_command_is_error_without_broker():
    bridge = MqttBridge(Settings(mqtt_ack_timeout_seconds=0.01))
    result, command_id = bridge.trigger("close", "aabbccddeeff")
    assert result == "error"
    assert command_id


def test_state_transition_is_recorded_for_the_mac_scoped_device():
    store = FakeDatabase()
    store.record_user_once("owner", None, None)
    store.register_device("owner", "aabbccddeeff", None)
    bridge = MqttBridge(Settings(), event_store=store)
    topic = STATE_TOPIC.format(mac="aabbccddeeff")

    bridge._on_message(None, None, message(topic, {"state": "closed", "ts": 123}))
    bridge._on_message(None, None, message(topic, {"state": "closed", "ts": 124}))
    bridge._on_message(None, None, message(topic, {"state": "open", "ts": 125}))

    assert [event.state for event in store.events] == ["closed", "open"]
