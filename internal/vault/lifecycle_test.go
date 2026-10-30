package vault

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wolph/vaultlock/internal/deadline"
	"github.com/wolph/vaultlock/internal/privileged"
	"github.com/wolph/vaultlock/internal/timelock"
	"howett.net/plist"
)

type fixtureExit int

func (e fixtureExit) Error() string { return "fixture child failure" }
func (e fixtureExit) ExitCode() int { return int(e) }

type lifecycleRunner struct {
	app          *App
	info         VolumeInfo
	key          []byte
	calls        [][]string
	fail         string
	rotated      []byte
	before       func(string, []string)
	unmountLocks bool
	allowed      []string
}

func (r *lifecycleRunner) Run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	r.calls = append(r.calls, append([]string{path}, args...))
	if r.before != nil {
		r.before(path, args)
	}
	if path == "/usr/bin/sudo" {
		path = args[0]
		args = args[1:]
	}
	if path == privileged.HelperPath && len(args) == 2 && args[0] == "allow" {
		r.allowed = append(r.allowed, args[1])
		return nil, nil
	}
	if path == privileged.HelperPath {
		path, args = r.translateHelper(args)
	}
	var joined string = strings.Join(args, " ")
	if r.fail != "" && strings.Contains(joined, r.fail) {
		return nil, errors.New("failure contains a secret that must be discarded")
	}
	switch path {
	case "/usr/sbin/diskutil":
		switch args[0] {
		case "info":
			return plist.Marshal(map[string]any{"VolumeUUID": r.info.UUID, "DeviceIdentifier": r.info.Device, "Locked": r.info.Locked, "MountPoint": r.info.MountPoint, "VolumeName": r.info.Name, "FileVault": true, "FilesystemType": "apfs"}, plist.XMLFormat)
		case "unmount":
			r.info.MountPoint = ""
			r.info.Locked = r.unmountLocks
		case "mount":
			if r.info.Locked {
				return nil, fixtureExit(1)
			}
			r.info.MountPoint = r.app.Config.MountPoint
		case "apfs":
			switch args[1] {
			case "list":
				return plist.Marshal(map[string]any{"Containers": []map[string]any{{"ContainerReference": r.app.Config.Container, "Volumes": []any{}}}}, plist.XMLFormat)
			case "addVolume":
				return []byte("Created new APFS Volume " + r.info.Device + "\n"), nil
			case "unlockVolume":
				r.info.Locked = false
				if !strings.Contains(joined, "-nomount") {
					r.info.MountPoint = r.app.Config.MountPoint
				}
			case "lockVolume":
				r.info.Locked = true
				r.info.MountPoint = ""
			case "changePassphrase":
				if r.info.Locked {
					return nil, errors.New("cannot rotate a locked APFS volume")
				}
				parts := strings.Split(strings.TrimSuffix(string(input), "\n"), "\n")
				r.rotated = []byte(parts[1])
			}
		}
	case "/usr/bin/security":
		switch args[0] {
		case "find-generic-password":
			if r.key == nil {
				return nil, fixtureExit(44)
			}
			return append(append([]byte{}, r.key...), '\n'), nil
		case "delete-generic-password":
			r.key = nil
		case "-i":
			parts := strings.Fields(string(input))
			for i, part := range parts {
				if part == "-w" {
					r.key = []byte(parts[i+1])
				}
			}
		}
	case "/usr/bin/tmutil":
		if args[0] == "isexcluded" {
			return plist.Marshal([]map[string]any{{"Path": args[2], "IsExcluded": uint64(1)}}, plist.XMLFormat)
		}
	}
	return nil, nil
}

