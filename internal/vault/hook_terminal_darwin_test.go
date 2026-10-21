//go:build darwin

package vault

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
	"github.com/wolph/vaultlock/internal/progress"
	"golang.org/x/sys/unix"
)

func TestTerminalHookLeavesNonTerminalInputUntouched(t *testing.T) {
	var command *exec.Cmd = exec.CommandContext(context.Background(), "/bin/sh", "-c", "exit 23")
	var handled bool
	var err error
	handled, err = runTerminalHook(context.Background(), command, strings.NewReader("answer\n"))
	if handled || err != nil || command.Process != nil {
		t.Fatalf("non-terminal input was handled: handled=%v err=%v process=%v", handled, err, command.Process)
	}
}

// Removing the private controlling terminal exposes /dev/tty output to the host.
func TestTerminalHookRoutesControllingTerminalAndPrompt(t *testing.T) {
	var master, terminal *os.File
	var err error
	master, terminal, err = pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	if err = pty.Setsize(terminal, &pty.Winsize{Rows: 37, Cols: 99}); err != nil {
		t.Fatal(err)
	}
	var original *unix.Termios
	original, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil {
		t.Fatal(err)
	}
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var output bytes.Buffer
	var diagnostic terminalHookBuffer
	var command *exec.Cmd = exec.CommandContext(ctx, "/bin/sh", "-c", `/bin/stty size </dev/tty; printf 'private-prompt:' >/dev/tty; IFS= read -r answer </dev/tty; while [ "$(/bin/stty size </dev/tty)" != '41 101' ]; do sleep 0.02; done; /bin/stty size </dev/tty; printf 'stdout:%s\n' "$answer"; printf 'stderr\n' >&2; printf 'private-done\n' >/dev/tty`)
	command.Stdout = &output
	command.Stderr = &diagnostic
	var finished chan error = make(chan error, 1)
	go func() {
		var handled bool
		var failure error
		handled, failure = runTerminalHook(ctx, command, terminal)
		if !handled {
			failure = errors.New("terminal input was not handled")
		}
		finished <- failure
	}()
	var deadline time.Time = time.Now().Add(2 * time.Second)
	for !strings.Contains(diagnostic.String(), "private-prompt:") && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !strings.Contains(diagnostic.String(), "private-prompt:") {
		t.Fatal("private terminal prompt did not reach diagnostics")
	}
	var forwarding *unix.Termios
	forwarding, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil {
		t.Fatal(err)
	}
	if forwarding.Lflag&(unix.ICANON|unix.ECHO|unix.ISIG) != 0 {
		t.Fatal("host terminal input is not forwarded directly")
	}
	if forwarding.Oflag != original.Oflag {
		t.Fatal("host terminal output processing changed")
	}
	if err = pty.Setsize(terminal, &pty.Winsize{Rows: 41, Cols: 101}); err != nil {
		t.Fatal(err)
	}
	if _, err = master.Write([]byte("spam and eggs\n")); err != nil {
		t.Fatal(err)
	}
	if err = <-finished; err != nil {
		t.Fatal(err)
	}
	if output.String() != "37 99\n41 101\nstdout:spam and eggs\n" {
		t.Fatalf("stdout = %q", output.String())
	}
	if !strings.Contains(diagnostic.String(), "private-done") || !strings.Contains(diagnostic.String(), "stderr") {
		t.Fatalf("diagnostics = %q", diagnostic.String())
	}
	var restored *unix.Termios
	restored, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil || *restored != *original {
		t.Fatalf("terminal settings were not restored: err=%v", err)
	}
	if err = unix.SetNonblock(int(master.Fd()), true); err != nil {
		t.Fatal(err)
	}
	var buffer [128]byte
	var count int
	count, err = unix.Read(int(master.Fd()), buffer[:])
	if count > 0 {
		t.Fatalf("hook output escaped to host terminal: %q", buffer[:count])
	}
	if err != nil && !errors.Is(err, unix.EAGAIN) {
		t.Fatal(err)
	}
}

// Leaving a descendant's pipes open must not hold cancellation hostage.
func TestTerminalHookCancellationRestoresTerminal(t *testing.T) {
	var unrelated *exec.Cmd = exec.Command("/bin/sleep", "20")
	var err error
	if err = unrelated.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		unrelated.Process.Kill()
		unrelated.Wait()
	}()
	var master, terminal *os.File
	master, terminal, err = pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	var original *unix.Termios
	original, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil {
		t.Fatal(err)
	}
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	var command *exec.Cmd = exec.CommandContext(ctx, "/bin/sh", "-c", "sleep 20 & wait")
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	var started time.Time = time.Now()
	var handled bool
	handled, err = runTerminalHook(ctx, command, terminal)
	if !handled || err == nil {
		t.Fatalf("cancelled hook: handled=%v err=%v", handled, err)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("cancellation cleanup exceeded two seconds")
	}
	if err = unrelated.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("cancellation affected unrelated process: %v", err)
	}
	var restored *unix.Termios
	restored, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil || *restored != *original {
		t.Fatalf("cancelled hook did not restore terminal: %v", err)
	}
}

