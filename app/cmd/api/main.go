// Command api accepts events and enqueues them. It is the only binary with an
// inbound network path.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/api"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/config"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/queue"
	"github.com/jakubfronczyk/webhook-relay-aws/app/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	// ECS sends SIGTERM before killing a task.
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

	st, err := store.Open(ctx, cfg.DatabaseURL, 10)
	if err != nil {
		return err
	}
	defer st.Close()

	// The api owns the schema; the worker does not migrate.
	if err := st.Migrate(ctx); err != nil {
		return err
	}

	q, err := queue.Open(ctx, cfg.AWSRegion, cfg.AWSEndpoint, cfg.QueueURL)
	if err != nil {
		return err
	}

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           api.New(st, q, log, cfg.AllowInsecureSubscribers).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	errc := make(chan error, 1)
	go func() {
		log.Info("api listening", "addr", cfg.ListenAddr)
		errc <- srv.ListenAndServe()
	}()

	select {
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		log.Info("shutting down")
		// Matched to the ALB deregistration delay of 30s.
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	}
}