// translateHelper maps a helper request onto the system command the real
// helper would run, so the fixture's storage emulation stays in one place.
func (r *lifecycleRunner) translateHelper(args []string) (string, []string) {
	var request privileged.Request
	var err error
	request, err = privileged.Parse(args)
	if err != nil {
		panic("fixture received a malformed helper request: " + err.Error())
	}
	if request.UUID != "" && request.UUID != r.info.UUID {
		panic("fixture received a helper request for an unknown volume " + request.UUID)
	}
	switch request.Kind {
	case privileged.KindUnlock:
		return "/usr/sbin/diskutil", []string{"apfs", "unlockVolume", r.info.Device, "-stdinpassphrase"}
	case privileged.KindUnlockNoMount:
		return "/usr/sbin/diskutil", []string{"apfs", "unlockVolume", r.info.Device, "-nomount", "-stdinpassphrase"}
	case privileged.KindRotate:
		return "/usr/sbin/diskutil", []string{"apfs", "changePassphrase", r.info.Device, "-user", "disk", "-oldStdinpassphrase", "-newStdinpassphrase"}
	case privileged.KindLock:
		return "/usr/sbin/diskutil", []string{"apfs", "lockVolume", r.info.Device}
	case privileged.KindExcludeVolume:
		return "/usr/bin/tmutil", []string{"addexclusion", "-v", r.info.MountPoint}
	case privileged.KindDeleteSnapshots:
		return "/usr/bin/tmutil", []string{"deletelocalsnapshots", r.info.MountPoint}
	case privileged.KindDeleteDataSnapshots:
		return "/usr/bin/tmutil", []string{"deletelocalsnapshots", "/System/Volumes/Data"}
	case privileged.KindExcludePath:
		return "/usr/bin/tmutil", []string{"addexclusion", "-p", request.Path}
	}
	panic("fixture cannot translate helper request")
}

type fixtureCrypto struct {
	encryptFailure, verifyFailure bool
	decrypted                     []byte
	decryptError                  error
	beforeEncrypt                 func()
}

