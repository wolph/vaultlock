//go:build darwin

package vault

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

func adoptCloneFile(input *os.File, target *os.Root, path string) (bool, error) {
	var parent *os.File
	var err error
	parent, err = target.OpenFile(filepath.Dir(path), os.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		return false, err
	}
	defer parent.Close()
	err = unix.Fclonefileat(int(input.Fd()), int(parent.Fd()), filepath.Base(path), 0)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EXDEV) || errors.Is(err, unix.ENOSYS) {
		if _, statErr := target.Lstat(path); errors.Is(statErr, os.ErrNotExist) {
			return false, nil
		}
	}
	return false, err
}

func adoptRestoreCopyPOSIXFile(ctx context.Context, file *os.File, wanted adoptMetadata) error {
	var actual unix.Stat_t
	if err := unix.Fstat(int(file.Fd()), &actual); err != nil {
		return err
	}
	if actual.Uid != wanted.UID || actual.Gid != wanted.GID {
		if err := unix.Fchown(int(file.Fd()), int(wanted.UID), int(wanted.GID)); err != nil {
			if !errors.Is(err, unix.EPERM) || actual.Uid != wanted.UID || wanted.UID != uint32(os.Getuid()) {
				return err
			}
			if err = adoptRestorePrivilegedGroup(ctx, file, wanted); err != nil {
				return err
			}
		}
	}
	if actual.Mode&07777 != wanted.Mode&07777 || actual.Uid != wanted.UID || actual.Gid != wanted.GID {
		if err := unix.Fchmod(int(file.Fd()), uint32(wanted.Mode&07777)); err != nil {
			return err
		}
	}
	return nil
}

func adoptRestorePrivilegedGroup(ctx context.Context, file *os.File, wanted adoptMetadata) error {
	// Standard input preserves the pinned descriptor through sudo. No pathname
	// from the copied tree is resolved by the privileged command.
	var ownership string = strconv.FormatUint(uint64(wanted.UID), 10) + ":" + strconv.FormatUint(uint64(wanted.GID), 10)
	var command *exec.Cmd = exec.CommandContext(ctx, "/usr/bin/sudo", "-n", "--", "/usr/sbin/chown", "-n", ownership, "/dev/fd/0")
	command.Stdin = file
	if wanted.Mode&0170000 == 0120000 {
		// sudo's terminal setup cannot duplicate Darwin symlink descriptors.
		command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	}
	var output []byte
	var err error
	output, err = command.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if wanted.Mode&0170000 == 0120000 {
			return fmt.Errorf("preserving symlink group %d requires administrator authorisation without a terminal. Its detached session may not share your terminal's sudo credentials. Source remains intact: %w (%s)", wanted.GID, err, output)
		}
		return fmt.Errorf("preserving group %d requires administrator authorisation. Run sudo -v before retrying adopt. Source remains intact: %w (%s)", wanted.GID, err, output)
	}
	var actual unix.Stat_t
	if err = unix.Fstat(int(file.Fd()), &actual); err != nil {
		return err
	}
	if actual.Uid != wanted.UID || actual.Gid != wanted.GID {
		return errors.New("privileged group restoration did not preserve the requested ownership")
	}
	return nil
}

func adoptRestoreCopyFlagsFile(file *os.File, wanted adoptMetadata) error {
	var actual unix.Stat_t
	if err := unix.Fstat(int(file.Fd()), &actual); err != nil {
		return err
	}
	if actual.Flags != wanted.Flags {
		return unix.Fchflags(int(file.Fd()), int(wanted.Flags))
	}
	return nil
}

func adoptRenamePinned(source *os.Root, name string, target *os.Root, destination string) error {
	var input *os.File
	var output *os.File
	var err error
	input, err = source.OpenFile(".", os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err = target.OpenFile(".", os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer output.Close()
	var from *byte
	var to *byte
	from, err = unix.BytePtrFromString(name)
	if err != nil {
		return err
	}
	to, err = unix.BytePtrFromString(destination)
	if err != nil {
		return err
	}
	var errno syscall.Errno
	_, _, errno = syscall.Syscall6(unix.SYS_RENAMEATX_NP, input.Fd(), uintptr(unsafe.Pointer(from)), output.Fd(), uintptr(unsafe.Pointer(to)), 4, 0)
	runtime.KeepAlive(input)
	runtime.KeepAlive(output)
	runtime.KeepAlive(from)
	runtime.KeepAlive(to)
	if errno != 0 {
		return errno
	}
	return nil
}
