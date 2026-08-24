-- Applied by the api at startup. Every statement is idempotent.

CREATE TABLE IF NOT EXISTS subscriptions (
    id          uuid        PRIMARY KEY,
    url         text        NOT NULL,
    event_type  text        NOT NULL,
    secret      text        NOT NULL,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- The same URL for the same event type is one subscription, not two.
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_url_event_type_key
    ON subscriptions (url, event_type);

-- The worker's hot path: live subscribers for an event type.
CREATE INDEX IF NOT EXISTS subscriptions_event_type_idx
    ON subscriptions (event_type) WHERE active;

CREATE TABLE IF NOT EXISTS events (
    id          uuid        PRIMARY KEY,
    type        text        NOT NULL,
    payload     jsonb       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS delivery_attempts (
    id              bigserial   PRIMARY KEY,
    event_id        uuid        NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    subscription_id uuid        NOT NULL REFERENCES subscriptions (id) ON DELETE CASCADE,
    attempt_no      int         NOT NULL,
    status_code     int,
    error           text,
    duration_ms     int         NOT NULL,
    attempted_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS delivery_attempts_event_id_idx
    ON delivery_attempts (event_id);

-- Asked on every redelivery, to skip subscribers that already returned 2xx.
CREATE INDEX IF NOT EXISTS delivery_attempts_delivered_idx
    ON delivery_attempts (event_id, subscription_id)
    WHERE status_code BETWEEN 200 AND 299;
