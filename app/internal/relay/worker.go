// Package relay drains the queue and delivers. SQS owns durability, redelivery,
// maxReceiveCount and the DLQ; this package owns the backoff curve and the HMAC.
package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/config"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/queue"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/sign"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/store"
)

type Worker struct {
	store  *store.Store
	queue  *queue.Queue
	cfg    config.Config
	log    *slog.Logger
	client *http.Client

	// storeDown stops the poll loop, since every receive during an outage
	// consumes one of maxReceiveCount without contacting any subscriber.
	storeDown atomic.Bool
}

func New(st *store.Store, q *queue.Queue, cfg config.Config, log *slog.Logger) *Worker {
	return &Worker{
		store: st,
		queue: q,
		cfg:   cfg,
		log:   log,
		client: &http.Client{
			Timeout: cfg.DeliveryTimeout,
			// For 301, 302 and 303 the Go client rewrites POST to GET and drops the
			// body, so a followed redirect would record a success that delivered nothing.
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
			Transport: &http.Transport{
				DialContext:         newDialer(cfg.AllowPrivateSubscribers).DialContext,
				MaxIdleConnsPerHost: cfg.Concurrency,
				// Subscribers are arbitrary hosts, mostly not contacted twice in a row.
				IdleConnTimeout: 30 * time.Second,
			},
		},
	}
}

// Run polls until the context is cancelled, then waits for in-flight deliveries.
// Anything received but unfinished is left undeleted and SQS redelivers it.
func (w *Worker) Run(ctx context.Context) error {
	sem := make(chan struct{}, w.cfg.Concurrency)
	var wg sync.WaitGroup
	defer wg.Wait()

	for {
		if ctx.Err() != nil {
			return nil
		}
		if w.storeDown.Load() && !w.waitForStore(ctx) {
			return nil
		}

		msgs, err := w.queue.Receive(ctx, w.cfg.BatchSize, w.cfg.PollWaitTime)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			w.log.Error("receive", "err", err)
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(time.Second):
			}
			continue
		}

		for _, msg := range msgs {
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return nil
			}
			wg.Add(1)
			go func(m queue.Message) {
				defer wg.Done()
				defer func() { <-sem }()
				w.handle(ctx, m)
			}(msg)
		}
	}
}

func (w *Worker) handle(ctx context.Context, m queue.Message) {
	log := w.log.With("event_id", m.EventID, "receive_count", m.ReceiveCount)

	ev, err := w.store.Event(ctx, m.EventID)
	if errors.Is(err, store.ErrNotFound) {
		// No retry resolves a missing event row.
		log.Warn("event missing, dropping message")
		w.ack(ctx, m, log)
		return
	}
	if err != nil {
		w.storeFailed(ctx, "load event", err, log)
		return
	}

	subs, err := w.store.SubscriptionsFor(ctx, ev.Type)
	if err != nil {
		w.storeFailed(ctx, "load subscriptions", err, log)
		return
	}
	if len(subs) == 0 {
		log.Info("no active subscriptions")
		w.ack(ctx, m, log)
		return
	}

	// SQS redelivers the whole message, so without this a retry caused by one
	// subscriber re-POSTs to every subscriber that already succeeded.
	delivered, err := w.store.Delivered(ctx, ev.ID)
	if err != nil {
		w.storeFailed(ctx, "load prior deliveries", err, log)
		return
	}

	body, err := json.Marshal(map[string]any{
		"event_id":   ev.ID,
		"type":       ev.Type,
		"payload":    ev.Payload,
		"created_at": ev.CreatedAt,
	})
	if err != nil {
		log.Error("marshal delivery body", "err", err)
		w.ack(ctx, m, log)
		return
	}

	failed := 0
	for _, sub := range subs {
		if delivered[sub.ID] {
			continue
		}
		if !w.deliver(ctx, ev, sub, body, m.ReceiveCount, log) {
			failed++
		}
	}

	if failed > 0 {
		w.retry(ctx, m, log)
		return
	}
	w.ack(ctx, m, log)
}

