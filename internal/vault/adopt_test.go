package vault

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	progressengine "github.com/wolph/vaultlock/internal/progress"
	"golang.org/x/sys/unix"
	"howett.net/plist"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func requireAdoptPlatform(t *testing.T) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("native APFS metadata requires macOS")
	}
}

func TestAdoptManifestDetectsSameSizeContentChange(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var path string = filepath.Join(root, "data")
	{
		var err error
		err = os.WriteFile(path, []byte("spam"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	var first adoptManifest
	var err error
	first, err = buildAdoptManifest(context.Background(), root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, []byte("eggs"), 0600); err != nil {
		t.Fatal(err)
	}
	var second adoptManifest
	second, err = buildAdoptManifest(context.Background(), root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if first.Digest == second.Digest {
		t.Fatal("same-sized changed content escaped verification")
	}
}

func TestAdoptManifestRejectsExternalHardlinks(t *testing.T) {
	requireAdoptPlatform(t)
	var parent string = t.TempDir()
	var root string = filepath.Join(parent, "source")
	{
		var err error
		err = os.Mkdir(root, 0700)
		if err != nil {
			t.Fatal(err)
		}
	}
	var path string = filepath.Join(root, "data")
	{
		var err error
		err = os.WriteFile(path, []byte("spam"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = os.Link(path, filepath.Join(parent, "outside"))
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		_, err = buildAdoptManifest(context.Background(), root, nil)
		if err == nil {
			t.Fatal("external hardlink accepted")
		}
	}
}

func TestAdoptManifestPreservesHardlinkRelationships(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var path string = filepath.Join(root, "data")
	{
		var err error
		err = os.WriteFile(path, []byte("spam"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = os.Link(path, filepath.Join(root, "linked"))
		if err != nil {
			t.Fatal(err)
		}
	}
	var manifest adoptManifest
	var err error
	manifest, err = buildAdoptManifest(context.Background(), root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Entries[1].Hardlink != manifest.Entries[2].Hardlink {
		t.Fatal("hardlink group differs")
	}
}

func TestAdoptManifestRejectsSymlinkRoot(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var link string = filepath.Join(t.TempDir(), "source")
	{
		var err error
		err = os.Symlink(root, link)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		_, err = buildAdoptManifest(context.Background(), link, nil)
		if err == nil {
			t.Fatal("symlink root accepted")
		}
	}
}

type adoptBrokenWriter struct{}

func (adoptBrokenWriter) Write(_ []byte) (int, error) { return 0, io.ErrClosedPipe }

func TestAdoptProgressBrokenPipeIsPresentationOnly(t *testing.T) {
	var progress *adoptProgress = newAdoptProgress(adoptBrokenWriter{}, "always")
	progress.phase("Manifest source")
	progress.tick(4, "data")
	progress.finish()
}

func TestAdoptManifestCancelled(t *testing.T) {
	requireAdoptPlatform(t)
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithCancel(context.Background())
	cancel()
	{
		var err error
		_, err = buildAdoptManifest(ctx, t.TempDir(), nil)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("got %v", err)
		}
	}
}

type adoptFixtureRunner struct {
	mount               string
	source              string
	locked              bool
	unmounted           bool
	afterCopy           func()
	failAfterQuarantine bool
	afterQuarantine     func()
	afterSourceLinked   func()
}

func (runner *adoptFixtureRunner) Run(ctx context.Context, name string, args []string, _ []byte) ([]byte, error) {
	switch name {
	case "/usr/sbin/diskutil":
		if runner.afterSourceLinked != nil {
			var sourceInfo os.FileInfo
			var sourceErr error
			sourceInfo, sourceErr = os.Lstat(runner.source)
			if sourceErr == nil && sourceInfo.Mode()&os.ModeSymlink != 0 {
				runner.afterSourceLinked()
				runner.afterSourceLinked = nil
			}
		}
		if runner.afterQuarantine != nil {
			var sourceErr error
			_, sourceErr = os.Lstat(runner.source)
			if errors.Is(sourceErr, os.ErrNotExist) {
				runner.afterQuarantine()
				runner.afterQuarantine = nil
			}
		}
		if runner.failAfterQuarantine {
			{
				var err error
				_, err = os.Lstat(runner.source)
				if errors.Is(err, os.ErrNotExist) {
					return nil, errors.New("mount changed during quarantine")
				}
			}
		}
		var mount string = runner.mount
		if runner.unmounted {
			mount = ""
		}
		return plist.Marshal(map[string]any{"VolumeUUID": "fixture-uuid", "DeviceIdentifier": "disk99s1", "Locked": runner.locked, "MountPoint": mount, "FileVault": true, "FilesystemType": "apfs", "VolumeName": "vault"}, plist.XMLFormat)
	case "/usr/bin/security":
		return []byte("c3BhbQ==\n"), nil
	case "/usr/bin/ditto":
		var output []byte
		var err error
		output, err = exec.CommandContext(ctx, name, args...).CombinedOutput()
		if err == nil && runner.afterCopy != nil {
			runner.afterCopy()
		}
		return output, err
	default:
		return nil, fmt.Errorf("unexpected external operation: %s", name)
	}
}

func adoptFixture(t *testing.T) (*App, *adoptFixtureRunner, string, string) {
	t.Helper()
	requireAdoptPlatform(t)
	var base string = t.TempDir()
	var home string = filepath.Join(base, "home")
	var mount string = filepath.Join(base, "mount")
	var source string = filepath.Join(home, "spam")
	var state string = filepath.Join(home, ".vaultlock")
	{
		var path string
		for _, path = range []string{home, mount, source, state} {
			{
				var err error
				err = os.Mkdir(path, 0700)
				if err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	{
		var name string
		var value string
		for name, value = range map[string]string{
			"state.json":        `{"locked":false,"volume_uuid":"fixture-uuid","deadline":null,"deadline_epoch":null,"round":null}`,
			"passphrase.txt":    "c3BhbQ==\n",
			"passphrase.sha256": digest([]byte("c3BhbQ==")) + "\n",
		} {
			{
				var err error
				err = os.WriteFile(filepath.Join(state, name), []byte(value), 0600)
				if err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	{
		var err error
		err = os.WriteFile(filepath.Join(source, "data"), []byte("spam"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	var runner *adoptFixtureRunner = &adoptFixtureRunner{mount: mount, source: source}
	var app *App = New(Config{Home: home, StateDir: state, MountPoint: mount, Volume: "vault", Container: "disk99", User: "fixture", ConfirmDevice: "/dev/tty"})
	app.Runner = runner
	app.Out = io.Discard
	app.Err = adoptBrokenWriter{}
	app.Options.Yes = true
	app.Options.Progress = "always"
	return app, runner, source, filepath.Join(mount, "spam")
}

func TestAdoptTransactionUsesVerifiedCopyAndBrokenProgressPipe(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	{
		var err error
		err = os.Link(filepath.Join(source, "data"), filepath.Join(source, "linked"))
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = os.Symlink("data", filepath.Join(source, "link"))
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err != nil {
			t.Fatal(err)
		}
	}
	var target string
	var err error
	target, err = os.Readlink(source)
	destination, _ = filepath.EvalSymlinks(destination)
	if err != nil || target != destination {
		t.Fatalf("source link = %q, %v", target, err)
	}
	var content []byte
	content, err = os.ReadFile(filepath.Join(source, "data"))
	if err != nil || string(content) != "spam" {
		t.Fatalf("data = %q, %v", content, err)
	}
	var retained []string
	retained, err = filepath.Glob(filepath.Join(filepath.Dir(source), ".vaultlock-backup-*"))
	if err != nil || len(retained) != 0 {
		t.Fatalf("unexpected retained backup: %v, %v", retained, err)
	}
}

func TestAdoptRejectsCorruptCopyWithoutReplacingSource(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	var destination string
	app, runner, source, destination = adoptFixture(t)
	runner.afterCopy = func() {
		{
			var err error
			err = os.WriteFile(filepath.Join(destination, "data"), []byte("eggs"), 0600)
			if err != nil {
				t.Error(err)
			}
		}
	}
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err == nil {
			t.Fatal("corrupt copy accepted")
		}
	}
	var info os.FileInfo
	var err error
	info, err = os.Lstat(source)
	if err != nil || !info.IsDir() {
		t.Fatalf("source was replaced: %v, %v", info, err)
	}
}

func TestAdoptRejectsSourceMutationWithoutReplacingSource(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	app, runner, source, _ = adoptFixture(t)
	runner.afterCopy = func() {
		{
			var err error
			err = os.WriteFile(filepath.Join(source, "data"), []byte("eggs"), 0600)
			if err != nil {
				t.Error(err)
			}
		}
	}
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err == nil {
			t.Fatal("source mutation accepted")
		}
	}
	var content []byte
	var err error
	content, err = os.ReadFile(filepath.Join(source, "data"))
	if err != nil || string(content) != "eggs" {
		t.Fatalf("source mutation lost: %q, %v", content, err)
	}
}

func TestAdoptRollsBackMountFailureAfterQuarantine(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	app, runner, source, _ = adoptFixture(t)
	runner.failAfterQuarantine = true
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err == nil {
			t.Fatal("mount failure accepted")
		}
	}
	var info os.FileInfo
	var err error
	info, err = os.Lstat(source)
	if err != nil || !info.IsDir() {
		t.Fatalf("original source not restored: %v, %v", info, err)
	}
}

func TestAdoptRejectsUnmountedVault(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	app, runner, source, _ = adoptFixture(t)
	runner.unmounted = true
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err == nil {
			t.Fatal("unmounted vault accepted")
		}
	}
}

func TestAdoptRejectsDanglingDestination(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	{
		var err error
		err = os.Symlink("missing", destination)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err == nil {
			t.Fatal("dangling destination accepted")
		}
	}
}

func TestAdoptDeletionRejectsSameInodeMutation(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var path string = filepath.Join(root, "data")
	{
		var err error
		err = os.WriteFile(path, []byte("spam"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}
	var original adoptManifest
	var err error
	original, err = stableAdoptManifest(context.Background(), root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, []byte("eggs"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = removeAdoptOriginal(context.Background(), root, original, nil); err == nil {
		t.Fatal("mutated original removed")
	}
	if _, err = os.Lstat(path); err != nil {
		t.Fatalf("mutated original lost: %v", err)
	}
}

func TestAdoptPreservesExtendedAttributesAndACL(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	var path string = filepath.Join(source, "data")
	{
		var err error
		err = unix.Lsetxattr(path, "com.example.vaultlock", []byte("spam metadata"), 0)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var output []byte
		var err error
		output, err = exec.Command("/bin/chmod", "+a", "everyone allow read", path).CombinedOutput()
		if err != nil {
			t.Fatalf("fixture ACL: %v, %s", err, output)
		}
	}
	var original adoptManifest
	var err error
	original, err = stableAdoptManifest(context.Background(), source, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(original.Entries[1].Metadata.ACL) == 0 {
		t.Fatal("native manifest did not capture fixture ACL")
	}
	if err = app.adopt(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	if _, err = adoptMatchesManifest(context.Background(), destination, original, nil, false); err != nil {
		t.Fatal(err)
	}
}

func TestAdoptDryRunDoesNotCopyOrReplace(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	app.Options.DryRun = true
	{
		var err error
		err = app.adopt(context.Background(), source)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = adoptAbsent(destination)
		if err != nil {
			t.Fatal("dry run created destination")
		}
	}
	var info os.FileInfo
	var err error
	info, err = os.Lstat(source)
	if err != nil || !info.IsDir() {
		t.Fatal("dry run replaced source")
	}
}

func TestAdoptRejectsSourceContainingOperationLock(t *testing.T) {
	var app *App
	var source string
	app, _, source, _ = adoptFixture(t)
	var path string = filepath.Join(app.Config.Home, ".vaultlock-operation.lock")
	{
		var err error
		err = os.Mkdir(path, 0700)
		if err != nil {
			t.Fatal(err)
		}
	}
	{
		var err error
		err = app.adopt(context.Background(), path)
		if err == nil {
			t.Fatal("reserved operation lock accepted")
		}
	}
	{
		var err error
		_, err = os.Lstat(source)
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestAdoptProgressCarriesTotalsAndDoesNotCompleteOnAbort(t *testing.T) {
	var output bytes.Buffer
	var progress *adoptProgress = newAdoptProgress(&output, "always")
	progress.sourceBytes = 2048
	progress.sourceCount = 2
	progress.copyBytes = 2048
	progress.copyCount = 2
	progress.phase("Copy source into vault")
	progress.tick(1024, "data")
	progress.finish()
	var rendered string = output.String()
	if !strings.Contains(rendered, "50%") || !strings.Contains(rendered, "ETA") || !strings.Contains(rendered, "MiB/s") {
		t.Fatalf("missing progress details: %q", rendered)
	}
	if strings.Contains(rendered, "100%") {
		t.Fatalf("aborted operation marked complete: %q", rendered)
	}
}

func TestAdoptProgressAutoUsesPlainNonTerminalOutput(t *testing.T) {
	var output *os.File
	var err error
	output, err = os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	var progress *adoptProgress = newAdoptProgress(output, "auto")
	defer progress.finish()
	if progress.terminal || !progress.enabled {
		t.Fatal("auto mode must use plain heartbeats on a non-terminal")
	}
}

type adoptProgressCapture struct {
	mu      sync.Mutex
	data    []byte
	writes  int
	changed chan struct{}
}

func (writer *adoptProgressCapture) Write(data []byte) (int, error) {
	writer.mu.Lock()
	writer.data = append(writer.data, data...)
	writer.writes++
	writer.mu.Unlock()
	select {
	case writer.changed <- struct{}{}:
	default:
	}
	return len(data), nil
}

func (writer *adoptProgressCapture) snapshot() (string, int) {
	writer.mu.Lock()
	defer writer.mu.Unlock()
	return string(writer.data), writer.writes
}

func waitForAdoptHeartbeats(t *testing.T, writer *adoptProgressCapture, before int) string {
	t.Helper()
	var timeout *time.Timer = time.NewTimer(2500 * time.Millisecond)
	defer timeout.Stop()
	for {
		var text string
		var count int
		text, count = writer.snapshot()
		if count >= before+2 {
			return text
		}
		select {
		case <-writer.changed:
		case <-timeout.C:
			t.Fatalf("blocked work produced no independent heartbeats: %q", text)
		}
	}
}

type adoptBlockingHashReader struct {
	first   bool
	blocked chan struct{}
	release chan struct{}
}

func (reader *adoptBlockingHashReader) Read(buffer []byte) (int, error) {
	if !reader.first {
		reader.first = true
		return copy(buffer, []byte("spam")), nil
	}
	close(reader.blocked)
	<-reader.release
	return 0, io.EOF
}

func TestAdoptHashProgressUpdatesBeforeEOFAndWhileBlocked(t *testing.T) {
	var writer *adoptProgressCapture = &adoptProgressCapture{changed: make(chan struct{}, 32)}
	var progress *adoptProgress = newAdoptProgress(writer, "always")
	defer progress.finish()
	progress.sourceBytes = 1024
	progress.sourceCount = 1
	progress.phase("Hash large source")
	var reader *adoptBlockingHashReader = &adoptBlockingHashReader{blocked: make(chan struct{}), release: make(chan struct{})}
	var release sync.Once
	defer release.Do(func() { close(reader.release) })
	var done chan error = make(chan error, 1)
	go func() {
		var err error
		_, err = io.Copy(io.Discard, adoptContextReader{Context: context.Background(), Reader: reader, Progress: progress, Path: "large.bin"})
		done <- err
	}()
	select {
	case <-reader.blocked:
	case <-time.After(2 * time.Second):
		t.Fatal("hash reader did not block")
	}
	if progress.bytes != 4 {
		t.Fatalf("bytes only updated at file completion: %d", progress.bytes)
	}
	var before int
	_, before = writer.snapshot()
	var rendered string = waitForAdoptHeartbeats(t, writer, before)
	if !strings.Contains(rendered, "hash: large.bin") || !strings.Contains(rendered, "4 B") {
		t.Fatalf("missing live hash details: %q", rendered)
	}
	if strings.Contains(rendered, "100%") || strings.Contains(rendered, "\x1b") {
		t.Fatalf("blocked plain output falsely completed or contained ANSI: %q", rendered)
	}
	release.Do(func() { close(reader.release) })
	var readErr error
	select {
	case readErr = <-done:
		if readErr != nil {
			t.Fatal(readErr)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("hash reader did not finish")
	}
}

type adoptBlockingCopyRunner struct {
	entered chan struct{}
	release chan struct{}
}

func (runner *adoptBlockingCopyRunner) Run(_ context.Context, _ string, _ []string, _ []byte) ([]byte, error) {
	return nil, errors.New("unexpected fallback runner")
}
func (runner *adoptBlockingCopyRunner) RunAdoptCopy(ctx context.Context, _ []string, _ func(int64, string)) error {
	close(runner.entered)
	select {
	case <-runner.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func TestAdoptCopyHeartbeatContinuesWithoutDittoOutput(t *testing.T) {
	var writer *adoptProgressCapture = &adoptProgressCapture{changed: make(chan struct{}, 32)}
	var progress *adoptProgress = newAdoptProgress(writer, "always")
	defer progress.finish()
	progress.sourceBytes = 1024
	progress.sourceCount = 1
	progress.phase("Copy source into vault")
	var runner *adoptBlockingCopyRunner = &adoptBlockingCopyRunner{entered: make(chan struct{}), release: make(chan struct{})}
	var app *App = &App{Runner: runner}
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	var done chan error = make(chan error, 1)
	go func() { done <- app.copyAdopt(ctx, "source", "destination", progress) }()
	select {
	case <-runner.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("copy runner did not block")
	}
	var before int
	_, before = writer.snapshot()
	var rendered string = waitForAdoptHeartbeats(t, writer, before)
	if !strings.Contains(rendered, "Copy source into vault") || !strings.Contains(rendered, "copy: source") {
		t.Fatalf("missing blocked copy activity: %q", rendered)
	}
	cancel()
	var copyErr error
	select {
	case copyErr = <-done:
		if !errors.Is(copyErr, context.Canceled) {
			t.Fatalf("got %v", copyErr)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("copy did not cancel")
	}
	progress.finish()
	rendered, _ = writer.snapshot()
	if strings.Contains(rendered, "100%") {
		t.Fatalf("cancelled copy marked complete: %q", rendered)
	}
}

func TestAdoptLargeFileHashTracksEveryPassAndExactBytes(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var content []byte = bytes.Repeat([]byte("spam"), 768*1024)
	var err error = os.WriteFile(filepath.Join(root, "large.bin"), content, 0600)
	if err != nil {
		t.Fatal(err)
	}
	var progress *adoptProgress = newAdoptProgress(io.Discard, "never")
	defer progress.finish()
	progress.scan(context.Background(), root)
	progress.phasePasses("Verify source", 2)
	var manifest adoptManifest
	manifest, err = stableAdoptManifest(context.Background(), root, progress)
	if err != nil {
		t.Fatal(err)
	}
	if progress.bytes != int64(len(content))*2 || progress.count != 4 || progress.passNumber != 2 {
		t.Fatalf("incorrect hash accounting: bytes=%d entries=%d passes=%d", progress.bytes, progress.count, progress.passNumber)
	}
	var expected [32]byte = sha256.Sum256(content)
	if manifest.Entries[1].Payload != hex.EncodeToString(expected[:]) {
		t.Fatal("chunked hashing changed the manifest payload")
	}
}

func TestAdoptReusesSharedProgressDisplay(t *testing.T) {
	var owner *adoptProgress = newAdoptProgress(io.Discard, "never")
	defer owner.finish()
	var app *App = &App{display: owner.display, Options: Options{Progress: "auto"}}
	var adapter *adoptProgress = app.adoptionProgress()
	if adapter.display != owner.display || adapter.ownDisplay {
		t.Fatal("adoption started a second concurrent renderer")
	}
	adapter.phase("Hash source")
	adapter.finish()
	var task *progressengine.Task = owner.display.Begin("Other lifecycle work", 0, 0)
	task.Complete()
}

func TestAdoptRunOutputFailureDuringCopyCompletesSafely(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	var destination string
	app, runner, source, destination = adoptFixture(t)
	app.Err = io.Discard
	runner.afterCopy = func() {
		var writer io.Writer = app.display.Wrap(adoptBrokenWriter{})
		_, _ = writer.Write([]byte("progress failure"))
	}
	var err error = app.Run(context.Background(), "adopt", []string{source})
	if err == nil || !strings.Contains(err.Error(), "output failed") {
		t.Fatalf("expected reported presentation failure after safe completion, got %v", err)
	}
	var target string
	target, err = os.Readlink(source)
	destination, _ = filepath.EvalSymlinks(destination)
	if err != nil || target != destination {
		t.Fatalf("safe replacement missing after output failure: %q, %v", target, err)
	}
	var content []byte
	content, err = os.ReadFile(filepath.Join(source, "data"))
	if err != nil || string(content) != "spam" {
		t.Fatalf("copied content lost: %q, %v", content, err)
	}
}

func TestAdoptDittoCountersExcludeDirectoriesAndDuplicateHardlinkBytes(t *testing.T) {
	requireAdoptPlatform(t)
	var directoryOnly bool
	for _, directoryOnly = range []bool{true, false} {
		var root string = t.TempDir()
		var source string = filepath.Join(root, "source")
		var destination string = filepath.Join(root, "destination")
		var err error = os.MkdirAll(filepath.Join(source, "nested", "empty"), 0700)
		if err != nil {
			t.Fatal(err)
		}
		if !directoryOnly {
			err = os.WriteFile(filepath.Join(source, "data"), []byte("spam"), 0600)
			if err != nil {
				t.Fatal(err)
			}
			err = os.Link(filepath.Join(source, "data"), filepath.Join(source, "linked"))
			if err != nil {
				t.Fatal(err)
			}
			err = os.WriteFile(filepath.Join(source, "zero"), nil, 0600)
			if err != nil {
				t.Fatal(err)
			}
		}
		var manifest adoptManifest
		manifest, err = stableAdoptManifest(context.Background(), source, nil)
		if err != nil {
			t.Fatal(err)
		}
		var progress *adoptProgress = newAdoptProgress(io.Discard, "never")
		progress.manifestTotals(manifest)
		progress.phase("Copy source into vault")
		var app *App = &App{Runner: systemRunner{}}
		err = app.copyAdopt(context.Background(), source, destination, progress)
		if err != nil {
			progress.finish()
			t.Fatal(err)
		}
		if progress.bytes != progress.copyBytes || progress.count != progress.copyCount {
			progress.finish()
			t.Fatalf("ditto actual counters disagree: %d/%d bytes, %d/%d entries", progress.bytes, progress.copyBytes, progress.count, progress.copyCount)
		}
		if !directoryOnly && (progress.copyBytes != 4 || progress.copyCount != 3) {
			t.Fatalf("wrong measurable copy totals: bytes=%d entries=%d", progress.copyBytes, progress.copyCount)
		}
		progress.complete()
		progress.finish()
	}
}

func TestAdoptRunOutputFailureBeforeOriginalRemovalCompletesSafely(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	app, runner, source, _ = adoptFixture(t)
	app.Err = io.Discard
	runner.afterSourceLinked = func() {
		var writer io.Writer = app.display.Wrap(adoptBrokenWriter{})
		_, _ = writer.Write([]byte("progress failure at original removal"))
	}
	var err error = app.Run(context.Background(), "adopt", []string{source})
	if err == nil || !strings.Contains(err.Error(), "output failed") {
		t.Fatalf("expected presentation failure after safe completion, got %v", err)
	}
	var info os.FileInfo
	info, err = os.Lstat(source)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("source replacement missing: %v, %v", info, err)
	}
	var retained []string
	retained, err = filepath.Glob(filepath.Join(filepath.Dir(source), ".vaultlock-backup-*"))
	if err != nil || len(retained) != 0 {
		t.Fatalf("original removal abandoned due to cosmetic output: %v, %v", retained, err)
	}
}

func TestAdoptOriginalRemovalIgnoresOutputFailureAfterDeletionStarts(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var err error = os.WriteFile(filepath.Join(root, "first"), []byte("spam"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	err = os.WriteFile(filepath.Join(root, "second"), []byte("eggs"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	var manifest adoptManifest
	manifest, err = stableAdoptManifest(context.Background(), root, nil)
	if err != nil {
		t.Fatal(err)
	}
	var progress *adoptProgress = newAdoptProgress(io.Discard, "always")
	defer progress.finish()
	progress.manifestTotals(manifest)
	progress.phasePasses("Remove verified original", 1)
	var app *App = &App{display: progress.display, storageChangesStarted: true}
	var poisoned bool
	progress.check = func() error {
		if progress.count > 0 && !poisoned {
			var writer io.Writer = progress.display.Wrap(adoptBrokenWriter{})
			_, _ = writer.Write([]byte("progress failure after first original unlink"))
			poisoned = true
		}
		return app.beforeMutation()
	}
	err = removeAdoptOriginal(context.Background(), root, manifest, progress)
	if err != nil {
		t.Fatal(err)
	}
	if !poisoned || progress.display.Err() == nil {
		t.Fatal("test did not inject failure during original removal")
	}
	_, err = os.Lstat(root)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("verified original removal was abandoned: %v", err)
	}
}
