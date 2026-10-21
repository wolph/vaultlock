package vault

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

type activityLog struct {
	mu      sync.Mutex
	text    strings.Builder
	fail    bool
	changed chan struct{}
}

func (l *activityLog) Write(data []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.fail {
		return 0, io.ErrClosedPipe
	}
	var count int
	var err error
	count, err = l.text.Write(data)
	select {
	case l.changed <- struct{}{}:
	default:
	}
	return count, err
}
func (l *activityLog) snapshot() string { l.mu.Lock(); defer l.mu.Unlock(); return l.text.String() }
func (l *activityLog) stop()            { l.mu.Lock(); l.fail = true; l.mu.Unlock() }

func (l *activityLog) waitFor(t *testing.T, label string, count int) string {
	t.Helper()
	var timeout *time.Timer = time.NewTimer(2 * time.Second)
	defer timeout.Stop()
	for {
		var text string = l.snapshot()
		if strings.Count(text, label) >= count {
			return text
		}
		select {
		case <-l.changed:
		case <-timeout.C:
			t.Fatalf("independent heartbeat missing for %s: %s", label, text)
		}
	}
}

type activityGate struct {
	entered   chan struct{}
	release   chan struct{}
	once      sync.Once
	closeOnce sync.Once
}

func newActivityGate() *activityGate {
	return &activityGate{entered: make(chan struct{}), release: make(chan struct{})}
}
func (g *activityGate) wait(ctx context.Context) error {
	g.once.Do(func() { close(g.entered) })
	select {
	case <-g.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (g *activityGate) open() { g.closeOnce.Do(func() { close(g.release) }) }

type activityRunner struct {
	base  Runner
	gate  *activityGate
	match func(string, []string) bool
}

func (r *activityRunner) Run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	if r.match(path, args) {
		if err := r.gate.wait(ctx); err != nil {
			return nil, err
		}
	}
	return r.base.Run(ctx, path, args, input)
}

type activityCrypto struct {
	base  Crypto
	gate  *activityGate
	stage string
}

func (c *activityCrypto) Encrypt(ctx context.Context, input []byte, round uint64) ([]byte, error) {
	if c.stage == "encrypt" {
		if err := c.gate.wait(ctx); err != nil {
			return nil, err
		}
	}
	return c.base.Encrypt(ctx, input, round)
}
func (c *activityCrypto) Decrypt(ctx context.Context, input []byte) ([]byte, error) {
	if c.stage == "decrypt" {
		if err := c.gate.wait(ctx); err != nil {
			return nil, err
		}
	}
	return c.base.Decrypt(ctx, input)
}
func (c *activityCrypto) VerifyFuture(ctx context.Context, input []byte, round uint64) error {
	if c.stage == "verify" {
		if err := c.gate.wait(ctx); err != nil {
			return err
		}
	}
	return c.base.VerifyFuture(ctx, input, round)
}

func TestIndependentActivityDuringLifecycleWaits(t *testing.T) {
	for _, scenario := range []string{"inspect", "keychain", "snapshots", "rotation", "hook", "encrypt", "verify", "decrypt"} {
		t.Run(scenario, func(t *testing.T) {
			var a *App
			var runner *lifecycleRunner
			a, runner = lifecycleFixture(t)
			var command string = "lock"
			var operands []string = []string{"1h"}
			if scenario == "decrypt" {
				if err := a.Run(context.Background(), "lock", operands); err != nil {
					t.Fatal(err)
				}
				a.Crypto = &fixtureCrypto{decrypted: runner.rotated}
				command = "unlock"
				operands = nil
			}
			var gate *activityGate = newActivityGate()
			defer gate.open()
			var log *activityLog = &activityLog{changed: make(chan struct{}, 1)}
			a.Err = log
			a.progressInterval = 10 * time.Millisecond
			a.Options.Progress = "always"
			var label string
			var match func(string, []string) bool
			switch scenario {
			case "inspect":
				command = "status"
				operands = nil
				label = "Inspect APFS volume identity"
				match = func(path string, args []string) bool { return path == "/usr/sbin/diskutil" && args[0] == "info" }
			case "keychain":
				label = "Read the protected Keychain"
				match = func(path string, args []string) bool {
					return path == "/usr/bin/security" && args[0] == "find-generic-password"
				}
			case "snapshots":
				label = "Delete local Time Machine snapshots"
				match = func(path string, args []string) bool {
					return path == "/usr/bin/sudo" && len(args) > 1 && args[1] == "deletelocalsnapshots"
				}
			case "rotation":
				label = "Rotate the APFS recovery passphrase"
				match = func(path string, args []string) bool {
					return path == "/usr/bin/sudo" && strings.Contains(strings.Join(args, " "), "changePassphrase")
				}
			case "hook":
				var path string = a.path("pre-lock.sh")
				if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
					t.Fatal(err)
				}
				a.Options.Hooks = true
				label = "Wait for pre-lock hook pre-lock.sh"
				match = func(candidate string, _ []string) bool { return candidate == path }
			case "encrypt":
				label = "Encrypt recovery material for the future drand round"
			case "verify":
				label = "Verify future time-lock ciphertext against drand"
			case "decrypt":
				label = "Wait for drand and decrypt recovery material"
			}
			if match != nil {
				a.Runner = &activityRunner{base: runner, gate: gate, match: match}
			} else {
				a.Crypto = &activityCrypto{base: a.Crypto, gate: gate, stage: scenario}
			}
			var result chan error = make(chan error, 1)
			go func() { result <- a.Run(context.Background(), command, operands) }()
			select {
			case <-gate.entered:
			case <-time.After(3 * time.Second):
				t.Fatal("operation did not reach expected wait")
			}
			var during string = log.waitFor(t, label, 3)
			if strings.Contains(during, "\x1b") {
				t.Error("automatic non-terminal heartbeat contains ANSI")
			}
			if strings.Contains(during, "b2xkcGFzcw==") {
				t.Error("passphrase leaked into activity")
			}
			gate.open()
			select {
			case err := <-result:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("operation did not finish")
			}
			var after string = log.snapshot()
			time.Sleep(30 * time.Millisecond)
			if log.snapshot() != after {
				t.Error("ticker continued after App.Run returned")
			}
			if a.display != nil || a.Err != log {
				t.Error("progress display or writer leaked across invocations")
			}
		})
	}
}