// deliver POSTs to one subscriber and records the attempt on every path,
// returning whether the subscriber accepted.
func (w *Worker) deliver(ctx context.Context, ev store.Event, sub store.Subscription, body []byte, attemptNo int, log *slog.Logger) bool {
	ts := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.URL, bytes.NewReader(body))
	if err != nil {
		w.record(ctx, ev.ID, sub.ID, attemptNo, nil, err, 0)
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "webhook-relay/1")
	req.Header.Set(sign.HeaderEventID, ev.ID)
	req.Header.Set(sign.HeaderAttempt, fmt.Sprint(attemptNo))
	req.Header.Set(sign.HeaderTimestamp, fmt.Sprint(ts.Unix()))
	req.Header.Set(sign.HeaderSignature, sign.Compute(sub.Secret, ts, body))

	start := time.Now()
	resp, err := w.client.Do(req)
	elapsed := time.Since(start)

	if err != nil {
		// A timeout is indistinguishable from a slow success, so it is retried.
		w.record(ctx, ev.ID, sub.ID, attemptNo, nil, err, elapsed)
		log.Warn("delivery failed", "subscription_id", sub.ID, "err", err)
		return false
	}
	// Drain and close so the connection can be reused.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
	_ = resp.Body.Close()

	ok := resp.StatusCode >= 200 && resp.StatusCode < 300
	var attemptErr error
	if !ok {
		attemptErr = fmt.Errorf("subscriber returned %d", resp.StatusCode)
	}
	w.record(ctx, ev.ID, sub.ID, attemptNo, &resp.StatusCode, attemptErr, elapsed)
	log.Info("delivery", "subscription_id", sub.ID, "status", resp.StatusCode, "duration_ms", elapsed.Milliseconds())
	return ok
}

func (w *Worker) record(ctx context.Context, eventID, subID string, attemptNo int, status *int, attemptErr error, took time.Duration) {
	a := store.Attempt{
		SubscriptionID: subID,
		AttemptNo:      attemptNo,
		StatusCode:     status,
		DurationMS:     int(took.Milliseconds()),
	}
	if attemptErr != nil {
		msg := attemptErr.Error()
		a.Error = &msg
	}
	// Detached, so a cancelled parent cannot lose the record of an attempt that happened.
	writeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := w.store.RecordAttempt(writeCtx, eventID, a); err != nil {
		w.log.Error("record attempt", "event_id", eventID, "err", err)
	}
}

func (w *Worker) ack(ctx context.Context, m queue.Message, log *slog.Logger) {
	if err := w.queue.Delete(ctx, m.ReceiptHandle); err != nil {
		// A failed delete causes redelivery, which the already-delivered check absorbs.
		log.Error("delete message", "err", err)
	}
}

// storeFailed leaves the message to reappear after its visibility timeout and
// pauses polling, so an outage costs each in-flight message one receive in total.
func (w *Worker) storeFailed(ctx context.Context, what string, err error, log *slog.Logger) {
	if ctx.Err() != nil {
		return
	}
	log.Error(what, "err", err)
	if !w.storeDown.Swap(true) {
		w.log.Warn("store unreachable, pausing the poll loop")
	}
}

// waitForStore pings until Postgres answers, returning false if the context ends first.
func (w *Worker) waitForStore(ctx context.Context) bool {
	for wait := time.Second; ; wait = min(wait*2, 30*time.Second) {
		pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err := w.store.Ping(pingCtx)
		cancel()
		if err == nil {
			w.storeDown.Store(false)
			w.log.Info("store reachable, resuming the poll loop")
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(wait):
		}
	}
}

func (w *Worker) retry(ctx context.Context, m queue.Message, log *slog.Logger) {
	after := Backoff(m.ReceiveCount, w.cfg.BackoffBase, w.cfg.BackoffMax)
	if err := w.queue.Retry(ctx, m.ReceiptHandle, after); err != nil {
		log.Error("change visibility", "err", err)
		return
	}
	log.Info("retry scheduled", "in", after.String())
}

// Backoff doubles per receive off base, capped at max, so the 30s default gives
// 30s, 1m, 2m, 4m. Un-jittered, so the intervals are measurable in the demo.
func Backoff(receiveCount int, base, max time.Duration) time.Duration {
	if receiveCount < 1 {
		receiveCount = 1
	}
	d := base
	for i := 1; i < receiveCount && d < max; i++ {
		d *= 2
	}
	if d > max {
		d = max
	}
	return d
}
