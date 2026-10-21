package progress

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

type recordingWriter struct {
	mu    sync.Mutex
	text  strings.Builder
	times []time.Time
}

func (w *recordingWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.times = append(w.times, time.Now())
	return w.text.Write(data)
}

func (w *recordingWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.text.String()
}

func TestHeartbeatContinuesWithoutWorkCallbacks(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Waiting for the beacon", 0, 0)
	time.Sleep(55 * time.Millisecond)
	task.Close()
	display.Close()
	var text string = output.String()
	if strings.Count(text, "Waiting for the beacon") < 3 {
		t.Fatalf("no independent heartbeat: %q", text)
	}
	if strings.Contains(text, "ETA") || strings.Contains(text, "%") || strings.Contains(text, "\x1b") {
		t.Fatalf("unknown total fabricated progress or ANSI: %q", text)
	}
	if !strings.Contains(text, "elapsed") {
		t.Fatal("heartbeat omits elapsed time")
	}
}

func TestKnownTotalsShowMeasurementsWithoutFalseCompletion(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Hash files", 1000, 10)
	task.Set(500, 5, "example.txt")
	time.Sleep(25 * time.Millisecond)
	task.Set(1000, 10, "example.txt")
	task.Close()
	display.Close()
	var text string = output.String()
	for _, fragment := range []string{"50%", "500 B/1000 B", "5/10 entries", "/s", "ETA", "example.txt"} {
		if !strings.Contains(text, fragment) {
			t.Errorf("missing %q: %s", fragment, text)
		}
	}
	if strings.Contains(text, "100%") {
		t.Fatalf("Close reported unverified completion: %s", text)
	}
}

func TestExplicitCompletionAndNestedTasks(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Interval: 10 * time.Millisecond})
	var parent *Task = display.Begin("Lock vault", 0, 0)
	var child *Task = display.Begin("Fetch beacon", 100, 1)
	var limit time.Time = time.Now().Add(500 * time.Millisecond)
	for !strings.Contains(output.String(), "Fetch beacon") && time.Now().Before(limit) {
		time.Sleep(5 * time.Millisecond)
	}
	child.Set(100, 1, "")
	child.Complete()
	child.Close()
	parent.Complete()
	display.Close()
	var text string = output.String()
	if strings.Count(text, "100%") != 1 {
		t.Fatalf("completion missing or duplicated: %q", text)
	}
	if strings.LastIndex(text, "Lock vault") < strings.LastIndex(text, "Fetch beacon") {
		t.Fatal("parent task not restored")
	}
}

func TestPauseStopsAndRestoresRendering(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Waiting", 0, 0)
	var restore func() = display.Pause()
	var before string = output.String()
	time.Sleep(35 * time.Millisecond)
	if output.String() != before {
		t.Fatal("rendered during pause")
	}
	restore()
	restore()
	task.Close()
	display.Close()
	if len(output.String()) <= len(before) {
		t.Fatal("did not restore rendering")
	}
}

func TestWrapSerialisesConcurrentOutput(t *testing.T) {
	var output bytes.Buffer
	var display *Display = New(&output, Options{Interval: time.Millisecond, Terminal: true})
	var writer io.Writer = display.Wrap(&output)
	var task *Task = display.Begin("Copy", 0, 0)
	var group sync.WaitGroup
	for index := 0; index < 8; index++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for step := 0; step < 100; step++ {
				_, _ = writer.Write([]byte("ordinary output\n"))
				task.Add(1024, 1, "file")
			}
		}()
	}
	group.Wait()
	task.Close()
	display.Close()
	if strings.Count(output.String(), "ordinary output") != 800 {
		t.Fatal("lost serialised output")
	}
}

type failedWriter struct{}

func (failedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestOutputFailureDoesNotInterruptTasks(t *testing.T) {
	var display *Display = New(failedWriter{}, Options{Interval: time.Millisecond})
	var task *Task = display.Begin("Work", 100, 1)
	task.Add(100, 1, "file")
	task.SetTotal(200, 2)
	task.Set(200, 2, "")
	task.Complete()
	display.Close()
	if !errors.Is(display.Err(), io.ErrClosedPipe) {
		t.Fatalf("lost writer error: %v", display.Err())
	}
}

func TestSanitisationAndTerminalWidth(t *testing.T) {
	t.Setenv("COLUMNS", "60")
	var output recordingWriter
	var display *Display = New(&output, Options{Terminal: true, Color: "never"})
	var task *Task = display.Begin("Copy\n\x1b[31m"+strings.Repeat("very long label ", 20), 10000, 100)
	task.Set(5000, 50, "file\r\t\x00"+strings.Repeat("x", 100))
	task.Close()
	display.Close()
	var text string = strings.ReplaceAll(strings.ReplaceAll(output.String(), "\x1b[2K", ""), "\x1b[1A", "")
	for _, line := range strings.Split(strings.ReplaceAll(text, "\r", "\n"), "\n") {
		if len([]rune(line)) > 60 {
			t.Fatalf("line exceeds terminal width: %q", line)
		}
	}
	if strings.ContainsAny(text, "\x00\t\x1b") {
		t.Fatalf("unsanitised controls: %q", text)
	}
}

func TestNeverModeAndNilTasks(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Interval: time.Millisecond})
	var task *Task = display.Begin("Work", 10, 1)
	task.Complete()
	display.Close()
	display.Close()
	if output.String() != "" {
		t.Fatal("never mode rendered")
	}
	var absent *Task
	absent.Add(1, 1, "")
	absent.Set(1, 1, "")
	absent.SetTotal(1, 1)
	absent.Close()
	absent.Complete()
}

