# garage-door-controller

iOS app to monitor and control a garage door, backed by an ESP32 (relay + door sensor) and MQTT.

This repo contains the iOS app and the Python API bridge. The ESP32 firmware, physical wiring, and
home-server MQTT broker are documented in [`esp32/`](esp32/); physical wiring remains outside this
repo.

- [`ios/`](ios/) — SwiftUI app using Sign in with Apple, Keychain, and HTTPS polling.
- [`service/`](service/) — FastAPI service issuing app JWTs and bridging REST to VPS MQTT over mTLS.
- [`esp32/`](esp32/) — PlatformIO ESP32-C3 firmware and Wokwi LED simulation.

See [`service/README.md`](service/README.md) for configuration and local startup instructions.

See [`docs/architecture/`](docs/architecture/) for the design history:

- [v0 — MQTT direct](docs/architecture/v0-mqtt-direct.md): original draft, app talks to the MQTT broker directly.
- [v1 — Python API bridge](docs/architecture/v1-python-api-bridge.md): current design. Mosquitto and the
  Python service run on the VPS; MQTT is directly exposed on MQTTS `8883` with per-device certificates,
  while nginx exposes only the HTTPS API at `iot.proximadigital.app`.

Single environment, no dev/prod split — this is a small personal project.

## Deploying

See [`deploy/`](deploy/) for the Docker Compose setup:

- `deploy/setup.sh` — one-time per VPS: creates the private CA, broker certificate, `garage-api` client
  certificate, TLS-only Mosquitto configuration, and starts the broker on port `8883`.
- `deploy/issue-device-cert.sh <device-id>` — idempotently issues a separate client certificate/key
  pair for each future MQTT device without exposing the CA private key.
- `deploy/deploy.sh` — run this whenever the service code changes: pulls, rebuilds, and restarts just
  the `garage-door-api` container.

Both assume `deploy/.env` already exists (copy `deploy/.env.example` and fill in real values first).
