#!/usr/bin/env bash
# One-time host setup for the VPS MQTT broker and API client identity.
# Run this once per host before deploy.sh. The default mode is intentionally
# root-only so the CA private key is created with root ownership and mode 0600.
# It is safe to re-run: existing CA and certificate files are left unchanged.
set -euo pipefail

LOCAL_TEST=0
if [ "${1:-}" = "--local-test" ]; then
  LOCAL_TEST=1
  shift
fi
if [ "$#" -ne 0 ]; then
  echo "usage: $0 [--local-test]" >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ] && [ "$LOCAL_TEST" -ne 1 ]; then
  echo "error: run deploy/setup.sh as root; the CA private key must be root-only readable" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQTT_DIR="${MQTT_DIR:-$HOME/mqtt}"
CONFIG_DIR="$MQTT_DIR/config"
CERTS_DIR="$MQTT_DIR/certs"
CA_DIR="$CERTS_DIR/ca"
BROKER_DIR="$CERTS_DIR/broker"
DATA_DIR="$MQTT_DIR/data"
LOG_DIR="$MQTT_DIR/log"

umask 077
mkdir -p "$CONFIG_DIR" "$CA_DIR" "$BROKER_DIR" "$DATA_DIR" "$LOG_DIR"
chmod 0755 "$MQTT_DIR" "$CERTS_DIR" "$BROKER_DIR"
chmod 0755 "$CA_DIR"

CA_KEY="$CA_DIR/ca.key"
CA_CERT="$CA_DIR/ca.crt"
BROKER_KEY="$BROKER_DIR/server.key"
BROKER_CERT="$BROKER_DIR/server.crt"

if [ ! -f "$CA_KEY" ]; then
  openssl genrsa -out "$CA_KEY" 4096 >/dev/null 2>&1
  echo "created $CA_KEY"
else
  echo "$CA_KEY already exists, leaving it unchanged"
fi

if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$CA_KEY"
fi
chmod 0600 "$CA_KEY"

if [ ! -f "$CA_CERT" ]; then
  openssl req -x509 -new -key "$CA_KEY" -sha256 -days 3650 \
    -out "$CA_CERT" -subj "/CN=Garage Door Controller Private CA" \
    -addext "basicConstraints=critical,CA:true,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  echo "created $CA_CERT"
else
  echo "$CA_CERT already exists, leaving it unchanged"
fi
chmod 0644 "$CA_CERT"

if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$CA_DIR" "$CA_CERT"
fi

if [ -e "$BROKER_KEY" ] || [ -e "$BROKER_CERT" ]; then
  if [ ! -f "$BROKER_KEY" ] || [ ! -f "$BROKER_CERT" ]; then
    echo "error: incomplete existing broker certificate; refusing to overwrite" >&2
    exit 1
  fi
  echo "broker certificate already exists, leaving it unchanged"
else
  broker_csr="$(mktemp "$BROKER_DIR/.server.XXXXXX.csr")"
  broker_ext="$(mktemp "$BROKER_DIR/.server.XXXXXX.ext")"
  cleanup_broker() {
    rm -f "$broker_csr" "$broker_ext"
  }
  trap cleanup_broker EXIT
  cat > "$broker_ext" <<'EOF'
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:mosquitto, DNS:localhost, DNS:mqtt.proximadigital.app, IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl genrsa -out "$BROKER_KEY" 2048 >/dev/null 2>&1
  openssl req -new -key "$BROKER_KEY" -out "$broker_csr" -subj "/CN=garage-mqtt-broker"
  openssl x509 -req -in "$broker_csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAserial "$CA_DIR/ca.srl" -CAcreateserial -out "$BROKER_CERT" \
    -days 825 -sha256 -extfile "$broker_ext"
  cleanup_broker
  trap - EXIT
  echo "created $BROKER_CERT"
fi

chmod 0644 "$BROKER_CERT"
if [ "$(id -u)" -eq 0 ]; then
  # eclipse-mosquitto runs as uid/gid 1883 and must read only this broker key.
  chown 1883:1883 "$BROKER_KEY"
  chmod 0640 "$BROKER_KEY"
else
  # Only the disposable --local-test path can reach this branch.
  chmod 0644 "$BROKER_KEY"
fi

if [ "$LOCAL_TEST" -eq 1 ]; then
  GARAGE_MQTT_ALLOW_NON_ROOT=1 MQTT_DIR="$MQTT_DIR" \
    "$SCRIPT_DIR/issue-device-cert.sh" garage-api
else
  MQTT_DIR="$MQTT_DIR" "$SCRIPT_DIR/issue-device-cert.sh" garage-api
fi

if ! docker network inspect garage-network >/dev/null 2>&1; then
  docker network create garage-network
  echo "created garage-network"
else
  echo "garage-network already exists"
fi

if [ ! -f "$CONFIG_DIR/mosquitto.conf" ]; then
  cp "$SCRIPT_DIR/mosquitto/mosquitto.conf" "$CONFIG_DIR/mosquitto.conf"
  chmod 0644 "$CONFIG_DIR/mosquitto.conf"
  echo "wrote $CONFIG_DIR/mosquitto.conf"
else
  echo "$CONFIG_DIR/mosquitto.conf already exists, leaving it alone"
fi

EXISTING_BROKER="$(docker ps --filter 'publish=8883' --format '{{.Names}}' | head -1)"
if [ -n "$EXISTING_BROKER" ]; then
  echo "a broker is already listening on 8883 ($EXISTING_BROKER) - not starting a second one"
  docker network connect garage-network "$EXISTING_BROKER" 2>/dev/null \
    && echo "joined $EXISTING_BROKER to garage-network" \
    || echo "$EXISTING_BROKER is already on garage-network"
else
  MQTT_DIR="$MQTT_DIR" docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d mosquitto
  echo "mosquitto is up on directly exposed MQTTS port 8883"
fi

echo
echo "MQTT TLS state: $MQTT_DIR/certs"
echo "CA private key: $CA_KEY (0600, root:root; keep on this VPS and never copy it)"
echo "CA certificate: $CA_CERT"
echo "Broker certificate: $BROKER_CERT"
echo "API client certificate: $MQTT_DIR/certs/devices/garage-api/client.crt"
echo "API client key: $MQTT_DIR/certs/devices/garage-api/client.key"
echo "join the shared nginx container to garage-network, then install deploy/nginx/garage-api.conf in its conf.d directory"