func TestFastNestedWaitsDoNotFloodOutput(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Interval: time.Second})
	var parent *Task = display.Begin("Lock vault", 0, 0)
	for index := 0; index < 100; index++ {
		var nested *Task = display.Begin("Inspect metadata", 0, 0)
		nested.Close()
		var read *Task = display.Begin("Read protected file", 64, 1)
		read.Set(64, 1, "")
		read.Complete()
	}
	parent.Complete()
	display.Close()
	if strings.Contains(output.String(), "Inspect metadata") {
		t.Fatal("fast nested waits flooded output")
	}
	if strings.Contains(output.String(), "Read protected file") {
		t.Fatal("fast nested completions flooded output")
	}
}

func TestWrappedPartialPromptIsNotErasedByHeartbeat(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Interval: 10 * time.Millisecond, Terminal: true})
	var task *Task = display.Begin("Run user hook", 0, 0)
	var writer io.Writer = display.Wrap(&output)
	_, _ = writer.Write([]byte("Password: "))
	time.Sleep(35 * time.Millisecond)
	var text string = output.String()
	var after string = strings.SplitN(text, "Password: ", 2)[1]
	if !strings.Contains(after, "Password: ") || !strings.Contains(after, "Run user hook") {
		t.Fatal("live display lost the hook prompt or heartbeat")
	}
	if terminalMaxRow(text) > 2 {
		t.Fatal("waiting at an interactive prompt flooded the terminal")
	}
	_, _ = writer.Write([]byte("\n"))
	task.Close()
	display.Close()
}

func TestTerminalLayoutPreservesLargeTransferMeasurements(t *testing.T) {
	var now time.Time = time.Now()
	var task Task = Task{label: strings.Repeat("Validation pass 1/2 ", 10), path: strings.Repeat("directory/", 20) + "file.bin", started: now.Add(-10 * time.Second), bytes: 200000000000, entries: 300000, totalBytes: 416700000000, totalEntries: 672744}
	for _, width := range []int{60, 80, 120} {
		var lines []string = task.terminalLines(now, 1, "", width)
		var text string = strings.Join(lines, "\n")
		for _, fragment := range []string{"ETA", "elapsed", "/s", "300000/672744 entries", "186.3 GiB/388.1 GiB", "[", "=", "."} {
			if !strings.Contains(text, fragment) {
				t.Errorf("width%d misses %q: %s", width, fragment, text)
			}
		}
		for _, line := range lines {
			if len([]rune(line)) > width {
				t.Errorf("width%d exceeded: %q", width, line)
			}
		}
	}
}

func TestDefaultPlainHeartbeatStaysBelowOneSecond(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{})
	var task *Task = display.Begin("Waiting for a blocked operation", 0, 0)
	time.Sleep(1200 * time.Millisecond)
	task.Close()
	display.Close()
	if len(output.times) < 3 {
		t.Fatalf("only%d heartbeat writes", len(output.times))
	}
	for index := 1; index < len(output.times); index++ {
		if gap := output.times[index].Sub(output.times[index-1]); gap >= time.Second {
			t.Fatalf("heartbeat gap %v", gap)
		}
	}
}

func TestUnicodeTerminalCellsRemainWithinWidth(t *testing.T) {
	var samples []struct {
		text  string
		cells int
	} = []struct {
		text  string
		cells int
	}{
		{"界", 2}, {"🙂", 2}, {"e\u0301", 1}, {"\u2764\ufe0f", 2}, {"1\ufe0f\u20e3", 2},
	}
	for _, sample := range samples {
		for _, columns := range []int{60, 80, 120} {
			var task Task = Task{label: "Validate copied files", path: strings.Repeat(sample.text, columns), started: time.Now(), bytes: 500, totalBytes: 1000, entries: 5, totalEntries: 10}
			var lines []string = task.terminalLines(time.Now(), 1, "", columns)
			for _, line := range lines {
				var cells int = len([]rune(line)) + strings.Count(line, sample.text)*(sample.cells-len([]rune(sample.text)))
				if cells > columns {
					t.Errorf("%q width%d uses%d cells: %q", sample.text, columns, cells, line)
				}
			}
		}
	}
}