func TestTerminalHookStartFailureRestoresTerminal(t *testing.T) {
	var master, terminal *os.File
	var err error
	master, terminal, err = pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	var original *unix.Termios
	original, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil {
		t.Fatal(err)
	}
	var command *exec.Cmd = exec.CommandContext(context.Background(), "/nonexistent-vaultlock-test-command")
	var handled bool
	handled, err = runTerminalHook(context.Background(), command, terminal)
	if !handled || err == nil {
		t.Fatalf("start failure: handled=%v err=%v", handled, err)
	}
	var restored *unix.Termios
	restored, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil || *restored != *original {
		t.Fatalf("start failure did not restore terminal: %v", err)
	}
}

func TestTerminalHookHostDisconnectStopsChild(t *testing.T) {
	var master, terminal *os.File
	var err error
	master, terminal, err = pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var diagnostic terminalHookBuffer
	var command *exec.Cmd = exec.CommandContext(ctx, "/bin/sh", "-c", "printf ready >/dev/tty; sleep 20")
	command.Stderr = &diagnostic
	var finished chan error = make(chan error, 1)
	go func() {
		var failure error
		_, failure = runTerminalHook(ctx, command, terminal)
		finished <- failure
	}()
	var deadline time.Time = time.Now().Add(time.Second)
	for !strings.Contains(diagnostic.String(), "ready") && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !strings.Contains(diagnostic.String(), "ready") {
		t.Fatal("hook did not start")
	}
	master.Close()
	select {
	case err = <-finished:
		if err == nil {
			t.Fatal("host disconnect succeeded unexpectedly")
		}
	case <-time.After(time.Second):
		t.Fatal("host disconnect did not stop child")
	}
}

func TestTerminalHookForwardsInterruptToChildSession(t *testing.T) {
	var master, terminal *os.File
	var err error
	master, terminal, err = pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var diagnostic terminalHookBuffer
	var command *exec.Cmd = exec.CommandContext(ctx, "/bin/sh", "-c", "trap 'printf interrupted >/dev/tty; exit 0' INT; printf ready >/dev/tty; IFS= read -r answer </dev/tty")
	command.Stderr = &diagnostic
	var finished chan error = make(chan error, 1)
	go func() {
		var failure error
		_, failure = runTerminalHook(ctx, command, terminal)
		finished <- failure
	}()
	var deadline time.Time = time.Now().Add(time.Second)
	for !strings.Contains(diagnostic.String(), "ready") && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !strings.Contains(diagnostic.String(), "ready") {
		t.Fatal("hook did not start")
	}
	if _, err = master.Write([]byte{3}); err != nil {
		t.Fatal(err)
	}
	if err = <-finished; err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diagnostic.String(), "interrupted") {
		t.Fatalf("interrupt did not reach child: %q", diagnostic.String())
	}
}

func TestTerminalHookProgressWrapSuppressesPrivateTerminalQueries(t *testing.T) {
	var master, terminal *os.File
	var err error
	master, terminal, err = pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer terminal.Close()
	var output terminalHookBuffer
	var display *progress.Display = progress.New(&output, progress.Options{Terminal: true, Color: "always", Interval: 10 * time.Millisecond})
	defer display.Close()
	var task *progress.Task = display.Begin("Wait for hook", 0, 0)
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var command *exec.Cmd = exec.CommandContext(ctx, "/bin/sh", "-c", `printf '\033]10;?\007\033]11;?\033\\\033]4;0;?\007' >/dev/tty; printf '\rloading 1%%' >/dev/tty; sleep 0.1; printf '\r\033[32mready\033[0m\n' >/dev/tty`)
	command.Stdout = display.Wrap(&output)
	command.Stderr = display.Wrap(&output)
	var handled bool
	handled, err = runTerminalHook(ctx, command, terminal)
	if !handled || err != nil {
		t.Fatalf("wrapped terminal hook: handled=%v err=%v", handled, err)
	}
	task.Complete()
	display.Close()
	var text string = output.String()
	if strings.Contains(text, "\x1b]") || strings.Contains(text, ";?") {
		t.Fatalf("terminal queries escaped: %q", text)
	}
	if !strings.Contains(text, "ready") || !strings.Contains(text, "Wait for hook") || !strings.Contains(text, "\x1b[32m") {
		t.Fatalf("hook progress, heartbeat or colour lost: %q", text)
	}
	if err = unix.SetNonblock(int(master.Fd()), true); err != nil {
		t.Fatal(err)
	}
	var buffer [256]byte
	var count int
	count, err = unix.Read(int(master.Fd()), buffer[:])
	if count > 0 {
		t.Fatalf("queries or echoes escaped to host terminal: %q", buffer[:count])
	}
	if err != nil && !errors.Is(err, unix.EAGAIN) {
		t.Fatal(err)
	}
}

type terminalHookBuffer struct {
	mutex  sync.Mutex
	buffer bytes.Buffer
}

func (b *terminalHookBuffer) Write(data []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.buffer.Write(data)
}
func (b *terminalHookBuffer) String() string {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.buffer.String()
}
