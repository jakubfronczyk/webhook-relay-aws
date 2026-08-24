package sign

import (
	"testing"
	"time"
)

func TestVerifyRoundTrip(t *testing.T) {
	const secret = "whsec_test"
	body := []byte(`{"event_id":"abc","type":"invoice.paid"}`)
	ts := time.Now()

	if err := Verify(secret, Compute(secret, ts, body), ts, body, time.Minute); err != nil {
		t.Fatalf("valid signature rejected: %v", err)
	}
}

func TestVerifyRejects(t *testing.T) {
	const secret = "whsec_test"
	body := []byte(`{"amount":100}`)
	ts := time.Now()
	sig := Compute(secret, ts, body)

	t.Run("tampered body", func(t *testing.T) {
		if err := Verify(secret, sig, ts, []byte(`{"amount":999}`), time.Minute); err == nil {
			t.Fatal("tampered body accepted")
		}
	})

	t.Run("wrong secret", func(t *testing.T) {
		if err := Verify("whsec_other", sig, ts, body, time.Minute); err == nil {
			t.Fatal("wrong secret accepted")
		}
	})

	// The timestamp is inside the signed string, so a replay cannot be dressed
	// up with a fresh header: changing the timestamp invalidates the signature,
	// and keeping the old one trips the tolerance check.
	t.Run("replayed outside tolerance", func(t *testing.T) {
		old := time.Now().Add(-10 * time.Minute)
		if err := Verify(secret, Compute(secret, old, body), old, body, time.Minute); err == nil {
			t.Fatal("stale delivery accepted")
		}
	})
}