func (c *fixtureCrypto) Encrypt(_ context.Context, pass []byte, _ uint64) ([]byte, error) {
	if c.beforeEncrypt != nil {
		c.beforeEncrypt()
	}
	if c.encryptFailure {
		return nil, errors.New("encrypt failed")
	}
	return append([]byte("cipher:"), pass...), nil
}
func (c *fixtureCrypto) Decrypt(context.Context, []byte) ([]byte, error) {
	if c.decryptError != nil {
		return nil, c.decryptError
	}
	return c.decrypted, nil
}
func (c *fixtureCrypto) VerifyFuture(context.Context, []byte, uint64) error {
	if c.verifyFailure {
		return errors.New("future verification failed")
	}
	return nil
}
func lifecycleFixture(t *testing.T) (*App, *lifecycleRunner) {
	t.Helper()
	var home string = t.TempDir()
	var config Config = Config{Home: home, StateDir: filepath.Join(home, "state"), MountPoint: filepath.Join(home, "mount"), Volume: "vault", Container: "disk3", User: "tester", ConfirmDevice: "/dev/tty"}
	if err := os.Mkdir(config.StateDir, 0700); err != nil {
		t.Fatal(err)
	}
	var a *App = New(config)
	a.Out = io.Discard
	a.Err = io.Discard
	a.Options.Yes = true
	a.Options.Hooks = false
	a.HelperProbe = func(string) bool { return false }
	a.Now = func() time.Time { return time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC) }
	var r *lifecycleRunner = &lifecycleRunner{app: a, info: VolumeInfo{UUID: "UUID", Device: "disk3s7", MountPoint: config.MountPoint, Name: "vault", FileVault: true}, key: []byte("b2xkcGFzcw==")}
	a.Runner = r
	a.Crypto = &fixtureCrypto{}
	if err := a.writeState(State{VolumeUUID: "UUID", Extra: map[string]json.RawMessage{"custom": json.RawMessage(`{"kept":true}`)}}); err != nil {
		t.Fatal(err)
	}
	if err := a.write("passphrase.txt", []byte("b2xkcGFzcw==\n")); err != nil {
		t.Fatal(err)
	}
	if err := a.write("passphrase.sha256", []byte(digest(r.key)+"\n")); err != nil {
		t.Fatal(err)
	}
	return a, r
}
func TestLockRetainsRotatedRecoveryOnFailure(t *testing.T) {
	for _, failure := range []string{"encrypt", "verify", "ciphertext-write", "hash-write", "state-write", "keychain-delete", "rotate"} {
		t.Run(failure, func(t *testing.T) {
			var a *App
			var r *lifecycleRunner

			a, r = lifecycleFixture(t)
			var crypto *fixtureCrypto = a.Crypto.(*fixtureCrypto)
			switch failure {
			case "encrypt":
				crypto.encryptFailure = true
			case "verify":
				crypto.verifyFailure = true
			case "keychain-delete":
				r.fail = "delete-generic-password"
			case "rotate":
				r.fail = "changePassphrase"
			default:
				crypto.beforeEncrypt = func() {
					var name string = map[string]string{"ciphertext-write": "passphrase.tle", "hash-write": "passphrase.sha256", "state-write": "state.json"}[failure]
					if err := os.Chmod(a.path(name), 0400); os.IsNotExist(err) {
						if err = os.WriteFile(a.path(name), []byte("block"), 0400); err != nil {
							t.Fatal(err)
						}
					}
				}
			}
			var err error = a.Run(context.Background(), "lock", []string{"1h"})
			if err == nil {
				t.Fatal("expected injected failure")
			}
			if strings.Contains(err.Error(), "a secret") {
				t.Fatal("child output leaked")
			}
			var staged []byte
			var e error

			staged, e = a.read("passphrase-new.txt")
			if e != nil {
				t.Fatalf("recovery stage not retained: %v (transition: %v)", e, err)
			}
			if failure != "rotate" {
				var pass []byte
				var e error

				pass, e = a.read("passphrase.txt")
				if e != nil {
					t.Fatal(e)
				}
				if strings.TrimSpace(string(pass)) != string(r.rotated) || string(pass) != string(staged) {
					t.Fatal("rotated recovery not retained")
				}
			}
			for _, call := range r.calls {
				for _, arg := range call {
					if len(r.rotated) > 0 && strings.Contains(arg, string(r.rotated)) {
						t.Fatal("passphrase leaked in argv")
					}
				}
			}
		})
	}
}
func TestLockUnlockRoundTripPreservesExtraFields(t *testing.T) {
	var a *App
	var r *lifecycleRunner

	a, r = lifecycleFixture(t)
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(a.path("passphrase.txt")); !os.IsNotExist(err) {
		t.Fatal("plaintext remains after successful lock")
	}
	if _, err := os.Lstat(a.path("passphrase-new.txt")); !os.IsNotExist(err) {
		t.Fatal("staged plaintext remains")
	}
	if !r.info.Locked || r.key != nil {
		t.Fatal("target not sealed")
	}
	var s State
	var err error

	s, err = a.ReadState()
	if err != nil || !s.Locked {
		t.Fatal("state not locked", err)
	}
	a.Crypto = &fixtureCrypto{decrypted: r.rotated}
	if err = a.Run(context.Background(), "unlock", nil); err != nil {
		t.Fatal(err)
	}
	s, err = a.ReadState()
	if err != nil || s.Locked || s.Deadline != nil {
		t.Fatal("state not unlocked", err)
	}
	var custom map[string]bool
	if err := json.Unmarshal(s.Extra["custom"], &custom); err != nil {
		t.Fatal(err)
	}
	if !custom["kept"] {
		t.Fatal("extra fields lost")
	}
	if r.info.Locked || r.info.MountPoint != a.Config.MountPoint {
		t.Fatal("volume not usable")
	}
}
func TestLockConfirmationDriftStopsBeforeMutation(t *testing.T) {
	var a *App
	var r *lifecycleRunner

	a, r = lifecycleFixture(t)
	a.Options.Yes = false
	a.Confirm = &confirmationMutation{mutate: func() { r.info.Device = "disk3s8" }}
	var err error = a.Run(context.Background(), "lock", []string{"1h"})
	if err == nil {
		t.Fatal("expected drift rejection")
	}
	for _, call := range r.calls {
		if call[0] == "/usr/bin/sudo" {
			t.Fatal("mutation occurred after drift")
		}
	}
}

type confirmationMutation struct {
	mutate func()
	done   bool
}

