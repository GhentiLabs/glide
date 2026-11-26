package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/GhentiLabs/glide/services/api/internal/app"
	"github.com/GhentiLabs/glide/services/api/internal/config"
	"github.com/GhentiLabs/glide/services/api/internal/repository"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	cfg, err := config.Load()
	must("load configuration", err)

	repo, err := repository.New(ctx, cfg.DatabaseURL, cfg.DatabaseCredentialsFile)
	must("configure Postgres", err)
	defer repo.Close()
	if len(os.Args) > 1 && os.Args[1] == "migrate" {
		must("apply migrations", repo.Migrate(ctx))
		log.Print("migrations applied")
		return
	}
	if cfg.S3Endpoint == "" || cfg.S3Bucket == "" || cfg.S3CredentialsFile == "" {
		log.Fatal("S3_ENDPOINT, S3_BUCKET and S3_CREDENTIALS_FILE are required")
	}

	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.Port),
		Handler:           app.New(cfg, repo),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       65 * time.Second,
	}
	go func() {
		log.Printf("Glide API listening on %s", server.Addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdown); err != nil {
		log.Printf("graceful shutdown: %v", err)
	}
}

func must(operation string, err error) {
	if err != nil {
		log.Fatalf("%s: %v", operation, err)
	}
}
