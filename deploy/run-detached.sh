#!/usr/bin/env bash
# Run a long-lived deploy Python script independently of the invoking session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
LOG_DIR="$SCRIPT_DIR/logs"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <script.py> [args...]" >&2
  exit 2
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "error: $ENV_FILE is missing" >&2
  exit 1
fi
if [ ! -x "$PYTHON" ]; then
  echo "error: $PYTHON is missing or not executable" >&2
  exit 1
fi

SCRIPT_ARG="$1"
shift
case "$SCRIPT_ARG" in
  /*) SCRIPT_PATH="$SCRIPT_ARG" ;;
  *) SCRIPT_PATH="$PWD/$SCRIPT_ARG" ;;
esac
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "error: script not found: $SCRIPT_ARG" >&2
  exit 1
fi

SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_BASENAME="${SCRIPT_NAME%.py}"
LOG_FILE="$LOG_DIR/$SCRIPT_BASENAME.log"
PID_FILE="$LOG_DIR/$SCRIPT_BASENAME.pid"

mkdir -p "$LOG_DIR"

# Export values from deploy/.env so the child Python process receives them.
set -a
source "$ENV_FILE"
set +a

nohup "$PYTHON" -u "$SCRIPT_PATH" "$@" >> "$LOG_FILE" 2>&1 &
PID=$!
disown "$PID"
echo "$PID" > "$PID_FILE"

echo "started $SCRIPT_NAME"
echo "PID: $PID"
echo "Log: $LOG_FILE"
