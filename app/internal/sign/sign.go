// Package sign implements HMAC-SHA256 over "<timestamp>.<body>" with a
// per-subscription secret. The timestamp is inside the signed string, so a
// captured delivery cannot be replayed with a fresh timestamp header.
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

// Verify is the receiver's half, exported so the compose sink checks signatures
// with the same code that produced them.
func Verify(secret, signature string, ts time.Time, body []byte, tolerance time.Duration) error {
	want := Compute(secret, ts, body)
	// Constant-time; a byte-by-byte compare leaks the correct prefix length.
	if !hmac.Equal([]byte(signature), []byte(want)) {
		return fmt.Errorf("signature mismatch")
	}
	if skew := time.Since(ts); skew > tolerance || skew < -tolerance {
		return fmt.Errorf("timestamp outside %s tolerance", tolerance)
	}
	return nil
}
