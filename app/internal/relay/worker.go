// Package relay is the delivery side: drain the queue, POST outward, retry with
// a growing interval, record every attempt.
//
// Division of labour worth being able to state out loud: SQS owns durability,
// redelivery, maxReceiveCount and the DLQ. This package owns the backoff curve
// and the HMAC.
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
}

func New(st *store.Store, q *queue.Queue, cfg config.Config, log *slog.Logger) *Worker {
	return &Worker{
		store: st,
		queue: q,
		cfg:   cfg,
		log:   log,
		client: &http.Client{
			Timeout: cfg.DeliveryTimeout,
			// Never follow redirects. For 301, 302 and 303 the Go client rewrites
			// POST to GET and drops the body, so a subscriber whose site redirects
			// http to https would answer 200 to a request carrying no payload. The
			// worker would record a successful delivery and delete the message, and
			// the event would be lost with no trace. Returning the 3xx unfollowed
			// makes it a failed attempt, which is the truth.
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
			Transport: &http.Transport{
				MaxIdleConnsPerHost: cfg.Concurrency,
				// Subscribers are arbitrary third-party hosts. Keeping
				// connections warm past a few seconds mostly holds sockets open
				// to hosts we will not talk to again.
				IdleConnTimeout: 30 * time.Second,
			},
		},
	}
}

// Run polls until the context is cancelled. Cancellation stops new receives and
// waits for in-flight deliveries; anything already received but unfinished is
// simply not deleted, so SQS redelivers it. That is the mechanism behind the
// "kill the whole fleet mid-drain and lose nothing" claim.
func (w *Worker) Run(ctx context.Context) error {
	sem := make(chan struct{}, w.cfg.Concurrency)
	var wg sync.WaitGroup
	defer wg.Wait()

	for {
		if ctx.Err() != nil {
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
		// The event row is gone, so no retry will ever resolve this message.
		// Deleting is the only terminal state that is not a DLQ entry.
		log.Warn("event missing, dropping message")
		w.ack(ctx, m, log)
		return
	}
	if err != nil {
		log.Error("load event", "err", err)
		w.retry(ctx, m, log)
		return
	}

	subs, err := w.store.SubscriptionsFor(ctx, ev.Type)
	if err != nil {
		log.Error("load subscriptions", "err", err)
		w.retry(ctx, m, log)
		return
	}
	if len(subs) == 0 {
		log.Info("no active subscriptions")
		w.ack(ctx, m, log)
		return
	}

	// Skip subscribers that already returned 2xx on an earlier receive of this
	// same message. Without this, a retry caused by subscriber B re-POSTs to
	// subscriber A and manufactures a duplicate SQS never asked for.
	delivered, err := w.store.Delivered(ctx, ev.ID)
	if err != nil {
		log.Error("load prior deliveries", "err", err)
		w.retry(ctx, m, log)
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

// deliver POSTs to one subscriber and records the attempt. It returns whether
// the subscriber accepted. Recording happens on every path, success or failure,
// because "did it get delivered?" having an answer is a product requirement.
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
		// A timeout is indistinguishable from a slow success from here. The
		// subscriber may well have processed it, which is exactly why the
		// contract is at-least-once and deliveries carry an event id.
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
	// A cancelled parent context must not lose the record of an attempt that
	// really happened, so the write gets its own short-lived context.
	writeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := w.store.RecordAttempt(writeCtx, eventID, a); err != nil {
		w.log.Error("record attempt", "event_id", eventID, "err", err)
	}
}

func (w *Worker) ack(ctx context.Context, m queue.Message, log *slog.Logger) {
	if err := w.queue.Delete(ctx, m.ReceiptHandle); err != nil {
		// Not deleting means redelivery, which the skip-already-delivered check
		// absorbs. Failing loudly here would be worse than the duplicate work.
		log.Error("delete message", "err", err)
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

// Backoff is the retry curve. It doubles per receive off a configurable base,
// so with the 30s default the intervals are 30s, 1m, 2m, 4m up to the ceiling.
//
// Deliberately un-jittered: the demo has to show measurable, predictable
// intervals. A real fleet delivering to one flapping subscriber would add full
// jitter here to avoid every retry landing in the same second.
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
