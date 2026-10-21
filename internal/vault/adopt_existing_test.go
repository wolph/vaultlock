package vault

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func copyExistingAdoptFixture(t *testing.T, source string, destination string) {
	t.Helper()
	var output []byte
	var err error
	output, err = exec.Command("/usr/bin/ditto", "--rsrc", "--extattr", "--acl", source, destination).CombinedOutput()
	if err != nil {
		t.Fatalf("copy fixture: %v, %s", err, output)
	}
	var paths []string
	err = filepath.WalkDir(source, func(path string, _ fs.DirEntry, walkErr error) error {
		paths = append(paths, path)
		return walkErr
	})
	if err != nil {
		t.Fatal(err)
	}
	var index int
	for index = len(paths) - 1; index >= 0; index-- {
		var relative string
		relative, err = filepath.Rel(source, paths[index])
		if err == nil {
			err = adoptRestoreTimes(paths[index], filepath.Join(destination, relative))
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestAdoptReusesVerifiedExistingDestination(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	copyExistingAdoptFixture(t, source, destination)
	var before adoptMetadata
	var err error
	before, err = adoptStat(filepath.Join(destination, "data"))
	if err != nil {
		t.Fatal(err)
	}
	if err = app.adopt(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	destination, err = filepath.EvalSymlinks(destination)
	if err != nil {
		t.Fatal(err)
	}
	var target string
	target, err = os.Readlink(source)
	if err != nil || target != destination {
		t.Fatalf("verified copy not adopted: target=%q, error=%v", target, err)
	}
	var after adoptMetadata
	after, err = adoptStat(filepath.Join(destination, "data"))
	if err != nil || !adoptIdentityEqual(before, after) {
		t.Fatalf("existing verified file was replaced: %v", err)
	}
	var content []byte
	content, err = os.ReadFile(filepath.Join(source, "data"))
	if err != nil || string(content) != "spam" {
		t.Fatalf("adopted data=%q, error=%v", content, err)
	}
}

func TestAdoptExistingDestinationUsesSourceAndPreservesPreviousCopy(t *testing.T) {
	var kind string
	for _, kind = range []string{"missing", "extra", "content", "metadata", "type"} {
		t.Run(kind, func(t *testing.T) {
			var app *App
			var source string
			var destination string
			app, _, source, destination = adoptFixture(t)
			copyExistingAdoptFixture(t, source, destination)
			var path string = filepath.Join(destination, "data")
			var err error
			switch kind {
			case "missing":
				err = os.Remove(path)
			case "extra":
				err = os.WriteFile(filepath.Join(destination, "extra"), []byte("eggs"), 0600)
			case "content":
				err = os.WriteFile(path, []byte("eggs"), 0600)
				if err == nil {
					err = adoptRestoreTimes(filepath.Join(source, "data"), path)
				}
			case "metadata":
				err = os.Chmod(path, 0644)
			case "type":
				err = os.Remove(path)
				if err == nil {
					err = os.Mkdir(path, 0700)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			var before adoptManifest
			before, err = stableAdoptManifest(context.Background(), destination, nil)
			if err != nil {
				t.Fatal(err)
			}
			err = app.adopt(context.Background(), source)
			if err != nil {
				t.Fatal(err)
			}
			var info os.FileInfo
			info, err = os.Lstat(source)
			if err != nil || info.Mode()&os.ModeSymlink == 0 {
				t.Fatalf("verified source was not replaced with a symlink: %v", err)
			}
			var content []byte
			content, err = os.ReadFile(filepath.Join(source, "data"))
			if err != nil || string(content) != "spam" {
				t.Fatalf("source content changed: %q, %v", content, err)
			}
			var backups []string
			backups, err = filepath.Glob(filepath.Join(app.Config.MountPoint, ".vaultlock-adopt-backup-*", "original"))
			if err != nil || len(backups) != 1 {
				t.Fatalf("previous destination not retained: %v, %v", backups, err)
			}
			if _, err = adoptMatchesManifest(context.Background(), backups[0], before, nil, true); err != nil {
				t.Fatalf("previous destination data or metadata changed: %v", err)
			}
			if _, err = os.Lstat(filepath.Join(destination, "extra")); !os.IsNotExist(err) {
				t.Fatalf("destination-only entry remains in authoritative copy: %v", err)
			}
		})
	}
}

func TestAdoptExistingDestinationCancellationDoesNotStageOrReplace(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	copyExistingAdoptFixture(t, source, destination)
	if err := os.WriteFile(filepath.Join(destination, "data"), []byte("eggs"), 0600); err != nil {
		t.Fatal(err)
	}
	app.Options.Yes = false
	app.Confirm = bytes.NewBufferString("no\n")
	if err := app.adopt(context.Background(), source); err == nil {
		t.Fatal("declined adoption succeeded")
	}
	var content []byte
	var err error
	content, err = os.ReadFile(filepath.Join(destination, "data"))
	if err != nil || string(content) != "eggs" {
		t.Fatalf("declined adoption changed destination: %q, %v", content, err)
	}
	var backups []string
	backups, err = filepath.Glob(filepath.Join(app.Config.MountPoint, ".vaultlock-adopt-backup-*"))
	if err != nil || len(backups) != 0 {
		t.Fatalf("declined adoption staged data: %v, %v", backups, err)
	}
}

func TestAdoptResumeLaterFailureRetainsSourceAndPreviousCopy(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	var destination string
	app, runner, source, destination = adoptFixture(t)
	copyExistingAdoptFixture(t, source, destination)
	if err := os.WriteFile(filepath.Join(destination, "data"), []byte("eggs"), 0600); err != nil {
		t.Fatal(err)
	}
	runner.failAfterQuarantine = true
	var failure error = app.adopt(context.Background(), source)
	if failure == nil {
		t.Fatal("failure after source quarantine was ignored")
	}
	var info os.FileInfo
	var err error
	info, err = os.Lstat(source)
	if err != nil || !info.IsDir() {
		t.Fatalf("source was not restored: %v", err)
	}
	var backups []string
	backups, err = filepath.Glob(filepath.Join(app.Config.MountPoint, ".vaultlock-adopt-backup-*", "original"))
	if err != nil || len(backups) != 1 {
		t.Fatalf("previous copy was not retained: %v, %v", backups, err)
	}
	var canonical string
	canonical, err = filepath.EvalSymlinks(filepath.Dir(backups[0]))
	if err != nil || !strings.Contains(failure.Error(), canonical) {
		t.Fatalf("failure did not identify retained backup: %v", failure)
	}
	var content []byte
	content, err = os.ReadFile(filepath.Join(backups[0], "data"))
	if err != nil || string(content) != "eggs" {
		t.Fatalf("previous data changed: %q, %v", content, err)
	}
	content, err = os.ReadFile(filepath.Join(source, "data"))
	if err != nil || string(content) != "spam" {
		t.Fatalf("authoritative source changed: %q, %v", content, err)
	}
}

func TestAdoptExistingDestinationRejectsChangeAtConfirmation(t *testing.T) {
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	copyExistingAdoptFixture(t, source, destination)
	app.Options.Yes = false
	var confirmed bool
	app.Confirm = adoptMutationReader{mutate: func() {
		confirmed = true
		var err error = os.WriteFile(filepath.Join(destination, "data"), []byte("eggs"), 0600)
		if err != nil {
			t.Fatal(err)
		}
	}, input: bytes.NewBufferString("yes\n")}
	if err := app.adopt(context.Background(), source); err == nil {
		t.Fatal("destination change during confirmation accepted")
	}
	if !confirmed {
		t.Fatal("adoption never reached confirmation")
	}
	var info os.FileInfo
	var err error
	info, err = os.Lstat(source)
	if err != nil || !info.IsDir() {
		t.Fatalf("source replaced after destination changed: %v", err)
	}
}

type adoptMutationReader struct {
	mutate func()
	input  *bytes.Buffer
}

func (reader adoptMutationReader) Read(buffer []byte) (int, error) {
	reader.mutate()
	return reader.input.Read(buffer)
}
