#!/usr/bin/env bash
# Issue one reusable MQTT client identity from the VPS-local private CA.
#
# The default mode intentionally requires root: the CA private key is root-only
# readable and must never be copied away from the VPS. GARAGE_MQTT_ALLOW_NON_ROOT=1
# exists only for the disposable local integration test, which uses a temporary
# MQTT_DIR and must never be used for a real deployment.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <device-id>" >&2
  exit 2
fi

DEVICE_ID="$1"
if [[ ! "$DEVICE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "error: device-id must contain only letters, numbers, '.', '_' or '-' and start with an alphanumeric character" >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ] && [ "${GARAGE_MQTT_ALLOW_NON_ROOT:-0}" != "1" ]; then
  echo "error: run this script as root so the CA private key remains root-only readable" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQTT_DIR="${MQTT_DIR:-$HOME/mqtt}"
CA_DIR="$MQTT_DIR/certs/ca"
DEVICE_DIR="$MQTT_DIR/certs/devices/$DEVICE_ID"
CA_KEY="$CA_DIR/ca.key"
CA_CERT="$CA_DIR/ca.crt"
CLIENT_KEY="$DEVICE_DIR/client.key"
CLIENT_CERT="$DEVICE_DIR/client.crt"

if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
  echo "error: CA is not initialized under $CA_DIR; run deploy/setup.sh first" >&2
  exit 1
fi

mkdir -p "$DEVICE_DIR"
chmod 0755 "$CA_DIR"
chmod 0700 "$DEVICE_DIR"
if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$CA_DIR" "$DEVICE_DIR" "$CA_KEY"
  chmod 0600 "$CA_KEY"
fi

if [ -e "$CLIENT_KEY" ] || [ -e "$CLIENT_CERT" ]; then
  if [ ! -f "$CLIENT_KEY" ] || [ ! -f "$CLIENT_CERT" ]; then
    echo "error: incomplete existing certificate for device '$DEVICE_ID'; refusing to overwrite" >&2
    exit 1
  fi
  echo "certificate already exists for '$DEVICE_ID'; leaving it unchanged"
else
  umask 077
  csr="$(mktemp "$DEVICE_DIR/.client.XXXXXX.csr")"
  extfile="$(mktemp "$DEVICE_DIR/.client.XXXXXX.ext")"
  cleanup() {
    rm -f "$csr" "$extfile"
  }
  trap cleanup EXIT

  cat > "$extfile" <<EOF
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

  openssl genrsa -out "$CLIENT_KEY" 2048 >/dev/null 2>&1
  openssl req -new -key "$CLIENT_KEY" -out "$csr" -subj "/CN=$DEVICE_ID"
  openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAserial "$CA_DIR/ca.srl" -CAcreateserial -out "$CLIENT_CERT" \
    -days 825 -sha256 -extfile "$extfile"

  chmod 0600 "$CLIENT_KEY"
  chmod 0644 "$CLIENT_CERT"
  if [ "$(id -u)" -eq 0 ]; then
    chown root:root "$CLIENT_KEY" "$CLIENT_CERT"
  fi
  echo "issued client certificate for '$DEVICE_ID'"
fi

chmod 0600 "$CLIENT_KEY"
chmod 0644 "$CLIENT_CERT"
if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$CLIENT_KEY" "$CLIENT_CERT"
fi

echo
echo "Copy these three files to the device's TLS configuration:"
echo "  CA trust certificate: $CA_CERT"
echo "  Client certificate:   $CLIENT_CERT"
echo "  Client private key:   $CLIENT_KEY"
echo
echo "Connection settings:"
echo "  Broker endpoint:      ${MQTT_ENDPOINT:-<vps-public-host-or-ip>}:8883"
echo "  MQTT identity:        $DEVICE_ID"
echo "  MQTT password:        none (mutual TLS only)"
