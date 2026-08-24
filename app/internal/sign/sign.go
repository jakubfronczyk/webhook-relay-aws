// Package sign implements the signature a subscriber uses to prove a delivery
// came from us.
//
// The scheme is the one Stripe and GitHub use: HMAC-SHA256 over
// "<timestamp>.<body>" with a per-subscription secret. The timestamp is inside
// the signed string, not just alongside it, so a captured delivery cannot be
// replayed later with a fresh timestamp header.
package sign

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"time"
)

const (
	HeaderSignature = "X-Webhook-Signature"
	HeaderTimestamp = "X-Webhook-Timestamp"
	HeaderEventID   = "X-Webhook-Event-Id"
	HeaderAttempt   = "X-Webhook-Attempt"
)

// Payload builds the exact bytes that get signed.
func Payload(ts time.Time, body []byte) []byte {
	p := make([]byte, 0, len(body)+24)
	p = strconv.AppendInt(p, ts.Unix(), 10)
	p = append(p, '.')
	return append(p, body...)
}

// Compute returns the value for the X-Webhook-Signature header.
func Compute(secret string, ts time.Time, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(Payload(ts, body))
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

// Verify is the receiver's half. It lives here so the compose sink can import
// the same code the sender uses, which is the only way the local demo proves
// the signature is actually correct rather than merely present.
func Verify(secret, signature string, ts time.Time, body []byte, tolerance time.Duration) error {
	want := Compute(secret, ts, body)
	// Constant-time: a byte-by-byte compare leaks the correct prefix length.
	if !hmac.Equal([]byte(signature), []byte(want)) {
		return fmt.Errorf("signature mismatch")
	}
	if skew := time.Since(ts); skew > tolerance || skew < -tolerance {
		return fmt.Errorf("timestamp outside %s tolerance", tolerance)
	}
	return nil
}
