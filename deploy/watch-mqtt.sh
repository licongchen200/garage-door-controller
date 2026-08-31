#!/usr/bin/env bash
# Watch every garage/# message live - run this while testing from the iOS app
# (or curl, or mock-esp32.py) to see exactly what hits the broker, before any
# real ESP32 is wired up. Uses the broker container's own mosquitto_sub, so
# nothing extra needs installing.
#
# Run on the host where the "mosquitto" container lives:
#   deploy/watch-mqtt.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${MQTT_CONTAINER:-mosquitto}"

ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  MQTT_USERNAME="$(grep -m1 '^MQTT_USERNAME=' "$ENV_FILE" | cut -d= -f2-)"
  MQTT_PASSWORD="$(grep -m1 '^MQTT_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
fi
: "${MQTT_USERNAME:?set MQTT_USERNAME (or put it in deploy/.env)}"
: "${MQTT_PASSWORD:?set MQTT_PASSWORD (or put it in deploy/.env)}"

echo "watching garage/# on $CONTAINER — ctrl-c to stop"
docker exec "$CONTAINER" mosquitto_sub -h localhost -p 1883 \
  -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" \
  -t 'garage/#' -v
