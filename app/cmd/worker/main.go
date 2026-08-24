// Command worker drains the queue and delivers. It listens on nothing, which is
// what makes worker-sg able to have zero ingress rules.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/config"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/queue"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/relay"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := run(ctx, log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	// One connection per delivery goroutine, plus headroom for the detached
	// attempt writes.
	st, err := store.Open(ctx, cfg.DatabaseURL, int32(cfg.Concurrency)+4)
	if err != nil {
		return err
	}
	defer st.Close()

	q, err := queue.Open(ctx, cfg.AWSRegion, cfg.AWSEndpoint, cfg.QueueURL)
	if err != nil {
		return err
	}

	log.Info("worker polling",
		"queue", cfg.QueueURL,
		"concurrency", cfg.Concurrency,
		"backoff_base", cfg.BackoffBase.String())

	return relay.New(st, q, cfg, log).Run(ctx)
}
