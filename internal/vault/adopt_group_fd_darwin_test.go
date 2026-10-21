//go:build darwin

package vault

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestAdoptPrivilegedGroupSymlinkFDDoesNotTouchTarget(t *testing.T) {
	if os.Getenv("VAULTLOCK_TEST_PRIVILEGED_GROUP") != "1" || os.Getuid() == 0 {
		t.Skip("requires explicit privileged group test and a non-root user")
	}
	var directory string = t.TempDir()
	var outside string = filepath.Join(directory, "outside")
	var link string = filepath.Join(directory, "link")
	if err := os.WriteFile(outside, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	var before unix.Stat_t
	if err := unix.Lstat(outside, &before); err != nil {
		t.Fatal(err)
	}
	if before.Gid == 0 {
		t.Skip("fixture already belongs to requested group")
	}
	var root *os.Root
	var err error
	root, err = os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	var file *os.File
	file, err = adoptOpenMetadataFile(root, "link")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var wanted adoptMetadata
	wanted, err = adoptStat(link)
	if err != nil {
		t.Fatal(err)
	}
	wanted.GID = 0
	var restoreErr error = adoptRestoreCopyPOSIXFile(context.Background(), file, wanted)
	var after unix.Stat_t
	if err = unix.Lstat(outside, &after); err != nil {
		t.Fatal(err)
	}
	if before.Uid != after.Uid || before.Gid != after.Gid {
		t.Fatalf("privileged symlink FD changed target ownership: uid %d->%d gid %d->%d, restore result %v", before.Uid, after.Uid, before.Gid, after.Gid, restoreErr)
	}
	if restoreErr != nil {
		t.Fatalf("symlink fd restoration: %v", restoreErr)
	}
	var actual unix.Stat_t
	if err = unix.Lstat(link, &actual); err != nil {
		t.Fatal(err)
	}
	if actual.Gid != 0 {
		t.Fatal("symlink itself did not receive requested group")
	}
}

func TestAdoptPrivilegedGroupCancelledBeforeSpawnDoesNotChangeFile(t *testing.T) {
	var path string = filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	var file *os.File
	var err error
	file, err = os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var wanted adoptMetadata
	wanted, err = adoptStat(path)
	if err != nil {
		t.Fatal(err)
	}
	var original uint32 = wanted.GID
	wanted.GID = 0
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithCancel(context.Background())
	cancel()
	if err = adoptRestorePrivilegedGroup(ctx, file, wanted); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled helper error: %v", err)
	}
	var actual unix.Stat_t
	if err = unix.Fstat(int(file.Fd()), &actual); err != nil {
		t.Fatal(err)
	}
	if actual.Gid != original {
		t.Fatal("cancelled group helper changed file")
	}
}