func (r *confirmationMutation) Read(data []byte) (int, error) {
	if r.done {
		return 0, io.EOF
	}
	r.done = true
	r.mutate()
	return copy(data, "yes\n"), nil
}
func TestOperationLockRefusesConcurrentAndLegacyOwners(t *testing.T) {
	var a *App

	a, _ = lifecycleFixture(t)
	var release func()
	var err error

	release, err = a.acquire()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.acquire(); err == nil {
		t.Fatal("concurrent lock acquired")
	}
	release()
	release, err = a.acquire()
	if err != nil {
		t.Fatal("stale file must be reusable", err)
	}
	release()
	var path string = filepath.Join(a.Config.Home, ".vaultlock-operation.lock")
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err = os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err = a.acquire(); err == nil {
		t.Fatal("legacy directory lock accepted")
	}
}
func TestProtectedFileValidation(t *testing.T) {
	var a *App

	a, _ = lifecycleFixture(t)
	var path string = a.path("passphrase.txt")
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := a.read("passphrase.txt"); err == nil {
		t.Fatal("public recovery file accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(a.path("passphrase.sha256"), path); err != nil {
		t.Fatal(err)
	}
	if _, err := a.read("passphrase.txt"); err == nil {
		t.Fatal("symlink recovery accepted")
	}
}

func TestCancellationAfterRecoveryDeletionStillSeals(t *testing.T) {
	var a *App
	var r *lifecycleRunner

	a, r = lifecycleFixture(t)
	var ctx context.Context
	var cancel context.CancelFunc

	ctx, cancel = context.WithCancel(context.Background())
	r.before = func(path string, args []string) {
		if path == "/usr/bin/security" && args[0] == "delete-generic-password" {
			cancel()
		}
	}
	var err error = a.Run(ctx, "lock", []string{"1h"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation after seal, got %v", err)
	}
	if !r.info.Locked {
		t.Fatal("cancellation left volume unsealed")
	}
	if _, err := os.Lstat(a.path("passphrase.txt")); !os.IsNotExist(err) {
		t.Fatal("plaintext remains")
	}
}
func TestUnsafePlaintextNeverReportedLocked(t *testing.T) {
	var a *App
	var r *lifecycleRunner

	a, r = lifecycleFixture(t)
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	if !r.info.Locked {
		t.Fatal("fixture failed to lock")
	}
	if err := os.Symlink("missing", a.path("passphrase.txt")); err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	a.Out = &output
	if err := a.Run(context.Background(), "status", nil); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(output.String(), "INCONSISTENT") {
		t.Fatalf("unsafe-present plaintext misreported: %s", output.String())
	}
}
func TestHookAddedDuringConfirmationRejected(t *testing.T) {
	var a *App
	var r *lifecycleRunner

	a, r = lifecycleFixture(t)
	a.Options.Hooks = true
	a.Options.Yes = false
	a.Confirm = &confirmationMutation{mutate: func() {
		if err := os.WriteFile(a.path("pre-lock.sh"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}}
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err == nil {
		t.Fatal("new hook accepted after planning")
	}
	for _, call := range r.calls {
		if call[0] == "/usr/bin/sudo" {
			t.Fatal("mutation began after hook drift")
		}
	}
}
func TestRecordedLockedDryRunDoesNotNeedCrypto(t *testing.T) {
	var a *App

	a, _ = lifecycleFixture(t)
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	a.Crypto = nil
	a.Options.DryRun = true
	if err := a.Run(context.Background(), "unlock", nil); err != nil {
		t.Fatal(err)
	}
}

func TestEarlyUnlockReportsAbsoluteAndRemainingDeadline(t *testing.T) {
	var a *App

	a, _ = lifecycleFixture(t)
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	var expected string = deadline.Format(time.Unix(a.Now().Add(time.Hour).Unix(), 0), a.Now())
	if !strings.HasSuffix(expected, "(in 1h)") {
		t.Fatalf("fixture deadline %q lacks remaining time", expected)
	}
	var output bytes.Buffer
	a.Out = &output
	a.Crypto = &fixtureCrypto{decryptError: timelock.ErrTooEarly}
	var err error = a.Run(context.Background(), "unlock", nil)
	if err == nil {
		t.Fatal("early unlock succeeded")
	}
	var wanted string = "still locked until " + expected + " - this failure is the lock working"
	if err.Error() != wanted {
		t.Fatalf("error %q, wanted %q", err.Error(), wanted)
	}
	var plan string = "Unlock UUID after " + expected + ", drand round"
	if !strings.Contains(output.String(), plan) {
		t.Fatalf("output %q lacks plan line %q", output.String(), plan)
	}
	a.Crypto = &fixtureCrypto{decryptError: errors.New("beacon unreachable")}
	err = a.Run(context.Background(), "unlock", nil)
	if err == nil || !strings.Contains(err.Error(), expected) || !strings.Contains(err.Error(), "beacon unreachable") {
		t.Fatalf("outage error %v lacks deadline %q or cause", err, expected)
	}
	output.Reset()
	a.Options.DryRun = true
	if err = a.Run(context.Background(), "unlock", nil); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), plan) {
		t.Fatalf("dry-run output %q lacks plan line %q", output.String(), plan)
	}
}

func initFixture(t *testing.T) (*App, *lifecycleRunner) {
	t.Helper()
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	for _, name := range []string{"state.json", "passphrase.txt", "passphrase.sha256"} {
		if err := os.Remove(a.path(name)); err != nil {
			t.Fatal(err)
		}
	}
	r.key = nil
	return a, r
}
func TestInitPinsRecoveryAcrossExternalCalls(t *testing.T) {
	for _, phase := range []string{"keychain", "create", "state-appears"} {
		t.Run(phase, func(t *testing.T) {
			var a *App
			var r *lifecycleRunner
			a, r = initFixture(t)
			r.before = func(path string, args []string) {
				var keychain bool = path == "/usr/bin/security" && args[0] == "-i"
				var create bool = path == "/usr/bin/sudo" && len(args) > 2 && args[2] == "addVolume"
				if (phase == "keychain" && keychain) || (phase == "create" && create) {
					if err := os.WriteFile(a.path("passphrase.txt"), []byte("changed\n"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				if phase == "state-appears" && create {
					if err := os.WriteFile(a.path("state.json"), []byte("unrelated existing state"), 0600); err != nil {
						t.Fatal(err)
					}
				}
			}
			if err := a.Run(context.Background(), "init", nil); err == nil {
				t.Fatal("init reported success after recovery drift")
			}
			if phase == "keychain" {
				for _, call := range r.calls {
					if len(call) > 3 && call[0] == "/usr/bin/sudo" && call[3] == "addVolume" {
						t.Fatal("APFS creation proceeded after recovery drift")
					}
				}
			}
			if phase == "state-appears" {
				var data []byte
				var err error
				data, err = os.ReadFile(a.path("state.json"))
				if err != nil || string(data) != "unrelated existing state" {
					t.Fatal("preexisting state was overwritten")
				}
			}
		})
	}
}
func TestInitCreatesVerifiedState(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = initFixture(t)
	if err := a.Run(context.Background(), "init", nil); err != nil {
		t.Fatal(err)
	}
	var state State
	var err error
	state, err = a.ReadState()
	if err != nil || state.VolumeUUID != r.info.UUID || state.Locked {
		t.Fatal("unexpected initial state", err)
	}
	if _, err = a.plaintext(); err != nil {
		t.Fatal(err)
	}
}
func TestDeferredHooksDoNotTraverseUnmountedDirectory(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	r.info.MountPoint = ""
	a.Options.DryRun = true
	a.Options.Hooks = true
	if err := os.MkdirAll(filepath.Join(a.Config.MountPoint, ".vaultlock"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(a.Config.MountPoint, ".vaultlock", "hooks"), []byte("not a directory"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal("deferred local hooks inspected before mount", err)
	}
}

func TestConfigurationRejectsUnsafeInteractiveNames(t *testing.T) {
	var a *App
	a, _ = lifecycleFixture(t)
	for _, value := range []string{"bad;command", "bad`command`", "bad\x1bname", "bad name", "../path", "."} {
		var config Config = a.Config
		config.Volume = value
		if err := config.validate(); err == nil {
			t.Fatalf("unsafe name accepted: %q", value)
		}
	}
	for _, value := range []string{"/path/with\ttab", "/path/with\x1bescape", "/path/with\x7fdelete"} {
		var config Config = a.Config
		config.StateDir = value
		if err := config.validate(); err == nil {
			t.Fatalf("unsafe path accepted: %q", value)
		}
	}
}
func TestStateIntegralNumberCompatibility(t *testing.T) {
	for _, number := range []string{"1000", "1000.0", "1e3", "10.00e2"} {
		var state State
		var raw string = `{"locked":true,"volume_uuid":"UUID","deadline":"future","deadline_epoch":` + number + `,"round":` + number + `}`
		if err := json.Unmarshal([]byte(raw), &state); err != nil {
			t.Fatalf("compatible integer %s rejected: %v", number, err)
		}
		if state.Round == nil || *state.Round != 1000 || state.DeadlineEpoch == nil || *state.DeadlineEpoch != 1000 {
			t.Fatal("integer altered")
		}
	}
	for _, number := range []string{"1.01", "-1", "1e18", "1e999999999", "\"1000\""} {
		var state State
		var raw string = `{"locked":true,"volume_uuid":"UUID","deadline":"future","deadline_epoch":` + number + `,"round":1000}`
		if err := json.Unmarshal([]byte(raw), &state); err == nil {
			t.Fatalf("unsafe integer %s accepted", number)
		}
	}
}

func TestUnlockPinsRecoveryAcrossExternalCalls(t *testing.T) {
	for _, locked := range []bool{false, true} {
		t.Run(map[bool]string{false: "repair", true: "recover"}[locked], func(t *testing.T) {
			var a *App
			var r *lifecycleRunner
			a, r = lifecycleFixture(t)
			if locked {
				if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
					t.Fatal(err)
				}
				a.Crypto = &fixtureCrypto{decrypted: r.rotated}
			} else {
				r.info.Locked = true
				r.info.MountPoint = ""
			}
			r.before = func(path string, args []string) {
				if path == "/usr/bin/security" && args[0] == "-i" {
					if err := os.WriteFile(a.path("passphrase.txt"), []byte("corrupted\n"), 0600); err != nil {
						t.Fatal(err)
					}
				}
			}
			if err := a.Run(context.Background(), "unlock", nil); err == nil {
				t.Fatal("unlock reported success after recovery mutation")
			}
			var state State
			var err error
			state, err = a.ReadState()
			if err != nil {
				t.Fatal(err)
			}
			if locked && !state.Locked {
				t.Fatal("recorded locked state cleared after recovery drift")
			}
		})
	}
}

func TestLockSealsDespiteDataSnapshotCleanupFailure(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	r.fail = "/System/Volumes/Data"
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err == nil {
		t.Fatal("snapshot failure was not reported")
	}
	if !r.info.Locked {
		t.Fatal("snapshot cleanup failure prevented sealing")
	}
	if _, err := os.Lstat(a.path("passphrase.txt")); !os.IsNotExist(err) {
		t.Fatal("plaintext remains after sealing")
	}
}

func TestColourExplicitAndAutomaticChoices(t *testing.T) {
	var a *App
	a, _ = lifecycleFixture(t)
	var file *os.File
	var err error
	file, err = os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	a.Out = file
	a.Options.Color = "auto"
	if a.colourEnabled() {
		t.Fatal("character device without terminal accepted")
	}
	t.Setenv("NO_COLOR", "")
	a.Options.Color = "auto"
	if a.colourEnabled() {
		t.Fatal("NO_COLOR ignored")
	}
	a.Options.Color = "always"
	if !a.colourEnabled() {
		t.Fatal("explicit colour did not override environment")
	}
	a.Options.Color = "never"
	if a.colourEnabled() {
		t.Fatal("explicit colour disable ignored")
	}
	t.Setenv("TERM", "dumb")
	a.Options.Color = "auto"
	if a.colourEnabled() {
		t.Fatal("dumb terminal accepted")
	}
}

func TestProgressModeChangesDiagnostics(t *testing.T) {
	var a *App
	a, _ = lifecycleFixture(t)
	var output strings.Builder
	a.Err = &output
	a.Options.Progress = "always"
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "Prepare vault lock") {
		t.Fatal("forced progress missing")
	}
	output.Reset()
	a.Options.Progress = "never"
	a.progress("should remain hidden")
	if output.Len() != 0 {
		t.Fatal("disabled progress emitted output")
	}
}