func TestActivityOutputFailureStopsBeforeStorageMutation(t *testing.T) {
	var a *App
	var runner *lifecycleRunner
	a, runner = lifecycleFixture(t)
	var log *activityLog = &activityLog{fail: true}
	a.Err = log
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err == nil {
		t.Fatal("output failure ignored")
	}
	if len(runner.calls) != 0 {
		t.Fatal("system operations occurred after initial output failure")
	}
	if _, err := os.Lstat(a.Config.Home + "/.vaultlock-operation.lock"); !os.IsNotExist(err) {
		t.Fatal("operation lock created after output failure")
	}
}
func TestActivityOutputFailureStillCompletesCommittedSeal(t *testing.T) {
	var a *App
	var runner *lifecycleRunner
	a, runner = lifecycleFixture(t)
	var log *activityLog = &activityLog{}
	a.Err = log
	runner.before = func(path string, args []string) {
		if path == "/usr/bin/security" && args[0] == "delete-generic-password" {
			log.stop()
			fmt.Fprintln(a.Err, "output interrupted")
		}
	}
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err == nil {
		t.Fatal("output failure ignored")
	}
	if !runner.info.Locked {
		t.Fatal("output failure prevented the committed seal")
	}
	if _, err := os.Lstat(a.path("passphrase.txt")); !os.IsNotExist(err) {
		t.Fatal("plaintext recovery remained after seal")
	}
}
func TestActivityCancellationStopsHeartbeat(t *testing.T) {
	var a *App
	var runner *lifecycleRunner
	a, runner = lifecycleFixture(t)
	var gate *activityGate = newActivityGate()
	defer gate.open()
	a.Runner = &activityRunner{base: runner, gate: gate, match: func(path string, args []string) bool { return path == "/usr/sbin/diskutil" && args[0] == "info" }}
	var log *activityLog = &activityLog{}
	a.Err = log
	a.progressInterval = 10 * time.Millisecond
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	var result chan error = make(chan error, 1)
	go func() { result <- a.Run(ctx, "lock", []string{"1h"}) }()
	<-gate.entered
	cancel()
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("cancelled operation succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled progress did not finish")
	}
	var after string = log.snapshot()
	time.Sleep(30 * time.Millisecond)
	if log.snapshot() != after {
		t.Fatal("cancelled ticker remained active")
	}
}

