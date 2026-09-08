# Garage Door API service

FastAPI bridge between the internet-facing iOS client and the VPS MQTT broker. Run it with Python
3.11+ (the service is also tested with current Python releases).

## Configuration

For a real deployment, see [`../deploy/`](../deploy/) - `deploy/.env` (copied from
`deploy/.env.example`) is what `docker-compose.yml` loads. `JWT_SECRET` and `APPLE_BUNDLE_ID` are
required; the service refuses to start without them. `APPLE_BUNDLE_ID` must equal the iOS app's
bundle ID. The API JWT uses **HS256** and lasts exactly **30 days** (`JWT_TTL_DAYS=30`). Keep the
secret only on the API host; never put it in the iOS app.

The service stores users, registered devices, and paginated operation history in PostgreSQL. The
deployment compose file starts a dedicated `postgres:16-alpine` service with a named volume and
loads the initial schema from [`app/schema.sql`](app/schema.sql). `DATABASE_URL` comes from
`deploy/.env`; the service creates the schema idempotently at startup after PostgreSQL is healthy.

The MQTT client uses paho-mqtt with the CA certificate and `garage-api` client certificate mounted
by compose at `/run/mqtt-certs/`. It subscribes to the topics in
[`docs/architecture/v1-python-api-bridge.md`](../docs/architecture/v1-python-api-bridge.md). It
runs in the background and reconnects when the broker is unavailable. TLS certificate files are
required at startup; there is no username/password fallback. Until a state message arrives,
`GET /door/state` returns `{"state":"unknown","online":false,"ts":null}`. Door commands return
`error` when MQTT is unavailable or no matching acknowledgement arrives within three seconds.

Run locally:

```sh
cd service
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export JWT_SECRET="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export APPLE_BUNDLE_ID=org.licongchen.home
uvicorn app.main:app --host 127.0.0.1 --port 8000
```

The API must be deployed behind HTTPS. The in-memory command rate limiter defaults to five commands
per user per 60 seconds; it is intended for this single-process deployment.

On the VPS, run `sudo deploy/setup.sh` once to create the private CA, broker identity, and
`garage-api` client identity, then use `deploy/deploy.sh` for the API image. The CA private key is
`$MQTT_DIR/certs/ca/ca.key`, mode `0600` and owned by `root:root`; it must remain on the VPS.
