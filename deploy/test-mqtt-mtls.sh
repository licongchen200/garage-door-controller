#!/usr/bin/env bash
# Disposable integration test for the complete Mosquitto mutual-TLS chain.
# It creates all state under mktemp, exercises the checked-in setup and issuer,
# and removes the stack and temporary certificates on exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/garage-mqtt-mtls.XXXXXX")"
MQTT_DIR="$TEST_ROOT/mqtt"
SUB_LOG="$TEST_ROOT/sub.log"
GARAGE_API_ENV_FILE="$TEST_ROOT/api.env"
NETWORK_CREATED=0

cat > "$GARAGE_API_ENV_FILE" <<'EOF'
JWT_SECRET=local-integration-test-secret-local-integration-test
APPLE_BUNDLE_ID=org.example.garage
EOF
export GARAGE_API_ENV_FILE

cleanup() {
  MQTT_DIR="$MQTT_DIR" docker compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1 || true
  if [ "$NETWORK_CREATED" -eq 1 ]; then
    docker network rm garage-network >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

DOCKER_VERSION="$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)"
if [ -z "$DOCKER_VERSION" ]; then
  echo "error: Docker daemon is required for the MQTT mTLS integration test" >&2
  exit 1
fi

if ! docker network inspect garage-network >/dev/null 2>&1; then
  docker network create garage-network >/dev/null
  NETWORK_CREATED=1
fi

MQTT_DIR="$MQTT_DIR" "$SCRIPT_DIR/setup.sh" --local-test >/dev/null
CA_KEY_SHA="$(shasum -a 256 "$MQTT_DIR/certs/ca/ca.key" | cut -d' ' -f1)"
CA_CERT_SHA="$(shasum -a 256 "$MQTT_DIR/certs/ca/ca.crt" | cut -d' ' -f1)"
MQTT_DIR="$MQTT_DIR" "$SCRIPT_DIR/setup.sh" --local-test >/dev/null
test "$CA_KEY_SHA" = "$(shasum -a 256 "$MQTT_DIR/certs/ca/ca.key" | cut -d' ' -f1)"
test "$CA_CERT_SHA" = "$(shasum -a 256 "$MQTT_DIR/certs/ca/ca.crt" | cut -d' ' -f1)"

MQTT_DIR="$MQTT_DIR" GARAGE_MQTT_ALLOW_NON_ROOT=1 \
  "$SCRIPT_DIR/issue-device-cert.sh" integration-device >/dev/null

MQTT_DIR="$MQTT_DIR" docker compose -f "$COMPOSE_FILE" up -d mosquitto >/dev/null
for _ in $(seq 1 30); do
  if [ "$(MQTT_DIR="$MQTT_DIR" docker compose -f "$COMPOSE_FILE" ps --status running --services | grep -c '^mosquitto$')" -eq 1 ]; then
    break
  fi
  sleep 1
done
if [ "$(MQTT_DIR="$MQTT_DIR" docker compose -f "$COMPOSE_FILE" ps --status running --services | grep -c '^mosquitto$')" -ne 1 ]; then
  echo "error: mosquitto did not become running" >&2
  exit 1
fi

CLIENT_IMAGE="eclipse-mosquitto:2"
CLIENT_MOUNTS=(
  -v "$MQTT_DIR/certs:/certs:ro"
  --network garage-network
)

if docker run --rm "${CLIENT_MOUNTS[@]}" "$CLIENT_IMAGE" mosquitto_pub \
  -h mosquitto -p 8883 --cafile /certs/ca/ca.crt \
  -t garage/test/no-client-cert -m rejected; then
  echo "error: broker accepted a client with no certificate" >&2
  exit 1
fi

mkdir -p "$TEST_ROOT/untrusted"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TEST_ROOT/untrusted/client.key" \
  -out "$TEST_ROOT/untrusted/client.crt" \
  -days 1 -subj "/CN=untrusted-client" >/dev/null 2>&1
chmod 0644 "$TEST_ROOT/untrusted/client.key" "$TEST_ROOT/untrusted/client.crt"

if docker run --rm "${CLIENT_MOUNTS[@]}" -v "$TEST_ROOT/untrusted:/untrusted:ro" "$CLIENT_IMAGE" mosquitto_pub \
  -h mosquitto -p 8883 --cafile /certs/ca/ca.crt \
  --cert /untrusted/client.crt --key /untrusted/client.key \
  -t garage/test/untrusted -m rejected; then
  echo "error: broker accepted a client certificate not signed by this CA" >&2
  exit 1
fi

docker run --rm "${CLIENT_MOUNTS[@]}" "$CLIENT_IMAGE" mosquitto_sub \
  -h mosquitto -p 8883 --cafile /certs/ca/ca.crt \
  --cert /certs/devices/integration-device/client.crt \
  --key /certs/devices/integration-device/client.key \
  -t garage/test/accepted -C 1 -W 10 -v > "$SUB_LOG" 2>&1 &
SUB_PID=$!
sleep 1
docker run --rm "${CLIENT_MOUNTS[@]}" "$CLIENT_IMAGE" mosquitto_pub \
  -h mosquitto -p 8883 --cafile /certs/ca/ca.crt \
  --cert /certs/devices/integration-device/client.crt \
  --key /certs/devices/integration-device/client.key \
  -t garage/test/accepted -m accepted
wait "$SUB_PID"
grep -Fq 'garage/test/accepted accepted' "$SUB_LOG"

echo "MQTT mTLS integration passed: no-cert rejected, untrusted-cert rejected, issued-cert pub/sub succeeded"