type adminActivityRunner struct {
	base       Runner
	gate       *activityGate
	authorised bool
	calls      [][]string
}

func (r *adminActivityRunner) CheckAdministrator(context.Context) error {
	if r.authorised {
		return nil
	}
	return fixtureExit(1)
}
func (r *adminActivityRunner) AuthoriseAdministrator(ctx context.Context, _ io.Reader, _ io.Writer, diagnostics io.Writer) error {
	fmt.Fprint(diagnostics, "Password: ")
	if err := r.gate.wait(ctx); err != nil {
		return err
	}
	r.authorised = true
	return nil
}
func (r *adminActivityRunner) Run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	if path == "/usr/bin/sudo" {
		r.calls = append(r.calls, append([]string(nil), args...))
		if len(args) == 0 || args[0] != "-n" {
			return nil, fixtureExit(2)
		}
		args = args[1:]
	}
	return r.base.Run(ctx, path, args, input)
}
func TestAdministratorPromptPausesRenderingAndUsesNoninteractiveMutation(t *testing.T) {
	var a *App
	var base *lifecycleRunner
	a, base = lifecycleFixture(t)
	var gate *activityGate = newActivityGate()
	defer gate.open()
	var runner *adminActivityRunner = &adminActivityRunner{base: base, gate: gate}
	a.Runner = runner
	var log *activityLog = &activityLog{}
	a.Err = log
	a.progressInterval = 10 * time.Millisecond
	var result chan error = make(chan error, 1)
	go func() { result <- a.Run(context.Background(), "lock", []string{"1h"}) }()
	select {
	case <-gate.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("sudo authorisation was not requested")
	}
	var prompt string = log.snapshot()
	if !strings.Contains(prompt, "Waiting for administrator authorisation") || !strings.HasSuffix(prompt, "Password: ") {
		t.Fatalf("administrator prompt missing: %s", prompt)
	}
	time.Sleep(60 * time.Millisecond)
	if log.snapshot() != prompt {
		t.Fatal("progress repainted over the administrator prompt")
	}
	gate.open()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("authorised operation did not finish")
	}
	if len(runner.calls) == 0 {
		t.Fatal("no authorised mutation executed")
	}
	for _, args := range runner.calls {
		if args[0] != "-n" {
			t.Fatal("secret stdin could be consumed by interactive sudo")
		}
	}
	if strings.Contains(log.snapshot(), "b2xkcGFzcw==") || strings.Contains(log.snapshot(), string(base.rotated)) {
		t.Fatal("recovery secret leaked into authentication output")
	}
}

type interactiveHookActivity struct {
	base Runner
	gate *activityGate
}

