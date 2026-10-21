//go:build darwin

package vault

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

func adoptOpenMetadataFile(rooted *os.Root, path string) (*os.File, error) {
	var parent *os.File
	var err error
	parent, err = rooted.OpenFile(filepath.Dir(path), os.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	// Root.OpenFile follows leaf symlinks. Pin the parent within the root and
	// open the leaf itself with Darwin's O_SYMLINK before using its descriptor.
	var descriptor int
	descriptor, err = unix.Openat(int(parent.Fd()), filepath.Base(path), os.O_RDONLY|unix.O_NONBLOCK|unix.O_SYMLINK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(descriptor), path), nil
}

func adoptCheckCopyFile(file *os.File, wanted adoptMetadata, device uint64) (adoptCopyIdentity, error) {
	var actual unix.Stat_t
	if err := unix.Fstat(int(file.Fd()), &actual); err != nil {
		return adoptCopyIdentity{}, err
	}
	if uint64(actual.Dev) != device || actual.Mode&0170000 != wanted.Mode&0170000 {
		return adoptCopyIdentity{}, errors.New("copied entry type or filesystem changed before metadata restoration")
	}
	if actual.Mode&0170000 == 0100000 && uint64(actual.Nlink) != wanted.Nlink {
		return adoptCopyIdentity{}, errors.New("copied file hardlinks changed before metadata restoration")
	}
	return adoptCopyIdentity{Device: uint64(actual.Dev), Inode: actual.Ino}, nil
}

func adoptFileXattrNames(file *os.File) ([]string, error) {
	var size int
	var err error
	size, err = unix.Flistxattr(int(file.Fd()), nil)
	if err != nil || size == 0 {
		return nil, err
	}
	var names []byte = make([]byte, size)
	size, err = unix.Flistxattr(int(file.Fd()), names)
	if err != nil {
		return nil, err
	}
	if size == 0 {
		return nil, nil
	}
	if names[size-1] != 0 {
		return nil, errors.New("invalid descriptor extended attribute listing")
	}
	return strings.Split(string(names[:size-1]), "\x00"), nil
}

func adoptRestoreFileXattrs(file *os.File, wanted []adoptXattr) error {
	var actual []string
	var err error
	actual, err = adoptFileXattrNames(file)
	if err != nil {
		return err
	}
	var names map[string]bool = make(map[string]bool, len(wanted))
	var attribute adoptXattr
	for _, attribute = range wanted {
		names[attribute.Name] = true
	}
	var name string
	for _, name = range actual {
		if name == "com.apple.provenance" {
			continue
		}
		if !names[name] {
			if err = unix.Fremovexattr(int(file.Fd()), name); err != nil {
				return err
			}
		}
	}
	for _, attribute = range wanted {
		if attribute.Name == "com.apple.provenance" {
			continue
		}
		if err = adoptSetFileXattr(file, attribute); err != nil {
			return err
		}
	}
	return nil
}

func adoptSetFileXattr(file *os.File, wanted adoptXattr) error {
	var size int
	var err error
	size, err = unix.Fgetxattr(int(file.Fd()), wanted.Name, nil)
	if err != nil && !errors.Is(err, unix.ENOATTR) {
		return err
	}
	if err == nil && size == len(wanted.Value) {
		var current []byte = make([]byte, size)
		size, err = unix.Fgetxattr(int(file.Fd()), wanted.Name, current)
		if err != nil {
			return err
		}
		if bytes.Equal(current[:size], wanted.Value) {
			return nil
		}
	}
	return unix.Fsetxattr(int(file.Fd()), wanted.Name, wanted.Value, 0)
}

func adoptSetFileAttributes(file *os.File, attrs unix.Attrlist, buffer []byte) error {
	var errno syscall.Errno
	_, _, errno = syscall.Syscall6(unix.SYS_FSETATTRLIST, file.Fd(), uintptr(unsafe.Pointer(&attrs)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)), 0, 0)
	runtime.KeepAlive(file)
	if errno != 0 {
		return errno
	}
	return nil
}

func adoptRestoreCopyMetadataFile(file *os.File, metadata adoptMetadata) error {
	if err := adoptRestoreFileXattrs(file, metadata.Xattrs); err != nil {
		return err
	}
	var acl []byte = metadata.ACL
	if len(acl) == 0 {
		// Darwin represents removal with kauth_filesec and KAUTH_FILESEC_NOACL.
		acl = make([]byte, 44)
		binary.LittleEndian.PutUint32(acl[:4], 0x012cc16d)
		binary.LittleEndian.PutUint32(acl[36:40], ^uint32(0))
	}
	var attrs unix.Attrlist = unix.Attrlist{Bitmapcount: 5, Commonattr: unix.ATTR_CMN_EXTENDED_SECURITY}
	var buffer []byte = make([]byte, 8+len(acl))
	binary.LittleEndian.PutUint32(buffer[:4], 8)
	binary.LittleEndian.PutUint32(buffer[4:8], uint32(len(acl)))
	copy(buffer[8:], acl)
	return adoptSetFileAttributes(file, attrs, buffer)
}

func adoptRestoreCopyTimesFile(file *os.File, metadata adoptMetadata) error {
	var attrs unix.Attrlist = unix.Attrlist{Bitmapcount: 5, Commonattr: unix.ATTR_CMN_CRTIME | unix.ATTR_CMN_MODTIME}
	var buffer []byte = make([]byte, 32)
	var values []int64 = []int64{metadata.BirthSec, metadata.BirthNS, metadata.MtimeSec, metadata.MtimeNS}
	var index int
	var value int64
	for index, value = range values {
		binary.LittleEndian.PutUint64(buffer[index*8:], uint64(value))
	}
	return adoptSetFileAttributes(file, attrs, buffer)
}
