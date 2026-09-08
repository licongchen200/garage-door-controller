#!/usr/bin/env bash
# Deploy or redeploy the garage-door-api service. Run this whenever the
# service code changes. Assumes setup.sh has already been run once and
# deploy/.env already exists with real secrets filled in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "error: $SCRIPT_DIR/.env is missing." >&2
  echo "Create it from .env.example first (JWT_SECRET and APPLE_BUNDLE_ID are required)." >&2
  exit 1
fi

MQTT_DIR="${MQTT_DIR:-$HOME/mqtt}"
for required_file in \
  "$MQTT_DIR/certs/ca/ca.crt" \
  "$MQTT_DIR/certs/devices/garage-api/client.crt" \
  "$MQTT_DIR/certs/devices/garage-api/client.key"; do
  if [ ! -f "$required_file" ]; then
    echo "error: missing MQTT TLS file: $required_file" >&2
    echo "Run deploy/setup.sh as root before deploying the API." >&2
    exit 1
  fi
done

git -C "$SCRIPT_DIR/.." pull
MQTT_DIR="$MQTT_DIR" docker compose -f "$SCRIPT_DIR/docker-compose.yml" build garage-door-api
MQTT_DIR="$MQTT_DIR" docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d garage-door-api
echo "garage-door-api deployed"
