//go:build !darwin

package vault

import (
	"context"
	"io"
	"os/exec"
)

func runTerminalHook(ctx context.Context, command *exec.Cmd, input io.Reader) (bool, error) {
	return false, nil
}