func (r *interactiveHookActivity) Run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	return r.base.Run(ctx, path, args, input)
}
func (r *interactiveHookActivity) RunHook(ctx context.Context, _ string, _ []string, input io.Reader, output, diagnostics io.Writer) error {
	if input == nil {
		return fixtureExit(1)
	}
	fmt.Fprintln(output, "Hook output is streamed before completion")
	fmt.Fprint(diagnostics, "Hook input: ")
	var err error = r.gate.wait(ctx)
	fmt.Fprintln(diagnostics)
	return err
}
func TestInteractiveHookStreamsWhileActivityContinues(t *testing.T) {
	var a *App
	var base *lifecycleRunner
	a, base = lifecycleFixture(t)
	if err := os.WriteFile(a.path("pre-lock.sh"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	var gate *activityGate = newActivityGate()
	defer gate.open()
	a.Runner = &interactiveHookActivity{base: base, gate: gate}
	a.Options.Hooks = true
	a.progressInterval = 10 * time.Millisecond
	a.Options.Progress = "always"
	var log *activityLog = &activityLog{changed: make(chan struct{}, 1)}
	a.Out = log
	a.Err = log
	var result chan error = make(chan error, 1)
	go func() { result <- a.Run(context.Background(), "lock", []string{"1h"}) }()
	select {
	case <-gate.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("interactive hook did not start")
	}
	var during string = log.waitFor(t, "Wait for pre-lock hook pre-lock.sh", 3)
	if !strings.Contains(during, "Hook output is streamed before completion") || !strings.Contains(during, "Hook input: ") {
		t.Fatal("hook output was buffered or prompt was erased")
	}
	if strings.Count(during, "Wait for pre-lock hook pre-lock.sh") < 3 {
		t.Fatal("interactive hook heartbeat missing")
	}
	gate.open()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("interactive hook did not finish")
	}
}
func TestDryRunActivityDoesNotCreateOperationLock(t *testing.T) {
	var a *App
	var base *lifecycleRunner
	a, base = lifecycleFixture(t)
	a.Options.DryRun = true
	var gate *activityGate = newActivityGate()
	defer gate.open()
	a.Runner = &activityRunner{base: base, gate: gate, match: func(path string, args []string) bool { return path == "/usr/sbin/diskutil" && args[0] == "info" }}
	var before map[string]string = make(map[string]string)
	for _, name := range []string{"state.json", "passphrase.txt", "passphrase.sha256"} {
		var data []byte
		var err error
		data, err = os.ReadFile(a.path(name))
		if err != nil {
			t.Fatal(err)
		}
		before[name] = string(data)
	}
	var log *activityLog = &activityLog{changed: make(chan struct{}, 1)}
	a.Err = log
	a.progressInterval = 10 * time.Millisecond
	a.Options.Progress = "always"
	var result chan error = make(chan error, 1)
	go func() { result <- a.Run(context.Background(), "lock", []string{"1h"}) }()
	<-gate.entered
	log.waitFor(t, "Inspect APFS volume identity", 3)
	gate.open()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	for name, wanted := range before {
		var data []byte
		var err error
		data, err = os.ReadFile(a.path(name))
		if err != nil || string(data) != wanted {
			t.Fatal("dry-run changed protected storage")
		}
	}
	if _, err := os.Lstat(a.Config.Home + "/.vaultlock-operation.lock"); !os.IsNotExist(err) {
		t.Fatal("dry-run created coordination state")
	}
	for _, call := range base.calls {
		if call[0] == "/usr/bin/sudo" || (call[0] == "/usr/sbin/diskutil" && call[1] == "mount") {
			t.Fatal("dry-run executed a mutation")
		}
	}
}

func TestOutputFailureDuringPassphraseRotationCompletesSafeLock(t *testing.T) {
	var a *App
	var runner *lifecycleRunner
	a, runner = lifecycleFixture(t)
	var log *activityLog = &activityLog{}
	a.Err = log
	runner.before = func(path string, args []string) {
		if path == "/usr/bin/sudo" && strings.Contains(strings.Join(args, " "), "changePassphrase") {
			log.stop()
			fmt.Fprintln(a.Err, "presentation stopped")
		}
	}
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err == nil {
		t.Fatal("output failure not reported")
	}
	if !runner.info.Locked || runner.key != nil {
		t.Fatal("presentation failure interrupted the requested seal")
	}
	var state State
	var err error
	state, err = a.ReadState()
	if err != nil || !state.Locked {
		t.Fatal("locked state was not persisted", err)
	}
	for _, name := range []string{"passphrase.txt", "passphrase-new.txt"} {
		if _, err := os.Lstat(a.path(name)); !os.IsNotExist(err) {
			t.Fatalf("plaintext recovery retained solely because output failed: %s", name)
		}
	}
	if err = a.verifyPass(runner.rotated); err != nil {
		t.Fatal("durable recovery does not match rotated passphrase", err)
	}
	if a.storageChangesStarted {
		t.Fatal("mutation phase leaked across App.Run calls")
	}
}
func TestOutputFailureDuringInspectionStopsBeforeFirstMutation(t *testing.T) {
	var a *App
	var runner *lifecycleRunner
	a, runner = lifecycleFixture(t)
	var log *activityLog = &activityLog{}
	a.Err = log
	runner.before = func(path string, args []string) {
		if path == "/usr/bin/security" && args[0] == "find-generic-password" {
			log.stop()
			fmt.Fprintln(a.Err, "presentation stopped")
		}
	}
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err == nil {
		t.Fatal("pre-mutation output failure not reported")
	}
	if runner.info.Locked || len(runner.rotated) > 0 {
		t.Fatal("storage mutation began after preflight output failure")
	}
	for _, call := range runner.calls {
		if call[0] == "/usr/bin/sudo" {
			t.Fatal("mutating child began after preflight output failure")
		}
	}
	var pass []byte
	var err error
	pass, err = a.plaintext()
	if err != nil || string(pass) != "b2xkcGFzcw==" {
		t.Fatal("original recovery changed", err)
	}
}
