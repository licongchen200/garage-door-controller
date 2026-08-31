# garage-door-controller

iOS app to monitor and control a garage door, backed by an ESP32 (relay + door sensor) and MQTT.

This repo covers the iOS app and its integration contract. The ESP32 firmware, physical wiring, and
home-server infrastructure (MQTT broker, and — as of v1 — a small Python bridge service) live outside
this repo.

See [`docs/architecture/`](docs/architecture/) for the design history:

- [v0 — MQTT direct](docs/architecture/v0-mqtt-direct.md): original draft, app talks to the MQTT broker directly.
- [v1 — Python API bridge](docs/architecture/v1-python-api-bridge.md): current design. MQTT stays local-only;
  a small Python service on the home server bridges it to a REST API, so only that API (not raw MQTT) is
  ever exposed to the internet.

Single environment, no dev/prod split — this is a small personal project.
