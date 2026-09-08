#!/usr/bin/env bash
# Watch every garage/# message live with the broker container's own client.
# Run on the host where the mosquitto container lives:
#   deploy/watch-mqtt.sh
set -euo pipefail

CONTAINER="${MQTT_CONTAINER:-mosquitto}"
CA_FILE="${MQTT_CA_FILE:-/mosquitto/certs/ca/ca.crt}"
CERT_FILE="${MQTT_CERT_FILE:-/mosquitto/certs/devices/garage-api/client.crt}"
KEY_FILE="${MQTT_KEY_FILE:-/mosquitto/certs/devices/garage-api/client.key}"

echo "watching garage/# on $CONTAINER — ctrl-c to stop"
docker exec "$CONTAINER" mosquitto_sub -h localhost -p 8883 \
  --cafile "$CA_FILE" --cert "$CERT_FILE" --key "$KEY_FILE" \
  -t 'garage/#' -v
