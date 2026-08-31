# Garage Door API service

FastAPI bridge between the internet-facing iOS client and the LAN-only MQTT broker. Run it with
Python 3.11+ (the service is also tested with current Python releases).

## Configuration

Copy `.env.example` to the process environment. `JWT_SECRET` and `APPLE_BUNDLE_ID` are required;
the service refuses to start without them. `APPLE_BUNDLE_ID` must equal the iOS app's bundle ID.
The API JWT uses **HS256** and lasts exactly **30 days** (`JWT_TTL_DAYS=30`). Keep the secret only
on the API host; never put it in the iOS app.

The MQTT client uses paho-mqtt and subscribes to the topics in
[`docs/architecture/v1-python-api-bridge.md`](../docs/architecture/v1-python-api-bridge.md). It
runs in the background and reconnects when the broker is unavailable. Until a state message arrives,
`GET /door/state` returns `{"state":"unknown","online":false,"ts":null}`. Door commands return
`error` when MQTT is unavailable or no matching acknowledgement arrives within three seconds.

Run locally:

```sh
cd service
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export JWT_SECRET="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export APPLE_BUNDLE_ID=com.example.garagedoor
uvicorn app.main:app --host 127.0.0.1 --port 8000
```

The API must be deployed behind HTTPS. The in-memory command rate limiter defaults to five commands
per user per 60 seconds; it is intended for this single-process, single-user deployment.
