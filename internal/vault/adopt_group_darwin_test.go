//go:build darwin

package vault

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"

	"golang.org/x/sys/unix"
)

func TestAdoptPreservesForeignGroupWithCachedAdministratorAuthorisation(t *testing.T) {
	if os.Getenv("VAULTLOCK_TEST_PRIVILEGED_GROUP") != "1" || os.Getuid() == 0 {
		t.Skip("requires explicit privileged group test and a non-root user")
	}
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	var path string
	for _, path = range []string{source, filepath.Join(source, "data")} {
		var file *os.File
		var err error
		file, err = os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		var command *exec.Cmd = exec.Command("/usr/bin/sudo", "-n", "--", "/usr/sbin/chown", "-n", strconv.Itoa(os.Getuid())+":0", "/dev/fd/0")
		command.Stdin = file
		err = command.Run()
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := app.adopt(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	for _, path = range []string{destination, filepath.Join(destination, "data")} {
		var actual unix.Stat_t
		if err := unix.Lstat(path, &actual); err != nil {
			t.Fatal(err)
		}
		if actual.Uid != uint32(os.Getuid()) || actual.Gid != 0 {
			t.Fatalf("foreign group was not preserved on %q", path)
		}
	}
	var actual string
	var err error
	destination, err = filepath.EvalSymlinks(destination)
	if err != nil {
		t.Fatal(err)
	}
	actual, err = os.Readlink(source)
	if err != nil || actual != destination {
		t.Fatalf("adoption did not complete: %v", err)
	}
}
