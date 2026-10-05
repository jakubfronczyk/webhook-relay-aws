package relay

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"
)

func TestBackoff(t *testing.T) {
	base, max := 30*time.Second, 4*time.Minute
	tests := []struct {
		receiveCount int
		want         time.Duration
	}{
		{0, 30 * time.Second}, // SQS should never report this; treat as first
		{1, 30 * time.Second},
		{2, time.Minute},
		{3, 2 * time.Minute},
		{4, 4 * time.Minute},
		{5, 4 * time.Minute}, // capped
		{50, 4 * time.Minute},
	}
	for _, tt := range tests {
		if got := Backoff(tt.receiveCount, base, max); got != tt.want {
			t.Errorf("Backoff(%d) = %s, want %s", tt.receiveCount, got, tt.want)
		}
	}
}

func TestPublicAddr(t *testing.T) {
	tests := []struct {
		ip   string
		want bool
	}{
		{"93.184.216.34", true},
		{"2606:4700::1111", true},
		{"127.0.0.1", false},
		{"10.0.11.5", false},
		{"172.16.0.1", false},
		{"192.168.1.1", false},
		{"169.254.170.2", false}, // ECS task credentials endpoint
		{"169.254.169.254", false},
		{"100.64.0.1", false},
		{"0.0.0.0", false},
		{"::1", false},
		{"fd00::1", false},
		{"fe80::1", false},
		{"::ffff:10.0.0.1", false}, // IPv4-mapped, unwrapped before the check
	}
	for _, tt := range tests {
		if got := publicAddr(netip.MustParseAddr(tt.ip)); got != tt.want {
			t.Errorf("publicAddr(%s) = %v, want %v", tt.ip, got, tt.want)
		}
	}
}

// The guard runs at connect time, so it is exercised through a real request rather than
// by checking the URL string.
func TestDeliveryToPrivateAddressIsRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	for _, allow := range []bool{false, true} {
		client := &http.Client{Transport: &http.Transport{DialContext: newDialer(allow).DialContext}}
		resp, err := client.Post(srv.URL, "application/json", nil)
		if resp != nil {
			resp.Body.Close()
		}
		if blocked := errors.Is(err, ErrBlockedAddress); blocked == allow {
			t.Errorf("allowPrivate=%v: blocked=%v, err=%v", allow, blocked, err)
		}
	}
}
