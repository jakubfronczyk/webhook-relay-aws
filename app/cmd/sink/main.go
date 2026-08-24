// Command sink is a fake subscriber. It exists so the local demo has somewhere
// to deliver to, and so "zero events lost" is a number rather than a claim: it
// counts distinct event ids received and reconciles against delivery_attempts.
//
// It is deliberately not part of the system. In AWS this role is filled by an
// HTTP API plus Lambda, outside the VPC, so the delivery path really is
// worker -> NAT -> internet -> subscriber.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/sign"
)

type sink struct {
	mu       sync.Mutex
	seen     map[string]int // event id -> times received
	requests int
	accepted int
	rejected int

	// failUntilAttempt makes the retry demo deterministic: reject every
	// delivery whose attempt number is below this, accept from then on.
	failUntilAttempt int
	// failRate is the statistical version, for the load run.
	failRate float64
	// delay simulates a slow subscriber. Without it the sink answers in under a
	// millisecond, the queue drains faster than a test can interrupt it, and the
	// kill-the-fleet-mid-drain proof has no drain to interrupt.
	delay  time.Duration
	secret string
	log    *slog.Logger
}

func main() {
	s := &sink{
		seen:             map[string]int{},
		failUntilAttempt: envInt("FAIL_UNTIL_ATTEMPT", 0),
		failRate:         envFloat("FAIL_RATE", 0),
		delay:            envDuration("RESPONSE_DELAY", 0),
		secret:           os.Getenv("SUBSCRIPTION_SECRET"),
		log:              slog.New(slog.NewJSONHandler(os.Stdout, nil)),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /hook", s.hook)
	mux.HandleFunc("GET /stats", s.stats)
	mux.HandleFunc("POST /reset", s.reset)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	addr := env("LISTEN_ADDR", ":9000")
	s.log.Info("sink listening", "addr", addr,
		"fail_until_attempt", s.failUntilAttempt, "fail_rate", s.failRate,
		"response_delay", s.delay.String())
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		s.log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func (s *sink) hook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "unreadable body", http.StatusBadRequest)
		return
	}

	if s.delay > 0 {
		time.Sleep(s.delay)
	}

	eventID := r.Header.Get(sign.HeaderEventID)
	attempt, _ := strconv.Atoi(r.Header.Get(sign.HeaderAttempt))

	// Verifying the signature with the same code that produced it is the only
	// way the local demo proves HMAC signing works rather than merely happens.
	if s.secret != "" {
		ts, _ := strconv.ParseInt(r.Header.Get(sign.HeaderTimestamp), 10, 64)
		if err := sign.Verify(s.secret, r.Header.Get(sign.HeaderSignature),
			time.Unix(ts, 0), body, 5*time.Minute); err != nil {
			s.log.Warn("rejected unsigned delivery", "event_id", eventID, "err", err)
			http.Error(w, "bad signature", http.StatusUnauthorized)
			return
		}
	}

	s.mu.Lock()
	s.requests++
	fail := attempt <= s.failUntilAttempt || (s.failRate > 0 && rand.Float64() < s.failRate)
	if !fail {
		s.seen[eventID]++
		s.accepted++
	} else {
		s.rejected++
	}
	s.mu.Unlock()

	if fail {
		// 500, not 4xx: a 4xx would be a permanent rejection, and this sink is
		// simulating a subscriber that is temporarily broken.
		http.Error(w, "simulated subscriber failure", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintln(w, "ok")
}

// stats is what "zero lost" is measured against.
func (s *sink) stats(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	duplicates := 0
	for _, n := range s.seen {
		if n > 1 {
			duplicates += n - 1
		}
	}
	out := map[string]int{
		"requests":       s.requests,
		"accepted":       s.accepted,
		"rejected":       s.rejected,
		"unique_events":  len(s.seen),
		"duplicate_recv": duplicates,
	}
	s.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (s *sink) reset(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.seen = map[string]int{}
	s.requests, s.accepted, s.rejected = 0, 0, 0
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if v, err := strconv.ParseFloat(os.Getenv(key), 64); err == nil {
		return v
	}
	return def
}
