# garage-door-controller

iOS app to monitor and control a garage door, backed by an ESP32 (relay + door sensor) and MQTT.

This repo contains the iOS app and the Python API bridge. The ESP32 firmware, physical wiring, and
home-server MQTT broker are documented in [`esp32/`](esp32/); physical wiring remains outside this
repo.

- [`ios/`](ios/) — SwiftUI app using Sign in with Apple, Keychain, and HTTPS polling.
- [`service/`](service/) — FastAPI service issuing app JWTs and bridging REST to local MQTT.
- [`esp32/`](esp32/) — PlatformIO ESP32-C3 firmware and Wokwi LED simulation.

See [`service/README.md`](service/README.md) for configuration and local startup instructions.

See [`docs/architecture/`](docs/architecture/) for the design history:

- [v0 — MQTT direct](docs/architecture/v0-mqtt-direct.md): original draft, app talks to the MQTT broker directly.
- [v1 — Python API bridge](docs/architecture/v1-python-api-bridge.md): current design. MQTT stays local-only;
  a small Python service on the home server bridges it to a REST API, so only that API (not raw MQTT) is
  ever exposed to the internet.

Single environment, no dev/prod split — this is a small personal project.

## Deploying

See [`deploy/`](deploy/) for the Docker Compose setup:

- `deploy/setup.sh` — one-time per host: creates the MQTT broker's config/data/log directories, generates its password file if missing, and starts the broker (skipped if one's already running on port 1883).
- `deploy/deploy.sh` — run this whenever the service code changes: pulls, rebuilds, and restarts just the `garage-door-api` container.

Both assume `service/.env` already exists (copy `service/.env.example` and fill in real values first).
