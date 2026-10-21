package vault

import (
	"context"
	"errors"
	"io"
	"os"
	"time"

	"github.com/wolph/vaultlock/internal/progress"
)

func (a *App) startProgress(command string) func(error) error {
	a.storageChangesStarted = false
	var originalOut io.Writer = a.Out
	var originalErr io.Writer = a.Err
	var terminal bool
	if file, ok := originalErr.(*os.File); ok {
		terminal = adoptTerminal(file.Fd()) && os.Getenv("TERM") != "dumb"
	}
	a.outputTerminal = false
	a.errorTerminal = writerTerminal(originalErr)
	if file, ok := originalOut.(*os.File); ok {
		a.outputTerminal = adoptTerminal(file.Fd())
	}
	var interval time.Duration = a.progressInterval
	if interval <= 0 {
		interval = 500 * time.Millisecond
		if terminal {
			interval = 200 * time.Millisecond
		}
	}
	a.display = progress.New(originalErr, progress.Options{Mode: a.Options.Progress, Color: a.Options.Color, Interval: interval, Terminal: terminal})
	a.Out = a.display.Wrap(originalOut)
	a.Err = a.display.Wrap(originalErr)
	var activity *progress.Task = a.beginProgress("Prepare vault "+command, 0, 0)
	return func(result error) error {
		if result == nil && a.display.Err() == nil {
			activity.Complete()
		} else {
			activity.Close()
		}
		a.display.Close()
		var outputErr error = a.display.Err()
		a.display = nil
		a.Out = originalOut
		a.Err = originalErr
		a.outputTerminal = false
		a.errorTerminal = false
		a.sealing = false
		a.storageChangesStarted = false
		if outputErr != nil {
			return errors.Join(result, errors.New("progress or command output failed"))
		}
		return result
	}
}
func (a *App) beginProgress(label string, totalBytes, totalEntries int64) *progress.Task {
	if a.display == nil {
		return nil
	}
	return a.display.Begin(label, totalBytes, totalEntries)
}
func (a *App) wait(label string) func() {
	var task *progress.Task = a.beginProgress(label, 0, 0)
	return task.Close
}
func (a *App) checkProgress() error {
	if a.storageChangesStarted || a.sealing || a.display == nil || a.display.Err() == nil {
		return nil
	}
	return errors.New("progress or command output failed before storage changes")
}
func (a *App) encryptRecovery(ctx context.Context, plaintext []byte, round uint64) ([]byte, error) {
	var task *progress.Task = a.beginProgress("Encrypt recovery material for the future drand round", 0, 0)
	defer task.Close()
	if err := a.checkProgress(); err != nil {
		return nil, err
	}
	var ciphertext []byte
	var err error
	ciphertext, err = a.Crypto.Encrypt(ctx, plaintext, round)
	if err == nil {
		task.Complete()
	}
	return ciphertext, err
}
func (a *App) decryptRecovery(ctx context.Context, ciphertext []byte) ([]byte, error) {
	var task *progress.Task = a.beginProgress("Wait for drand and decrypt recovery material", 0, 0)
	defer task.Close()
	if err := a.checkProgress(); err != nil {
		return nil, err
	}
	var plaintext []byte
	var err error
	plaintext, err = a.Crypto.Decrypt(ctx, ciphertext)
	if err == nil {
		task.Complete()
	}
	return plaintext, err
}
func (a *App) verifyFutureRecovery(ctx context.Context, ciphertext []byte, round uint64) error {
	var task *progress.Task = a.beginProgress("Verify future time-lock ciphertext against drand", 0, 0)
	defer task.Close()
	if err := a.checkProgress(); err != nil {
		return err
	}
	var err error = a.Crypto.VerifyFuture(ctx, ciphertext, round)
	if err == nil {
		task.Complete()
	}
	return err
}

func (a *App) generatePassphrase() ([]byte, error) {
	var task *progress.Task = a.beginProgress("Generate a cryptographically random recovery passphrase", 0, 0)
	defer task.Close()
	if err := a.checkProgress(); err != nil {
		return nil, err
	}
	var passphrase []byte
	var err error
	passphrase, err = randomPass()
	if err == nil {
		task.Complete()
	}
	return passphrase, err
}

func (a *App) beforeMutation() error {
	if a.storageChangesStarted {
		return nil
	}
	if err := a.checkProgress(); err != nil {
		return err
	}
	a.storageChangesStarted = true
	return nil
}
