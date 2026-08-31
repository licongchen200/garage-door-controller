#!/usr/bin/env bash
# Stop a long-lived deploy Python script started by run-detached.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <script.py>" >&2
  exit 2
fi

SCRIPT_NAME="$(basename "$1")"
SCRIPT_BASENAME="${SCRIPT_NAME%.py}"
PID_FILE="$LOG_DIR/$SCRIPT_BASENAME.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "no pidfile for $SCRIPT_NAME: $PID_FILE" >&2
  exit 1
fi

PID="$(<"$PID_FILE")"
if [[ ! "$PID" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: invalid PID in $PID_FILE" >&2
  exit 1
fi

if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "stopped $SCRIPT_NAME (PID: $PID)"
else
  echo "$SCRIPT_NAME is not running (stale PID: $PID)"
fi

rm -f "$PID_FILE"
