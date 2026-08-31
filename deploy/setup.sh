#!/usr/bin/env bash
# One-time host setup for the garage-door-controller MQTT broker.
# Run this once per host before using deploy.sh. Safe to re-run: it skips
# anything that already exists, including an already-running broker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQTT_DIR="${MQTT_DIR:-$HOME/mqtt}"
MQTT_USER="${MQTT_USER:-firstmate}"

mkdir -p "$MQTT_DIR/config" "$MQTT_DIR/data" "$MQTT_DIR/log"

if [ ! -f "$MQTT_DIR/config/mosquitto.conf" ]; then
  cp "$SCRIPT_DIR/mosquitto/mosquitto.conf" "$MQTT_DIR/config/mosquitto.conf"
  echo "wrote $MQTT_DIR/config/mosquitto.conf"
else
  echo "$MQTT_DIR/config/mosquitto.conf already exists, leaving it alone"
fi

if [ ! -f "$MQTT_DIR/config/passwd" ]; then
  echo "No MQTT password file found. Creating one for user '$MQTT_USER'."
  read -rsp "Enter a password for MQTT user '$MQTT_USER': " MQTT_PASS
  echo
  docker run --rm -v "$MQTT_DIR/config:/mosquitto/config" eclipse-mosquitto:2 \
    mosquitto_passwd -b -c /mosquitto/config/passwd "$MQTT_USER" "$MQTT_PASS"
  chmod 0600 "$MQTT_DIR/config/passwd"
  echo "wrote $MQTT_DIR/config/passwd - put this same password in ../service/.env as MQTT_PASSWORD"
else
  echo "$MQTT_DIR/config/passwd already exists, leaving it alone"
fi

if docker ps --format '{{.Ports}}' | grep -q '1883->1883'; then
  echo "a broker is already listening on 1883 - not starting a second one"
else
  MQTT_DIR="$MQTT_DIR" docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d mosquitto
  echo "mosquitto is up"
fi
