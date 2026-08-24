// Package config reads process configuration from the environment.
//
// One rule: every value the api and worker need has a default that works under
// docker compose, and the AWS task definitions override the ones that differ.
// A missing DATABASE_URL is fatal; nothing else is.
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
	// AllowInsecureSubscribers permits http:// subscriber URLs. Compose sets it;
	// AWS does not, because worker egress is :443 only.
	AllowInsecureSubscribers bool

	// worker
	Concurrency     int
	BackoffBase     time.Duration // first retry delay; doubles per receive
	BackoffMax      time.Duration // ceiling, and must stay under the queue's own max
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
		// Must not exceed WORKER_CONCURRENCY. A message received beyond the
		// concurrency limit sits in the local slice waiting for a semaphore slot
		// while its visibility timeout is already running.
		BatchSize: int32(envInt("POLL_BATCH_SIZE", 8)),
	}
	// On Fargate there is no DATABASE_URL to hand over. RDS owns the master
	// password and stores it as a JSON document in Secrets Manager, and the ECS
	// task definition injects one key of it as DB_PASSWORD. The remaining parts
	// are plain Terraform outputs, so the DSN is assembled here rather than
	// interpolated into the task definition, which would put the password in the
	// ECS console and in CloudWatch on every task start.
	if c.DatabaseURL == "" {
		c.DatabaseURL = databaseURLFromParts()
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL, or DB_HOST with DB_PASSWORD, is required")
	}
	return c, nil
}

// databaseURLFromParts builds a DSN from discrete variables, returning "" when
// the required ones are absent. url.UserPassword handles escaping, which matters
// because an RDS-generated password contains punctuation that is not URL-safe.
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
	// RDS presents a certificate signed by the Amazon RDS CA. require verifies
	// the connection is encrypted without verifying that chain; verify-full needs
	// the CA bundle in the image and is the production setting.
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
