// Package api accepts events: persist, enqueue, return 202. It makes no
// outbound deliveries.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"time"

	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/queue"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/store"
)

type Server struct {
	store *store.Store
	queue *queue.Queue
	log   *slog.Logger

	// allowInsecure permits http:// subscriber URLs. False in AWS, where worker
	// egress opens :443 only; the compose sink speaks http and sets it true.
	allowInsecure bool
}

func New(st *store.Store, q *queue.Queue, log *slog.Logger, allowInsecure bool) *Server {
	return &Server{store: st, queue: q, log: log, allowInsecure: allowInsecure}
}

// Routes uses the stdlib method-and-wildcard patterns from Go 1.22.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("POST /events", s.createEvent)
	mux.HandleFunc("POST /subscriptions", s.createSubscription)
	mux.HandleFunc("GET /events/{id}", s.getEvent)
	return s.logRequests(mux)
}

type createEventRequest struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

func (s *Server) createEvent(w http.ResponseWriter, r *http.Request) {
	var req createEventRequest
	if err := decode(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.Type == "" {
		writeError(w, http.StatusBadRequest, "type is required")
		return
	}
	if len(req.Payload) == 0 {
		req.Payload = json.RawMessage(`{}`)
	}

	ev, err := s.store.CreateEvent(r.Context(), req.Type, req.Payload)
	if err != nil {
		s.log.Error("persist event", "err", err)
		writeError(w, http.StatusInternalServerError, "could not persist event")
		return
	}

	// Enqueued after the row exists; an orphaned row is recoverable, an
	// unresolvable message is not.
	if err := s.queue.Send(r.Context(), queue.Delivery{EventID: ev.ID, EventType: ev.Type}); err != nil {
		s.log.Error("enqueue event", "event_id", ev.ID, "err", err)
		writeError(w, http.StatusInternalServerError, "could not enqueue event")
		return
	}

	// 202, not 201: the event is durable and delivery has not happened yet.
	writeJSON(w, http.StatusAccepted, map[string]string{"event_id": ev.ID})
}

type createSubscriptionRequest struct {
	URL       string `json:"url"`
	EventType string `json:"event_type"`
}

func (s *Server) createSubscription(w http.ResponseWriter, r *http.Request) {
	var req createSubscriptionRequest
	if err := decode(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if req.EventType == "" {
		writeError(w, http.StatusBadRequest, "event_type is required")
		return
	}
	u, err := url.Parse(req.URL)
	if err != nil || u.Host == "" || (u.Scheme != "https" && !(u.Scheme == "http" && s.allowInsecure)) {
		writeError(w, http.StatusBadRequest, "url must be an absolute https URL")
		return
	}

	sub, created, err := s.store.CreateSubscription(r.Context(), req.URL, req.EventType)
	if err != nil {
		s.log.Error("create subscription", "err", err)
		writeError(w, http.StatusInternalServerError, "could not create subscription")
		return
	}

	// The secret is returned only on the call that creates the subscription. This
	// endpoint is unauthenticated, so returning it on re-registration would hand
	// a subscriber's signing key to anyone who can guess its URL.
	if !created {
		sub.Secret = ""
		writeJSON(w, http.StatusOK, sub)
		return
	}
	writeJSON(w, http.StatusCreated, sub)
}

func (s *Server) getEvent(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ev, err := s.store.Event(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "no such event")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read event")
		return
	}
	attempts, err := s.store.Attempts(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read attempts")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"event": ev, "delivery_attempts": attempts})
}

// health is the ALB target check and touches the database, because a task that
// cannot persist cannot honour a 202.
func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unreachable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r) // polled by the ALB every 15s
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.log.Info("request",
			"method", r.Method, "path", r.URL.Path,
			"status", rec.status, "duration_ms", time.Since(start).Milliseconds())
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func decode(r *http.Request, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return errors.New("invalid JSON body")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
