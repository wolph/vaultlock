package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/wolph/vaultlock/internal/cli"
)

func main() {
	// A closed output pipe must not interrupt a recovery transaction.
	signal.Ignore(syscall.SIGPIPE)
	var ctx context.Context
	var stop context.CancelFunc
	ctx, stop = signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	var status int = cli.Run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(status)
}
