CREATE TABLE IF NOT EXISTS users (
    apple_user_id TEXT PRIMARY KEY,
    email TEXT,
    full_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
    mac_address TEXT PRIMARY KEY,
    owner_apple_user_id TEXT NOT NULL REFERENCES users (apple_user_id) ON DELETE CASCADE,
    display_name TEXT,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS events (
    id BIGSERIAL PRIMARY KEY,
    mac_address TEXT NOT NULL REFERENCES devices (mac_address) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('command', 'state_change')),
    actor_apple_user_id TEXT REFERENCES users (apple_user_id) ON DELETE SET NULL,
    command TEXT CHECK (command IS NULL OR command IN ('open', 'close')),
    outcome TEXT CHECK (outcome IS NULL OR outcome IN ('triggered', 'error')),
    state TEXT CHECK (state IS NULL OR state IN ('open', 'closed', 'unknown')),
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (kind = 'command' AND actor_apple_user_id IS NOT NULL AND command IS NOT NULL AND outcome IS NOT NULL AND state IS NULL)
        OR
        (kind = 'state_change' AND actor_apple_user_id IS NULL AND command IS NULL AND outcome IS NULL AND state IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS events_device_occurred_idx
    ON events (mac_address, occurred_at DESC, id DESC);
