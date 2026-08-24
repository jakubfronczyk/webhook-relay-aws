// Package config reads process configuration from the environment.
//
// One rule: every value the api and worker need has a default that works under
// docker compose, and the AWS task definitions override the ones that differ.
// A missing DATABASE_URL is fatal; nothing else is.
package config

import (
	"fmt"
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
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is required")
	}
	return c, nil
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
