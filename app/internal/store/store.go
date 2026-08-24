// Package store is the only place that talks to Postgres.
//
// Ids are Go strings cast to uuid in SQL rather than a uuid Go type. It keeps
// the pgx type map out of the picture and every query readable.
package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/jakubfronczyk/webhook-relay-aws/app/migrations"
)

// ErrNotFound is returned instead of pgx.ErrNoRows so callers do not import pgx.
var ErrNotFound = errors.New("not found")

type Store struct {
	pool *pgxpool.Pool
}

type Subscription struct {
	ID        string    `json:"id"`
	URL       string    `json:"url"`
	EventType string    `json:"event_type"`
	Secret    string    `json:"secret,omitempty"`
	Active    bool      `json:"active"`
	CreatedAt time.Time `json:"created_at"`
}

type Event struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}

type Attempt struct {
	SubscriptionID string    `json:"subscription_id"`
	AttemptNo      int       `json:"attempt_no"`
	StatusCode     *int      `json:"status_code"`
	Error          *string   `json:"error"`
	DurationMS     int       `json:"duration_ms"`
	AttemptedAt    time.Time `json:"attempted_at"`
}

// Open dials Postgres and waits for it to answer. Both binaries start at the
// same time as the database under docker compose, so the retry loop is not
// optional; on Fargate it covers an RDS failover just as well.
func Open(ctx context.Context, url string, maxConns int32) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}

	// pgxpool defaults to max(4, NumCPU), which on a 2-vCPU Fargate task is four
	// connections against eight delivery goroutines. Acquisition then blocks, and
	// that wait is charged to the message's visibility timeout. Worse, the
	// detached 5s context in RecordAttempt can expire while queueing, losing the
	// record of a delivery that actually happened and causing a duplicate POST on
	// the next receive.
	if maxConns > 0 {
		cfg.MaxConns = maxConns
	}

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("open pool: %w", err)
	}

	deadline := time.Now().Add(60 * time.Second)
	for {
		if err = pool.Ping(ctx); err == nil {
			return &Store{pool: pool}, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			pool.Close()
			return nil, fmt.Errorf("database unreachable: %w", err)
		}
		select {
		case <-ctx.Done():
			pool.Close()
			return nil, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

func (s *Store) Close() { s.pool.Close() }

// Migrate applies every embedded .sql file in name order. Statements are
// idempotent, so concurrent tasks racing here is safe.
func (s *Store) Migrate(ctx context.Context) error {
	names, err := fs.Glob(migrations.FS, "*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, name := range names {
		body, err := migrations.FS.ReadFile(name)
		if err != nil {
			return err
		}
		if _, err := s.pool.Exec(ctx, string(body)); err != nil {
			return fmt.Errorf("migration %s: %w", name, err)
		}
	}
	return nil
}

// CreateSubscription registers a subscription, returning whether it was newly
// created. A false means the caller re-registered an existing one.
func (s *Store) CreateSubscription(ctx context.Context, url, eventType string) (Subscription, bool, error) {
	var created bool
	sub := Subscription{
		ID:        uuid.NewString(),
		URL:       url,
		EventType: eventType,
		Secret:    newSecret(),
		Active:    true,
	}
	// Idempotent on (url, event_type): a repeated registration reactivates the
	// existing subscription rather than creating a second one that would double
	// every delivery. DO UPDATE rather than DO NOTHING, because DO NOTHING
	// returns no row to RETURNING.
	//
	// xmax is zero only on a freshly inserted row, so it distinguishes a create
	// from a conflict without a second query. The caller needs that distinction
	// because the secret must never be returned on the conflict path: anyone who
	// can guess a subscriber's URL would otherwise be handed its signing key and
	// could forge deliveries straight to that subscriber.
	err := s.pool.QueryRow(ctx,
		`INSERT INTO subscriptions (id, url, event_type, secret)
		 VALUES ($1::uuid, $2, $3, $4)
		 ON CONFLICT (url, event_type) DO UPDATE SET active = true
		 RETURNING id::text, secret, created_at, (xmax = 0) AS created`,
		sub.ID, sub.URL, sub.EventType, sub.Secret,
	).Scan(&sub.ID, &sub.Secret, &sub.CreatedAt, &created)
	return sub, created, err
}

func (s *Store) CreateEvent(ctx context.Context, eventType string, payload json.RawMessage) (Event, error) {
	ev := Event{ID: uuid.NewString(), Type: eventType, Payload: payload}
	err := s.pool.QueryRow(ctx,
		`INSERT INTO events (id, type, payload)
		 VALUES ($1::uuid, $2, $3) RETURNING created_at`,
		ev.ID, ev.Type, []byte(payload),
	).Scan(&ev.CreatedAt)
	return ev, err
}

func (s *Store) Event(ctx context.Context, id string) (Event, error) {
	var ev Event
	err := s.pool.QueryRow(ctx,
		`SELECT id::text, type, payload, created_at FROM events WHERE id = $1::uuid`, id,
	).Scan(&ev.ID, &ev.Type, &ev.Payload, &ev.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ev, ErrNotFound
	}
	return ev, err
}

// SubscriptionsFor returns the live subscribers for an event type. The worker
// calls this, not the api: a subscriber added after an event was accepted but
// before it was delivered should still receive it.
func (s *Store) SubscriptionsFor(ctx context.Context, eventType string) ([]Subscription, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id::text, url, event_type, secret, active, created_at
		 FROM subscriptions WHERE event_type = $1 AND active ORDER BY created_at`, eventType)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Subscription
	for rows.Next() {
		var sub Subscription
		if err := rows.Scan(&sub.ID, &sub.URL, &sub.EventType, &sub.Secret, &sub.Active, &sub.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, sub)
	}
	return out, rows.Err()
}

// Delivered reports which subscriptions have already returned 2xx for this
// event. SQS redelivers the whole message, so without this a retry caused by
// subscriber B would re-POST to subscriber A. At-least-once is the contract;
// duplicates we can cheaply avoid, we avoid.
func (s *Store) Delivered(ctx context.Context, eventID string) (map[string]bool, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT DISTINCT subscription_id::text FROM delivery_attempts
		 WHERE event_id = $1::uuid AND status_code BETWEEN 200 AND 299`, eventID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	done := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		done[id] = true
	}
	return done, rows.Err()
}

func (s *Store) RecordAttempt(ctx context.Context, eventID string, a Attempt) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO delivery_attempts
		   (event_id, subscription_id, attempt_no, status_code, error, duration_ms)
		 VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6)`,
		eventID, a.SubscriptionID, a.AttemptNo, a.StatusCode, a.Error, a.DurationMS)
	return err
}

func (s *Store) Attempts(ctx context.Context, eventID string) ([]Attempt, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT subscription_id::text, attempt_no, status_code, error, duration_ms, attempted_at
		 FROM delivery_attempts WHERE event_id = $1::uuid ORDER BY attempted_at`, eventID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	attempts := []Attempt{}
	for rows.Next() {
		var a Attempt
		if err := rows.Scan(&a.SubscriptionID, &a.AttemptNo, &a.StatusCode, &a.Error, &a.DurationMS, &a.AttemptedAt); err != nil {
			return nil, err
		}
		attempts = append(attempts, a)
	}
	return attempts, rows.Err()
}

// Ping backs GET /healthz. The ALB health check failing when the database is
// unreachable is deliberate: an api task that cannot persist cannot honour a 202.
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func newSecret() string {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand failing is not a recoverable condition
	}
	return "whsec_" + hex.EncodeToString(b)
}
