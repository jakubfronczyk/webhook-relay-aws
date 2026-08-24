-- Applied by both api and worker at startup. Every statement is idempotent, so
-- N tasks racing on a cold cluster converge instead of one of them crashing.

CREATE TABLE IF NOT EXISTS subscriptions (
    id          uuid        PRIMARY KEY,
    url         text        NOT NULL,
    event_type  text        NOT NULL,
    secret      text        NOT NULL,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Registering the same URL for the same event type twice is the same
-- subscription, not two. Without this, a client retrying a 500 on
-- POST /subscriptions silently doubles every future delivery to itself.
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_url_event_type_key
    ON subscriptions (url, event_type);

-- The worker's hot path: "which live subscribers want this event type?"
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

-- Answers "has this (event, subscriber) pair already succeeded?" without a scan.
-- The worker asks this on every redelivery so a retry for subscriber B does not
-- re-POST to subscriber A, which already returned 2xx.
CREATE INDEX IF NOT EXISTS delivery_attempts_delivered_idx
    ON delivery_attempts (event_id, subscription_id)
    WHERE status_code BETWEEN 200 AND 299;
