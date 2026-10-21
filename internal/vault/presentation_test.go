package vault

import (
	"bytes"
	"regexp"
	"strings"
	"testing"
)

var presentationSGR *regexp.Regexp = regexp.MustCompile("\x1b\\[[0-9;]*m")

func TestPresentationColoursDistinguishStatusAndMeasurements(t *testing.T) {
	var cases []struct {
		text string
		span string
	} = []struct {
		text string
		span string
	}{
		{"LOCKED until tomorrow", "\x1b[1;32mLOCKED\x1b[0m"},
		{"UNLOCKED at /Volumes/vault", "\x1b[1;32mUNLOCKED\x1b[0m"},
		{"INCONSISTENT: recovery is missing", "\x1b[1;31mINCONSISTENT\x1b[0m"},
		{"REPAIRABLE: run vaultlock unlock", "\x1b[1;33mREPAIRABLE\x1b[0m"},
		{"Actions:", "\x1b[1;36mActions:\x1b[0m"},
		{"Hooks: disabled", "\x1b[1;33mdisabled\x1b[0m"},
		{"Result: no changes made", "\x1b[1;32mno changes made\x1b[0m"},
		{"Adopt source into vault", "\x1b[1;36mAdopt\x1b[0m"},
		{"Create encrypted APFS volume", "\x1b[1;36mCreate\x1b[0m"},
	}
	var item struct {
		text string
		span string
	}
	for _, item = range cases {
		t.Run(item.text, func(t *testing.T) {
			var output bytes.Buffer
			var app *App = &App{Out: &output, Options: Options{Color: "always"}}
			app.Report("%s", item.text)
			var actual string = output.String()
			if !strings.Contains(actual, item.span) {
				t.Fatalf("semantic colour missing: %q", actual)
			}
			if plain := presentationSGR.ReplaceAllString(actual, ""); plain != item.text+"\n" {
				t.Fatalf("decoration changed content: %q", plain)
			}
		})
	}
}

func TestMultilinePresentationStylesEachFieldSeparately(t *testing.T) {
	var output bytes.Buffer
	var app *App = &App{Out: &output, Options: Options{Color: "always"}}
	var text string = "Recorded locked: true\nAPFS locked: true\nTarget round: 40000000"
	app.Report("%s", text)
	var lines []string = strings.Split(strings.TrimSuffix(output.String(), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("field layout changed: %q", output.String())
	}
	var line string
	for _, line = range lines {
		if !strings.Contains(line, "\x1b[0m") {
			t.Fatalf("missing per-line style reset: %q", line)
		}
	}
	if actual := presentationSGR.ReplaceAllString(output.String(), ""); actual != text+"\n" {
		t.Fatalf("field content changed: %q", actual)
	}
}

func TestPlainPresentationDoesNotEmitColour(t *testing.T) {
	t.Setenv("NO_COLOR", "")
	var mode string
	for _, mode = range []string{"auto", "never"} {
		var output bytes.Buffer
		var app *App = &App{Out: &output, Options: Options{Color: mode}}
		app.Report("LOCKED until tomorrow")
		if output.String() != "LOCKED until tomorrow\n" {
			t.Fatalf("%s changed plain output: %q", mode, output.String())
		}
	}
}

func TestPresentationEscapesTerminalControls(t *testing.T) {
	var output bytes.Buffer
	var app *App = &App{Out: &output, Options: Options{Color: "always"}}
	app.Report("LOCKED at %s", "folder\x1b[31m\r\x7f")
	var plain string = presentationSGR.ReplaceAllString(output.String(), "")
	if plain != "LOCKED at folder?[31m??\n" {
		t.Fatalf("untrusted terminal controls: %q", plain)
	}
}
