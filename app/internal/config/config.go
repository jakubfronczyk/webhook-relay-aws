// Package config reads process configuration from the environment. Every value
// defaults to something that works under docker compose.
package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"time"
)

type Config struct {
	// Shared
	DatabaseURL string
	QueueURL    string
	AWSEndpoint string // non-empty only for ElasticMQ; empty means real SQS
	AWSRegion   string

	// api
	ListenAddr string
	// AllowInsecureSubscribers permits http:// subscriber URLs. Compose sets it; AWS does not.
	AllowInsecureSubscribers bool

	// worker
	Concurrency     int
	BackoffBase     time.Duration // first retry delay, doubling per receive
	BackoffMax      time.Duration // ceiling on that delay
	DeliveryTimeout time.Duration
	PollWaitTime    int32 // SQS long-poll seconds, 20 is the maximum
	BatchSize       int32
}

func Load() (Config, error) {
	c := Config{
		DatabaseURL:              env("DATABASE_URL", ""),
		QueueURL:                 env("QUEUE_URL", ""),
		AWSEndpoint:              env("AWS_ENDPOINT_URL_SQS", ""),
		AWSRegion:                env("AWS_REGION", "us-east-1"),
		ListenAddr:               env("LISTEN_ADDR", ":8080"),
		AllowInsecureSubscribers: env("ALLOW_INSECURE_SUBSCRIBERS", "") == "true",
		Concurrency:              envInt("WORKER_CONCURRENCY", 8),
		BackoffBase:              envDuration("BACKOFF_BASE", 30*time.Second),
		BackoffMax:               envDuration("BACKOFF_MAX", 15*time.Minute),
		DeliveryTimeout:          envDuration("DELIVERY_TIMEOUT", 5*time.Second),
		PollWaitTime:             int32(envInt("POLL_WAIT_SECONDS", 20)),
		// Must not exceed WORKER_CONCURRENCY; a message received beyond it waits
		// for a slot with its visibility timeout already running.
		BatchSize: int32(envInt("POLL_BATCH_SIZE", 8)),
	}
	// On Fargate the password arrives on its own as DB_PASSWORD, injected from
	// Secrets Manager, so the DSN is assembled here rather than in the task definition.
	if c.DatabaseURL == "" {
		c.DatabaseURL = databaseURLFromParts()
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL, or DB_HOST with DB_PASSWORD, is required")
	}
	return c, nil
}

// databaseURLFromParts builds a DSN from discrete variables, returning "" when
// DB_HOST or DB_PASSWORD is absent. RDS passwords contain characters needing escape.
func databaseURLFromParts() string {
	host, password := env("DB_HOST", ""), env("DB_PASSWORD", "")
	if host == "" || password == "" {
		return ""
	}
	u := url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(env("DB_USER", "relay"), password),
		Host:   net.JoinHostPort(host, env("DB_PORT", "5432")),
		Path:   "/" + env("DB_NAME", "relay"),
	}
	q := u.Query()
	// require encrypts without verifying the chain; verify-full needs the RDS CA
	// bundle in the image.
	q.Set("sslmode", "require")
	u.RawQuery = q.Encode()
	return u.String()
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(env(key, "")); err == nil {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(env(key, "")); err == nil {
		return v
	}
	return def
}
