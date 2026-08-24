package relay

import (
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
