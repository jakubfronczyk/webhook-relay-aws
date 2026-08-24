package config

import (
	"net/url"
	"testing"
)

// RDS generates passwords containing punctuation that is not URL-safe. Pasting one into a
// DSN unescaped produces either a parse error or, worse, a DSN that parses into the wrong
// host and fails with a confusing message.
func TestDatabaseURLFromPartsEscapesPassword(t *testing.T) {
	t.Setenv("DB_HOST", "relay.abc123.us-east-1.rds.amazonaws.com")
	t.Setenv("DB_PORT", "5432")
	t.Setenv("DB_USER", "relay")
	t.Setenv("DB_NAME", "relay")
	t.Setenv("DB_PASSWORD", "p@ss:w/rd?#[]&=+ ")

	dsn := databaseURLFromParts()
	if dsn == "" {
		t.Fatal("expected a DSN")
	}

	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatalf("assembled DSN does not parse: %v", err)
	}
	if u.Host != "relay.abc123.us-east-1.rds.amazonaws.com:5432" {
		t.Errorf("host = %q, want the RDS endpoint and port", u.Host)
	}
	pw, _ := u.User.Password()
	if pw != "p@ss:w/rd?#[]&=+ " {
		t.Errorf("password did not survive the round trip: %q", pw)
	}
	if u.Path != "/relay" {
		t.Errorf("path = %q, want /relay", u.Path)
	}
	if got := u.Query().Get("sslmode"); got != "require" {
		t.Errorf("sslmode = %q, want require", got)
	}
}

// Absent parts must produce an empty string rather than a DSN pointing at nothing, so Load
// can report a useful error instead of the pool failing to dial later.
func TestDatabaseURLFromPartsRequiresHostAndPassword(t *testing.T) {
	t.Run("no host", func(t *testing.T) {
		t.Setenv("DB_HOST", "")
		t.Setenv("DB_PASSWORD", "secret")
		if got := databaseURLFromParts(); got != "" {
			t.Errorf("got %q, want empty", got)
		}
	})

	t.Run("no password", func(t *testing.T) {
		t.Setenv("DB_HOST", "db.internal")
		t.Setenv("DB_PASSWORD", "")
		if got := databaseURLFromParts(); got != "" {
			t.Errorf("got %q, want empty", got)
		}
	})
}

// DATABASE_URL, when present, wins. It is what the compose stack sets.
func TestLoadPrefersDatabaseURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://relay:relay@postgres:5432/relay?sslmode=disable")
	t.Setenv("DB_HOST", "should-be-ignored")
	t.Setenv("DB_PASSWORD", "ignored")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.DatabaseURL != "postgres://relay:relay@postgres:5432/relay?sslmode=disable" {
		t.Errorf("DATABASE_URL was overridden: %q", cfg.DatabaseURL)
	}
}
