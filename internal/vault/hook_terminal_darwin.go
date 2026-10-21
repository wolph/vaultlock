//go:build darwin

package vault

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
)

// runTerminalHook confines /dev/tty traffic to the managed diagnostic stream.
func runTerminalHook(ctx context.Context, command *exec.Cmd, input io.Reader) (handled bool, result error) {
	var terminal *os.File
	var ok bool
	terminal, ok = input.(*os.File)
	if !ok {
		return false, nil
	}
	var original *unix.Termios
	var err error
	original, err = unix.IoctlGetTermios(int(terminal.Fd()), unix.TIOCGETA)
	if err != nil {
		return false, nil
	}
	var master, slave *os.File
	master, slave, err = pty.Open()
	if err != nil {
		return true, err
	}
	defer master.Close()
	defer slave.Close()
	var hostFD int = int(terminal.Fd())
	var masterFD int = int(master.Fd())
	if err = unix.SetNonblock(masterFD, true); err != nil {
		return true, err
	}
	var forwarding unix.Termios = terminalHookInputMode(*original)
	if err = unix.IoctlSetTermios(hostFD, unix.TIOCSETA, &forwarding); err != nil {
		return true, err
	}
	defer func() { result = errors.Join(result, unix.IoctlSetTermios(hostFD, unix.TIOCSETA, original)) }()
	serialiseTerminalHookOutput(command)
	var pump terminalHookPump = terminalHookPump{terminal: terminal, master: master, hostFD: hostFD, masterFD: masterFD, diagnostic: command.Stderr}
	pump.resize()
	configureTerminalHook(command, slave)
	if err = command.Start(); err != nil {
		return true, err
	}
	slave.Close()
	var forwardingContext context.Context
	var stopForwarding context.CancelFunc
	forwardingContext, stopForwarding = context.WithCancel(ctx)
	defer stopForwarding()
	var pumped chan error = make(chan error, 1)
	go func() {
		var failure error = pump.run(forwardingContext)
		if failure != nil || ctx.Err() != nil {
			killTerminalHook(command)
		}
		pumped <- failure
	}()
	var waitError error = command.Wait()
	stopForwarding()
	return true, errors.Join(waitError, <-pumped, ctx.Err())
}

func terminalHookInputMode(original unix.Termios) unix.Termios {
	var forwarding unix.Termios = original
	forwarding.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	forwarding.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	forwarding.Cflag &^= unix.CSIZE | unix.PARENB
	forwarding.Cflag |= unix.CS8
	forwarding.Cc[unix.VMIN] = 1
	forwarding.Cc[unix.VTIME] = 0
	// Preserve output processing for the progress display sharing this terminal.
	return forwarding
}

func configureTerminalHook(command *exec.Cmd, slave *os.File) {
	var attributes syscall.SysProcAttr
	if command.SysProcAttr != nil {
		attributes = *command.SysProcAttr
	}
	attributes.Setsid = true
	attributes.Setctty = true
	attributes.Ctty = 0
	command.SysProcAttr = &attributes
	command.Stdin = slave
	command.WaitDelay = 300 * time.Millisecond
	if command.Cancel != nil {
		command.Cancel = func() error { return killTerminalHook(command) }
	}
}

func killTerminalHook(command *exec.Cmd) error {
	if command.Process == nil {
		return nil
	}
	var err error = unix.Kill(-command.Process.Pid, unix.SIGKILL)
	if errors.Is(err, unix.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}

type terminalHookPump struct {
	terminal   *os.File
	master     *os.File
	hostFD     int
	masterFD   int
	diagnostic io.Writer
	pending    []byte
	lastSize   pty.Winsize
	nextResize time.Time
}

type terminalHookWriter struct {
	mutex  *sync.Mutex
	writer io.Writer
}

func (w terminalHookWriter) Write(data []byte) (int, error) {
	w.mutex.Lock()
	defer w.mutex.Unlock()
	return w.writer.Write(data)
}

func serialiseTerminalHookOutput(command *exec.Cmd) {
	var mutex *sync.Mutex = &sync.Mutex{}
	if command.Stdout != nil {
		command.Stdout = terminalHookWriter{mutex: mutex, writer: command.Stdout}
	}
	if command.Stderr != nil {
		command.Stderr = terminalHookWriter{mutex: mutex, writer: command.Stderr}
	}
}

func (p *terminalHookPump) run(ctx context.Context) error {
	for {
		if ctx.Err() != nil {
			return p.drain()
		}
		if time.Now().After(p.nextResize) {
			p.resize()
		}
		var descriptors []unix.PollFd = []unix.PollFd{{Fd: int32(p.hostFD)}, {Fd: int32(p.masterFD), Events: unix.POLLIN}}
		if len(p.pending) == 0 {
			descriptors[0].Events = unix.POLLIN
		} else {
			descriptors[1].Events |= unix.POLLOUT
		}
		var err error
		if _, err = unix.Poll(descriptors, 50); err != nil {
			if errors.Is(err, unix.EINTR) {
				continue
			}
			return err
		}
		if descriptors[0].Revents&unix.POLLNVAL != 0 {
			return unix.EBADF
		}
		if descriptors[0].Revents&(unix.POLLHUP|unix.POLLERR) != 0 {
			return io.EOF
		}
		if descriptors[1].Revents&(unix.POLLIN|unix.POLLHUP|unix.POLLERR) != 0 {
			if err = p.drain(); err != nil {
				return err
			}
			if descriptors[1].Revents&unix.POLLHUP != 0 {
				return nil
			}
		}
		if descriptors[0].Revents&unix.POLLIN != 0 {
			var buffer [4096]byte
			var count int
			count, err = unix.Read(p.hostFD, buffer[:])
			if err != nil && !errors.Is(err, unix.EINTR) {
				return err
			}
			if count == 0 && err == nil {
				return io.EOF
			}
			if count > 0 {
				p.pending = append(p.pending, buffer[:count]...)
			}
		}
		if descriptors[1].Revents&unix.POLLOUT != 0 {
			var count int
			count, err = unix.Write(p.masterFD, p.pending)
			if err != nil && !errors.Is(err, unix.EAGAIN) && !errors.Is(err, unix.EINTR) {
				return err
			}
			if count > 0 {
				p.pending = p.pending[count:]
			}
		}
	}
}

func (p *terminalHookPump) drain() error {
	var buffer [4096]byte
	// Bound each drain so a noisy descendant cannot prevent cancellation.
	var remaining int
	for remaining = 64; remaining > 0; remaining-- {
		var count int
		var err error
		count, err = unix.Read(p.masterFD, buffer[:])
		if count > 0 && p.diagnostic != nil {
			var written int
			var writeError error
			written, writeError = p.diagnostic.Write(buffer[:count])
			if writeError != nil {
				return writeError
			}
			if written != count {
				return io.ErrShortWrite
			}
		}
		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EIO) || count == 0 {
			return nil
		}
		if err != nil && !errors.Is(err, unix.EINTR) {
			return err
		}
	}
	return nil
}

func (p *terminalHookPump) resize() {
	p.nextResize = time.Now().Add(200 * time.Millisecond)
	var size *pty.Winsize
	var err error
	size, err = pty.GetsizeFull(p.terminal)
	if err != nil || *size == p.lastSize {
		return
	}
	if pty.Setsize(p.master, size) == nil {
		p.lastSize = *size
	}
}
