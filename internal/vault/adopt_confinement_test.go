package vault

import (
	"context"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"testing"
)

func TestAdoptMetadataCannotFollowReplacedIntermediateDirectory(t *testing.T) {
	var app *App
	var runner *adoptFixtureRunner
	var source string
	var destination string
	app, runner, source, destination = adoptFixture(t)
	var err error = os.Mkdir(filepath.Join(source, "nested"), 0700)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(source, "nested", "data"), []byte("source"), 0600); err != nil {
		t.Fatal(err)
	}
	var outside string = t.TempDir()
	var other string = filepath.Join(outside, "data")
	if err = os.WriteFile(other, []byte("unrelated"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = unix.Lsetxattr(other, "com.example.keep", []byte("preserve"), 0); err != nil {
		t.Fatal(err)
	}
	runner.afterCopy = func() {
		if err = os.Rename(filepath.Join(destination, "nested"), filepath.Join(destination, "saved-nested")); err != nil {
			t.Fatal(err)
		}
		if err = os.Symlink(outside, filepath.Join(destination, "nested")); err != nil {
			t.Fatal(err)
		}
	}
	if err = app.adopt(context.Background(), source); err == nil {
		t.Fatal("adopt accepted replaced intermediate directory")
	}
	var size int
	size, err = unix.Lgetxattr(other, "com.example.keep", nil)
	if err != nil || size != len("preserve") {
		t.Fatalf("metadata restoration modified unrelated outside file: size%d, error%v", size, err)
	}
}

func TestAdoptDestinationSwapDoesNotMutateOutsideMetadata(t *testing.T) {
	requireAdoptPlatform(t)
	var app *App
	var runner *adoptFixtureRunner
	var source string
	var destination string
	app, runner, source, destination = adoptFixture(t)
	var outside string = t.TempDir()
	var outsideFile string = filepath.Join(outside, "data")
	var err error = os.WriteFile(outsideFile, []byte("valuable"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	err = unix.Lsetxattr(outsideFile, "com.example.keep", []byte("precious"), 0)
	if err != nil {
		t.Fatal(err)
	}
	runner.afterCopy = func() {
		var swapErr error = os.Rename(destination, destination+".retained-copy")
		if swapErr == nil {
			swapErr = os.Symlink(outside, destination)
		}
		if swapErr != nil {
			t.Error(swapErr)
		}
	}
	err = app.adopt(context.Background(), source)
	if err == nil {
		t.Fatal("destination symlink swap accepted")
	}
	var buffer []byte = make([]byte, 64)
	var size int
	size, err = unix.Lgetxattr(outsideFile, "com.example.keep", buffer)
	if err != nil {
		t.Fatalf("outside copy metadata was modified: %v", err)
	}
	if string(buffer[:size]) != "precious" {
		t.Fatalf("outside copy metadata was modified: value%q", buffer[:size])
	}
}

func TestAdoptHardlinkSubstitutionDoesNotMutateOutsideMetadata(t *testing.T) {
	requireAdoptPlatform(t)
	var app *App
	var runner *adoptFixtureRunner
	var source string
	var destination string
	app, runner, source, destination = adoptFixture(t)
	var err error = os.Link(filepath.Join(source, "data"), filepath.Join(source, "linked"))
	if err != nil {
		t.Fatal(err)
	}
	var outsideFile string = filepath.Join(t.TempDir(), "data")
	err = os.WriteFile(outsideFile, []byte("valuable"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	err = unix.Lsetxattr(outsideFile, "com.example.keep", []byte("precious"), 0)
	if err != nil {
		t.Fatal(err)
	}
	runner.afterCopy = func() {
		var swapErr error = os.Remove(filepath.Join(destination, "linked"))
		if swapErr == nil {
			swapErr = os.Link(outsideFile, filepath.Join(destination, "linked"))
		}
		if swapErr != nil {
			t.Error(swapErr)
		}
	}
	err = app.adopt(context.Background(), source)
	if err == nil {
		t.Fatal("outside hardlink substitution accepted")
	}
	var buffer []byte = make([]byte, 64)
	var size int
	size, err = unix.Lgetxattr(outsideFile, "com.example.keep", buffer)
	if err != nil {
		t.Fatalf("outside hardlinked metadata was modified: %v", err)
	}
	if string(buffer[:size]) != "precious" {
		t.Fatalf("outside hardlinked metadata changed: %q", buffer[:size])
	}
}
