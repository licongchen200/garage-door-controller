#!/usr/bin/env bash
# Deploy or redeploy the garage-door-api service. Run this whenever the
# service code changes. Assumes setup.sh has already been run once and
# ../service/.env already exists with real secrets filled in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "error: $SCRIPT_DIR/.env is missing." >&2
  echo "Create it from .env.example first (JWT_SECRET, APPLE_BUNDLE_ID, MQTT_PASSWORD are required)." >&2
  exit 1
fi

git -C "$SCRIPT_DIR/.." pull
MQTT_DIR="${MQTT_DIR:-$HOME/mqtt}" docker compose -f "$SCRIPT_DIR/docker-compose.yml" build garage-door-api
MQTT_DIR="${MQTT_DIR:-$HOME/mqtt}" docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d garage-door-api
echo "garage-door-api deployed"
