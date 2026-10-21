package vault

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
)

type unmountFailureRunner struct{ base *lifecycleRunner }

func (r unmountFailureRunner) Run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	if path == "/usr/sbin/diskutil" && len(args) == 2 && args[0] == "unmount" {
		return []byte("Volume vault failed to unmount: dissented by PID 29932 (node)\n"), &exec.ExitError{Stderr: []byte("Resource busy\n")}
	}
	return r.base.Run(ctx, path, args, input)
}

func TestBusyUnmountExplainsFailureAndPreservesRecovery(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	var before []byte
	var err error
	before, err = os.ReadFile(a.path("passphrase.txt"))
	if err != nil {
		t.Fatal(err)
	}
	a.Runner = unmountFailureRunner{base: r}
	err = a.Run(context.Background(), "lock", []string{"1h"})
	if err == nil || !strings.Contains(err.Error(), "PID 29932") || !strings.Contains(err.Error(), "Resource busy") {
		t.Fatalf("missing unmount diagnostic: %v", err)
	}
	var after []byte
	after, err = os.ReadFile(a.path("passphrase.txt"))
	if err != nil || string(before) != string(after) {
		t.Fatalf("recovery changed: %v", err)
	}
	if len(r.rotated) != 0 || r.info.Locked || r.info.MountPoint == "" || r.key == nil {
		t.Fatal("busy unmount changed the vault or Keychain")
	}
	for _, call := range r.calls {
		if strings.Contains(strings.Join(call, " "), "force") {
			t.Fatal("attempted forced unmount")
		}
	}
}

func TestSystemRunnerRetainsFailedCommandDiagnostics(t *testing.T) {
	var output []byte
	var err error
	output, err = (systemRunner{}).Run(context.Background(), "/bin/sh", []string{"-c", "printf 'unmount stdout'; printf 'unmount stderr' >&2; exit 1"}, nil)
	var failure *exec.ExitError
	var ok bool
	failure, ok = err.(*exec.ExitError)
	if string(output) != "unmount stdout" || !ok || string(failure.Stderr) != "unmount stderr" {
		t.Fatalf("lost diagnostic: %q %v", output, err)
	}
}

type diagnosticFailureRunner struct{}

func (diagnosticFailureRunner) Run(context.Context, string, []string, []byte) ([]byte, error) {
	return []byte("private stdout"), &exec.ExitError{Stderr: []byte("private stderr")}
}

func TestOnlyUnmountWithoutSecretsExposesDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		name, path string
		args       []string
		input      []byte
	}{
		{name: "Keychain", path: "/usr/bin/security", args: []string{"-i"}},
		{name: "rotation", path: "/usr/sbin/diskutil", args: []string{"apfs", "changePassphrase", "disk3s7"}, input: []byte("private input")},
		{name: "unexpected input", path: "/usr/sbin/diskutil", args: []string{"unmount", "disk3s7"}, input: []byte("private input")},
		{name: "unexpected device", path: "/usr/sbin/diskutil", args: []string{"unmount", "not-a-device"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var a *App
			a, _ = lifecycleFixture(t)
			a.Runner = diagnosticFailureRunner{}
			var err error
			_, err = a.run(context.Background(), tc.path, tc.args, tc.input)
			if err == nil || strings.Contains(err.Error(), "private") {
				t.Fatalf("private diagnostic escaped: %v", err)
			}
		})
	}
}

func TestUnmountDiagnosticIsBoundedAndControlsAreRemoved(t *testing.T) {
	var err error = unmountError("disk3s7", []byte("\x1b\x00"+strings.Repeat("a", 10000)), &exec.ExitError{})
	var message string = err.Error()
	if strings.ContainsAny(message, "\x1b\x00") || !strings.Contains(message, "[diagnostic truncated]") || len(message) > 4500 {
		t.Fatal("unsafe or unbounded diagnostic")
	}
}

func TestLockHandlesAPFSAutoLockOnUnmount(t *testing.T) {
	for _, unlockFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "round trip", true: "unlock failure retains recovery"}[unlockFails], func(t *testing.T) {
			var a *App
			var r *lifecycleRunner
			a, r = lifecycleFixture(t)
			r.unmountLocks = true
			if unlockFails {
				r.fail = "unlockVolume"
			}
			var err error = a.Run(context.Background(), "lock", []string{"1h"})
			if unlockFails {
				if err == nil || len(r.rotated) != 0 || r.key == nil {
					t.Fatalf("failed unlock rotated recovery: %v", err)
				}
				var pass []byte
				pass, err = a.read("passphrase.txt")
				if err != nil || strings.TrimSpace(string(pass)) != string(r.key) {
					t.Fatal("lost original recovery")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var nomount bool
			for _, call := range r.calls {
				if strings.Contains(strings.Join(call, " "), "unlockVolume disk3s7 -nomount -stdinpassphrase") {
					nomount = true
				}
			}
			if !nomount || !r.info.Locked || r.info.MountPoint != "" || r.key != nil {
				t.Fatal("auto-locked volume was not prepared and sealed safely")
			}
			a.Crypto = &fixtureCrypto{decrypted: r.rotated}
			if err = a.Run(context.Background(), "unlock", nil); err != nil {
				t.Fatal(err)
			}
			if r.info.Locked || r.info.MountPoint != a.Config.MountPoint {
				t.Fatal("round trip did not restore access")
			}
		})
	}
}
