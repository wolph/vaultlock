package progress

import (
	"io"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestCarriageReturnProgressDoesNotAppendHeartbeats(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Terminal: true, Color: "always", Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Wait for hook", 0, 0)
	var writer io.Writer = display.Wrap(&output)
	for index := 0; index < 12; index++ {
		if _, err := writer.Write([]byte("\r\x1b[32mLoading model\x1b[0m\x1b[K")); err != nil {
			t.Fatal(err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	task.Complete()
	display.Close()
	var text string = output.String()
	if terminalMaxRow(text) > 3 {
		t.Fatalf("transient progress appended lines: %d", terminalMaxRow(text))
	}
	if !strings.Contains(text, "Loading model") || !strings.Contains(text, "Wait for hook") || !strings.Contains(text, "\x1b[32m") {
		t.Fatal("lost child progress, heartbeat or colour")
	}
}

func TestTerminalQueriesAreSuppressedAcrossWriteBoundaries(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Terminal: true, Color: "always"})
	var writer io.Writer = display.Wrap(&output)
	var source string = "before\x1b]10;?\x07\x1b]4;0;?\x1b\\\x1b[6n\x1b[32mgreen\x1b[0m after\n"
	for _, value := range []byte(source) {
		if _, err := writer.Write([]byte{value}); err != nil {
			t.Fatal(err)
		}
	}
	display.Close()
	if output.String() != "before\x1b[32mgreen\x1b[0m after\n" {
		t.Fatalf("queries escaped or text lost: %q", output.String())
	}
}

func TestRedirectedCarriageProgressKeepsLogsAndFinalSnapshot(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Terminal: false, Color: "never"})
	var writer io.Writer = display.Wrap(&output)
	for _, part := range []string{"real log\n", "\r\x1b[31mloading 1%\x1b[K", "\rloading 99%\x1b[K", "\rready\x1b[0m\n", "last log\n"} {
		if _, err := writer.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
	}
	display.Close()
	if output.String() != "real log\nready\nlast log\n" {
		t.Fatalf("redirected progress polluted log: %q", output.String())
	}
}

// Count terminal rows using ANSI cursor semantics, rather than raw line feeds
// that are subsequently overwritten by cursor movement.
func terminalMaxRow(text string) int {
	var row, maxRow int
	for index := 0; index < len(text); index++ {
		if text[index] == '\n' {
			row++
			if row > maxRow {
				maxRow = row
			}
		}
		if text[index] != 0x1b || index+1 >= len(text) || text[index+1] != '[' {
			continue
		}
		var start int = index + 2
		index = start
		for index < len(text) && (text[index] < 0x40 || text[index] > 0x7e) {
			index++
		}
		if index >= len(text) {
			break
		}
		if text[index] == 'A' {
			var count int
			count, _ = strconv.Atoi(text[start:index])
			if count == 0 {
				count = 1
			}
			row -= count
			if row < 0 {
				row = 0
			}
		}
	}
	return maxRow
}

func TestCRLFAcrossWritesPreservesOrdinaryLines(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Terminal: true})
	var writer io.Writer = display.Wrap(&output)
	for _, part := range []string{"hello\r", "\nworld\r\n"} {
		if _, err := writer.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
	}
	display.Close()
	if output.String() != "hello\nworld\n" {
		t.Fatalf("CRLF erased text: %q", output.String())
	}
}

func TestLargeUnterminatedProgressDoesNotLoseOutput(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Terminal: false})
	var writer io.Writer = display.Wrap(&output)
	_, _ = writer.Write([]byte("\r" + strings.Repeat("a", 64000)))
	_, _ = writer.Write([]byte(strings.Repeat("b", 4000)))
	display.Close()
	if strings.Count(output.String(), "a") != 64000 || strings.Count(output.String(), "b") != 4000 {
		t.Fatal("overflow discarded output")
	}
}

func TestAutomaticRedirectedProgressReportsPhasesWithoutAnimation(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "auto", Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Wait for hook", 0, 0)
	time.Sleep(45 * time.Millisecond)
	task.Complete()
	display.Close()
	if strings.Count(output.String(), "Wait for hook") != 2 {
		t.Fatalf("redirected animation flooded logs: %q", output.String())
	}
}

func TestForcedRedirectedProgressStillHasHeartbeats(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "always", Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Wait for hook", 0, 0)
	time.Sleep(45 * time.Millisecond)
	task.Complete()
	display.Close()
	if strings.Count(output.String(), "Wait for hook") < 3 {
		t.Fatal("forced heartbeat suppressed")
	}
}

func TestHugeSingleWriteDoesNotLoseOrLoop(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Terminal: true, Color: "never"})
	var task *Task = display.Begin("Subprocess", 0, 0)
	var writer io.Writer = display.Wrap(&output)
	if _, err := writer.Write([]byte("\r" + strings.Repeat("z", 200000))); err != nil {
		t.Fatal(err)
	}
	task.Complete()
	display.Close()
	if strings.Count(output.String(), "z") < 200000 {
		t.Fatal("large write lost bytes")
	}
}

func TestPausedDisplayFlushesProgressAndStreamsPromptsImmediately(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Terminal: true, Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Hook", 0, 0)
	var writer io.Writer = display.Wrap(&output)
	_, _ = writer.Write([]byte("\rLoading"))
	var resume func() = display.Pause()
	_, _ = writer.Write([]byte("\rPassword: "))
	if !strings.HasSuffix(output.String(), "Password: ") {
		t.Fatal("paused prompt was buffered")
	}
	var before string = output.String()
	time.Sleep(25 * time.Millisecond)
	if output.String() != before {
		t.Fatal("paused renderer altered prompt")
	}
	_, _ = writer.Write([]byte("\n"))
	resume()
	task.Close()
	display.Close()
}

func TestNeverModeDoesNotHideCarriageReturnPrompts(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Terminal: true})
	var writer io.Writer = display.Wrap(&output)
	_, _ = writer.Write([]byte("\rPassword: "))
	if !strings.HasSuffix(output.String(), "Password: ") {
		t.Fatal("never mode hid interactive prompt")
	}
	display.Close()
}

func TestUnterminatedControlDoesNotSwallowNextTask(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "never", Terminal: true})
	var writer io.Writer = display.Wrap(&output)
	var parent *Task = display.Begin("Unlock", 0, 0)
	var task *Task = display.Begin("Hook", 0, 0)
	_, _ = writer.Write([]byte("\x1b]10;"))
	task.Close()
	_, _ = writer.Write([]byte("real error\n"))
	parent.Close()
	display.Close()
	if output.String() != "real error\n" {
		t.Fatalf("malformed query poisoned diagnostics: %q", output.String())
	}
}

func TestRedirectedFirstFrameIsSeparatedFromFinalFrame(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Mode: "auto", Terminal: false})
	var writer io.Writer = display.Wrap(&output)
	_, _ = writer.Write([]byte("loading 1%\rloading 99%\rready\n"))
	display.Close()
	if output.String() != "loading 1%\nready\n" {
		t.Fatalf("progress frames concatenated: %q", output.String())
	}
}

func TestSuppressedQueriesDoNotClearLiveDisplay(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Terminal: true, Interval: time.Second})
	var task *Task = display.Begin("Working", 0, 0)
	var writer io.Writer = display.Wrap(&output)
	var before string = output.String()
	_, _ = writer.Write([]byte("\x1b]10;?\x07"))
	if output.String() != before {
		t.Fatal("suppressed query erased live progress")
	}
	task.Close()
	display.Close()
}
