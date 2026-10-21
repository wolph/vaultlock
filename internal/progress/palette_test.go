package progress

import (
	"bytes"
	"io"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

var sgrPattern *regexp.Regexp = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripSGR(text string) string { return sgrPattern.ReplaceAllString(text, "") }

func TestColourPolicy(t *testing.T) {
	t.Setenv("TERM", "xterm-256color")
	t.Setenv("NO_COLOR", "")
	if ColourEnabled("auto", true) {
		t.Fatal("empty NO_COLOR still disables automatic colour")
	}
	if !ColourEnabled("always", false) {
		t.Fatal("always did not override NO_COLOR and redirected output")
	}
	t.Setenv("TERM", "dumb")
	if !ColourEnabled("always", true) {
		t.Fatal("always did not override dumb terminal")
	}
	if ColourEnabled("never", true) {
		t.Fatal("never mode coloured output")
	}
	var err error = os.Unsetenv("NO_COLOR")
	if err != nil {
		t.Fatal(err)
	}
	if ColourEnabled("auto", true) {
		t.Fatal("dumb terminal coloured automatically")
	}
	t.Setenv("TERM", "xterm")
	if !ColourEnabled("auto", true) || !ColourEnabled("", true) {
		t.Fatal("automatic terminal colour missing")
	}
	if ColourEnabled("auto", false) {
		t.Fatal("redirected output coloured automatically")
	}
}

func TestPaletteRolesAndBalancedResets(t *testing.T) {
	var palette Palette = Palette{Enabled: true}
	var roles []struct {
		name  string
		style func(string) string
		code  string
	} = []struct {
		name  string
		style func(string) string
		code  string
	}{
		{"heading", palette.Heading, "1;36"}, {"accent", palette.Accent, "36"}, {"number", palette.Number, "1;36"}, {"label", palette.Label, "2"}, {"path", palette.Path, "2"}, {"rate", palette.Rate, "32"}, {"eta", palette.ETA, "33"}, {"success", palette.Success, "1;32"}, {"warning", palette.Warning, "1;33"}, {"error", palette.Error, "1;31"},
	}
	var role struct {
		name  string
		style func(string) string
		code  string
	}
	for _, role = range roles {
		var got string = role.style("example")
		if got != "\x1b["+role.code+"mexample\x1b[0m" {
			t.Errorf("%s: %q", role.name, got)
		}
	}
	palette.Enabled = false
	if palette.Heading("example") != "example" || palette.Error("example") != "example" {
		t.Fatal("disabled palette changed text")
	}
}

func TestStyledLayoutsPreservePlainContentAndCellWidths(t *testing.T) {
	var now time.Time = time.Now()
	var task Task = Task{label: "Verify copied source", path: strings.Repeat("界e\u0301\u2764\ufe0f/", 20) + "file.bin", started: now.Add(-10 * time.Second), bytes: 200000000000, entries: 300000, totalBytes: 416700000000, totalEntries: 672744}
	var columns int
	for _, columns = range []int{60, 80, 120} {
		var status string
		for _, status = range []string{"", "done"} {
			var plain []string = task.terminalLines(now, 2, status, columns)
			var styled []string = task.styledTerminalLines(now, 2, status, columns, Palette{Enabled: true})
			if len(plain) != len(styled) {
				t.Fatal("colour changed row count")
			}
			var index int
			var line string
			for index, line = range styled {
				if stripSGR(line) != plain[index] {
					t.Fatalf("width%d content changed: %q != %q", columns, stripSGR(line), plain[index])
				}
				if textWidth(stripSGR(line)) > columns {
					t.Fatalf("width%d exceeded", columns)
				}
				if len(sgrPattern.FindAllString(line, -1))%2 != 0 {
					t.Fatalf("unbalanced style spans: %q", line)
				}
			}
		}
	}
	if stripSGR(task.styledDescription(now, 2, "", Palette{Enabled: true})) != task.describe(now, 2, "") {
		t.Fatal("plain log content changed with colour")
	}
	task.totalBytes = 0
	task.totalEntries = 0
	var unknown string = task.styledDescription(now, 2, "", Palette{Enabled: true})
	if strings.Contains(stripSGR(unknown), "%") || strings.Contains(stripSGR(unknown), "ETA") {
		t.Fatal("unknown totals gained fabricated measurements")
	}
}

func TestAlwaysColourRedirectedOutputUsesOnlySGR(t *testing.T) {
	var output bytes.Buffer
	var display *Display = New(&output, Options{Color: "always", Terminal: false})
	var task *Task = display.Begin("Wait for the beacon", 0, 0)
	task.Complete()
	display.Close()
	var text string = output.String()
	if !strings.Contains(text, "\x1b[") {
		t.Fatal("always mode omitted colours")
	}
	if strings.ContainsAny(stripSGR(text), "\x1b\r") {
		t.Fatalf("redirected colour contains cursor controls: %q", text)
	}
}

func TestColouredPartialPromptRemainsVisibleWithoutScrolling(t *testing.T) {
	var output recordingWriter
	var display *Display = New(&output, Options{Color: "always", Terminal: true, Interval: 10 * time.Millisecond})
	var task *Task = display.Begin("Run the hook", 0, 0)
	var writer io.Writer = display.Wrap(&output)
	_, _ = writer.Write([]byte("Answer: "))
	time.Sleep(35 * time.Millisecond)
	var after string = strings.SplitN(output.String(), "Answer: ", 2)[1]
	if !strings.Contains(after, "Answer: ") || !strings.Contains(after, "Run the hook") {
		t.Fatal("coloured redraw lost prompt or heartbeat")
	}
	if terminalMaxRow(output.String()) > 2 {
		t.Fatal("coloured prompt heartbeat scrolled the terminal")
	}
	_, _ = writer.Write([]byte("\n"))
	task.Close()
	display.Close()
}

func TestSanitiseTextPreservesAuthoredWhitespaceAndBlocksTerminalControls(t *testing.T) {
	var input string = "Heading\n\tPath 界é\x1b[31m\r\x00\x7f\u0085\x1b]0;title\a"
	var want string = "Heading\n\tPath 界é?[31m?????]0;title?"
	var got string = SanitiseText(input)
	if got != want {
		t.Fatalf("got%q, want%q", got, want)
	}
	got = sanitise(input)
	if strings.ContainsAny(got, "\n\t") {
		t.Fatal("task paths gained multiline whitespace")
	}
}
