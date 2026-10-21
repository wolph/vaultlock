//go:build darwin

package vault

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"runtime"
	"sort"
	"syscall"
	"unicode/utf8"
	"unsafe"

	"golang.org/x/sys/unix"
)

func adoptNativeMetadata(path string, info os.FileInfo) (adoptMetadata, error) {
	var stat *syscall.Stat_t
	var ok bool
	stat, ok = info.Sys().(*syscall.Stat_t)
	if !ok {
		return adoptMetadata{}, errors.New("file identity unavailable")
	}
	var result adoptMetadata = adoptMetadata{
		Device: uint64(stat.Dev), Inode: stat.Ino, Mode: stat.Mode, UID: stat.Uid, GID: stat.Gid,
		Size: stat.Size, Nlink: uint64(stat.Nlink), Flags: stat.Flags,
		MtimeSec: stat.Mtimespec.Sec, MtimeNS: stat.Mtimespec.Nsec,
		BirthSec: stat.Birthtimespec.Sec, BirthNS: stat.Birthtimespec.Nsec,
		CtimeSec: stat.Ctimespec.Sec, CtimeNS: stat.Ctimespec.Nsec,
	}
	if result.Flags&(unix.UF_APPEND|unix.UF_IMMUTABLE|unix.SF_APPEND|unix.SF_IMMUTABLE|unix.UF_COMPRESSED) != 0 {
		return result, fmt.Errorf("unsupported immutable, append-only or compressed flags on %s", path)
	}
	var err error
	result.ACL, err = adoptACL(path)
	if err != nil {
		return result, fmt.Errorf("read ACL for %s: %w", path, err)
	}
	result.Xattrs, err = adoptXattrs(path)
	return result, err
}

func adoptACL(path string) ([]byte, error) {
	var name *byte
	var err error
	name, err = unix.BytePtrFromString(path)
	if err != nil {
		return nil, err
	}
	var attrs unix.Attrlist = unix.Attrlist{Bitmapcount: 5, Commonattr: unix.ATTR_CMN_EXTENDED_SECURITY}
	var buffer []byte = make([]byte, 65536)
	var errno syscall.Errno
	_, _, errno = syscall.Syscall6(unix.SYS_GETATTRLIST, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&attrs)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)), unix.FSOPT_NOFOLLOW, 0)
	runtime.KeepAlive(name)
	if errno != 0 {
		return nil, errno
	}
	var length uint32 = binary.LittleEndian.Uint32(buffer[:4])
	if length < 12 || length > uint32(len(buffer)) {
		return nil, errors.New("invalid ACL attribute length")
	}
	var offset int64 = int64(int32(binary.LittleEndian.Uint32(buffer[4:8]))) + 4
	var size int64 = int64(binary.LittleEndian.Uint32(buffer[8:12]))
	if size == 0 {
		return nil, nil
	}
	if offset < 12 || offset+size > int64(length) {
		return nil, errors.New("invalid ACL attribute reference")
	}
	return append([]byte(nil), buffer[offset:offset+size]...), nil
}

func adoptXattrs(path string) ([]adoptXattr, error) {
	var size int
	var err error
	size, err = unix.Llistxattr(path, nil)
	if err != nil {
		return nil, fmt.Errorf("list extended attributes for %s: %w", path, err)
	}
	var names []byte = make([]byte, size)
	if size > 0 {
		size, err = unix.Llistxattr(path, names)
		if err != nil {
			return nil, err
		}
		names = names[:size]
	}
	var result []adoptXattr
	var start int
	var index int
	var value byte
	for index, value = range names {
		if value != 0 {
			continue
		}
		var name string = string(names[start:index])
		if !utf8.ValidString(name) {
			return nil, fmt.Errorf("cannot safely archive a non-UTF-8 extended attribute name on %s", path)
		}
		start = index + 1
		size, err = unix.Lgetxattr(path, name, nil)
		if err != nil {
			return nil, err
		}
		var value []byte = make([]byte, size)
		if size > 0 {
			size, err = unix.Lgetxattr(path, name, value)
			if err != nil {
				return nil, err
			}
			value = value[:size]
		}
		result = append(result, adoptXattr{Name: name, Value: value})
	}
	if start != len(names) {
		return nil, errors.New("invalid extended attribute listing")
	}
	sort.Slice(result, func(left int, right int) bool { return result[left].Name < result[right].Name })
	return result, nil
}

func adoptRestoreTimes(source string, destination string) error {
	var stat unix.Stat_t
	var err error = unix.Lstat(source, &stat)
	if err != nil {
		return err
	}
	var attrs unix.Attrlist = unix.Attrlist{Bitmapcount: 5, Commonattr: unix.ATTR_CMN_CRTIME | unix.ATTR_CMN_MODTIME | unix.ATTR_CMN_ACCTIME}
	var times []byte = make([]byte, 48)
	var values []int64 = []int64{stat.Btim.Sec, stat.Btim.Nsec, stat.Mtim.Sec, stat.Mtim.Nsec, stat.Atim.Sec, stat.Atim.Nsec}
	var index int
	var value int64
	for index, value = range values {
		binary.LittleEndian.PutUint64(times[index*8:], uint64(value))
	}
	return unix.Setattrlist(destination, &attrs, times, unix.FSOPT_NOFOLLOW)
}

func adoptRenameExclusive(source string, destination string) error {
	var from *byte
	var to *byte
	var err error
	from, err = unix.BytePtrFromString(source)
	if err != nil {
		return err
	}
	to, err = unix.BytePtrFromString(destination)
	if err != nil {
		return err
	}
	var errno syscall.Errno
	var cwd int = unix.AT_FDCWD
	// renameatx_np with RENAME_EXCL prevents replacing an entry created after inspection.
	_, _, errno = syscall.Syscall6(unix.SYS_RENAMEATX_NP, uintptr(cwd), uintptr(unsafe.Pointer(from)), uintptr(cwd), uintptr(unsafe.Pointer(to)), 4, 0)
	runtime.KeepAlive(from)
	runtime.KeepAlive(to)
	if errno != 0 {
		return errno
	}
	return nil
}

func adoptTerminal(fd uintptr) bool {
	var err error
	_, err = unix.IoctlGetTermios(int(fd), unix.TIOCGETA)
	return err == nil
}
