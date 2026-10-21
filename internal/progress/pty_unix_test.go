//go:build darwin || linux

package progress

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestTerminalFixtureProcess(t *testing.T) {
	if os.Getenv("VAULTLOCK_PROGRESS_FIXTURE") != "1" {
		return
	}
	var display *Display = New(os.Stderr, Options{Mode: "auto", Color: "always", Terminal: true, Interval: 10 * time.Millisecond})
	var output io.Writer = display.Wrap(os.Stdout)
	var diagnostic io.Writer = display.Wrap(os.Stderr)
	var task *Task = display.Begin("Wait for post-unlock hook", 0, 0)
	fmt.Fprintln(output, "hook started")
	for index := 0; index < 30; index++ {
		fmt.Fprintf(output, "\r\x1b[32mLoading model %d%% - %s\x1b[0m\x1b[K", index, strings.Repeat("model ", 15))
		if index == 10 {
			fmt.Fprintln(diagnostic, "warning retained")
		}
		if index == 15 {
			fmt.Fprint(diagnostic, "\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]4;0;?\x1b\\")
		}
		time.Sleep(5 * time.Millisecond)
	}
	fmt.Fprint(output, "\rmodel ready\n")
	task.Complete()
	display.Close()
}

func TestProgressInActualPTYHasBoundedRowsAndRetainsLogs(t *testing.T) {
	for _, columns := range []int{40, 80, 120} {
		t.Run(strconv.Itoa(columns), func(t *testing.T) {
			var command *exec.Cmd = exec.Command(os.Args[0], "-test.run=^TestTerminalFixtureProcess$")
			command.Env = append(os.Environ(), "VAULTLOCK_PROGRESS_FIXTURE=1", "COLUMNS="+strconv.Itoa(columns))
			var terminal *os.File
			var err error
			terminal, err = pty.StartWithSize(command, &pty.Winsize{Rows: 24, Cols: uint16(columns)})
			if err != nil {
				t.Fatal(err)
			}
			defer terminal.Close()
			var capture bytes.Buffer
			// Unix PTYs can return EIO after the last slave closes.
			_, _ = io.Copy(&capture, terminal)
			if err = command.Wait(); err != nil {
				t.Fatal(err)
			}
			var text string = capture.String()
			for _, line := range []string{"hook started", "warning retained", "model ready"} {
				if strings.Count(text, line) != 1 {
					t.Fatalf("lost or repeated log %q", line)
				}
			}
			if strings.Contains(text, "\x1b]") || strings.Contains(text, "rgb:") {
				t.Fatal("terminal query leaked")
			}
			if !strings.Contains(text, "\x1b[32m") {
				t.Fatal("hook colour lost")
			}
			if terminalMaxRow(text) > 7 {
				t.Fatalf("progress scrolled instead of updating in place: %d rows", terminalMaxRow(text))
			}
		})
	}
}
