from datetime import datetime, timezone

from app.database import DeviceAlreadyOwnedError, DeviceRecord, EventRecord, normalize_mac_address


class FakeDatabase:
    def __init__(self):
        self.users = {}
        self.devices = {}
        self.events = []

    def ensure_schema(self):
        pass

    def record_user_once(self, apple_user_id, email, full_name):
        self.users.setdefault(
            apple_user_id,
            {"email": email, "full_name": full_name},
        )

    def register_device(self, user_id, mac_address, display_name):
        mac_address = normalize_mac_address(mac_address)
        existing = self.devices.get(mac_address)
        if existing is not None and existing.owner_apple_user_id != user_id:
            raise DeviceAlreadyOwnedError("device is already registered to another user")
        if existing is not None:
            return existing
        record = DeviceRecord(mac_address, user_id, display_name, datetime.now(timezone.utc))
        self.devices[mac_address] = record
        return record

    def first_owned_device(self, user_id):
        devices = [device for device in self.devices.values() if device.owner_apple_user_id == user_id]
        return sorted(devices, key=lambda device: (device.registered_at, device.mac_address))[0] if devices else None

    def owned_device(self, user_id, mac_address):
        device = self.devices.get(normalize_mac_address(mac_address))
        return device if device is not None and device.owner_apple_user_id == user_id else None

    def record_command(self, user_id, mac_address, command, outcome):
        self.events.append(
            EventRecord(
                len(self.events) + 1,
                normalize_mac_address(mac_address),
                "command",
                user_id,
                command,
                outcome,
                None,
                datetime.now(timezone.utc),
            )
        )

    def record_state_change(self, mac_address, state, occurred_at=None):
        mac_address = normalize_mac_address(mac_address)
        if mac_address not in self.devices:
            return
        if isinstance(occurred_at, (int, float)):
            occurred_at = datetime.fromtimestamp(occurred_at, timezone.utc)
        self.events.append(
            EventRecord(
                len(self.events) + 1,
                mac_address,
                "state_change",
                None,
                None,
                None,
                state,
                occurred_at or datetime.now(timezone.utc),
            )
        )

    def list_events(self, user_id, mac_address, limit, offset):
        mac_address = normalize_mac_address(mac_address)
        if self.owned_device(user_id, mac_address) is None:
            return []
        events = [event for event in self.events if event.mac_address == mac_address]
        events.reverse()
        return events[offset : offset + limit]
