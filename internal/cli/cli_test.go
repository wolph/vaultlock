package cli

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestHelpDoesNotNeedConfigurationOrNetwork(t *testing.T) {
	t.Setenv("VAULTLOCK_STATE_DIR", "/missing/state")
	var output bytes.Buffer
	var errors bytes.Buffer
	var status int = Run(context.Background(), []string{"--help"}, &output, &errors)
	if status != 0 || !strings.Contains(output.String(), "vaultlock lock") || errors.Len() != 0 {
		t.Fatalf("status=%d stdout=%q stderr=%q", status, output.String(), errors.String())
	}
}

func TestInvalidArgumentsFailBeforeConfiguration(t *testing.T) {
	var cases [][]string = [][]string{
		{}, {"unknown"}, {"lock"}, {"adopt"}, {"status", "--yes"},
		{"unlock", "--yes"}, {"init", "--no-hooks"}, {"adopt", "--no-hooks", "/data"},
		{"lock", "--color=purple", "20h"}, {"adopt", "--progress=sometimes", "/data"},
		{"status", "extra"}, {"lock", "20h", "--dry-run"}, {"status", "--surprise"},
		{"privileged"}, {"privileged", "revoke"}, {"privileged", "allow", "--yes"},
		{"privileged", "allow", "extra"},
	}
	var arguments []string
	for _, arguments = range cases {
		t.Run(strings.Join(arguments, " "), func(t *testing.T) {
			var output bytes.Buffer
			var errors bytes.Buffer
			var status int = Run(context.Background(), arguments, &output, &errors)
			if status != 64 {
				t.Fatalf("status=%d stdout=%q stderr=%q", status, output.String(), errors.String())
			}
		})
	}
}

func TestParsePreservesDeadlineWordsAndOptions(t *testing.T) {
	var parsed invocation
	var err error
	parsed, err = parse([]string{"lock", "-vv", "--color=never", "--dry-run", "--no-hooks", "09:00", "+2d"})
	if err != nil {
		t.Fatal(err)
	}
	if parsed.command != "lock" || parsed.options.Verbosity != 2 || !parsed.options.DryRun || parsed.options.Hooks || strings.Join(parsed.operands, " ") != "09:00 +2d" {
		t.Fatalf("unexpected invocation: %+v", parsed)
	}
}

func TestEndOfOptionsAllowsDashPrefixedDirectory(t *testing.T) {
	var parsed invocation
	var err error
	parsed, err = parse([]string{"adopt", "--", "-games"})
	if err != nil || len(parsed.operands) != 1 || parsed.operands[0] != "-games" {
		t.Fatalf("parsed=%+v err=%v", parsed, err)
	}
}

func TestForcedColourAppliesToUsageErrors(t *testing.T) {
	t.Setenv("NO_COLOR", "")
	var output bytes.Buffer
	var errors bytes.Buffer
	var status int = Run(context.Background(), []string{"status", "--color=always", "extra"}, &output, &errors)
	if status != 64 || !strings.Contains(errors.String(), "\x1b[1;31mvaultlock:\x1b[0m") {
		t.Fatalf("status=%d error=%q", status, errors.String())
	}
}

func TestUsageErrorEscapesUntrustedTerminalControls(t *testing.T) {
	var output bytes.Buffer
	var errors bytes.Buffer
	var status int = Run(context.Background(), []string{"status", "--color=always", "--bad\x1b[2J\r"}, &output, &errors)
	if status != 64 || strings.Contains(errors.String(), "\x1b[2J") || strings.Contains(errors.String(), "\r") {
		t.Fatalf("status=%d untrusted terminal controls: %q", status, errors.String())
	}
	if !strings.Contains(errors.String(), "--bad?[2J?") {
		t.Fatalf("missing escaped argument: %q", errors.String())
	}
}

func TestPrivilegedAllowParsesWithDryRun(t *testing.T) {
	var parsed invocation
	var err error
	parsed, err = parse([]string{"privileged", "--dry-run", "allow"})
	if err != nil || parsed.command != "privileged" || !parsed.options.DryRun || strings.Join(parsed.operands, " ") != "allow" {
		t.Fatalf("parsed=%+v err=%v", parsed, err)
	}
	var output bytes.Buffer
	if status := Run(context.Background(), []string{"privileged", "--help"}, &output, &output); status != 0 || !strings.Contains(output.String(), "privileged allow") {
		t.Fatalf("help status %d output %q", status, output.String())
	}
}
