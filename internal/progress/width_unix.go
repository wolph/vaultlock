//go:build darwin || linux

package progress

import (
	"io"
	"os"
	"syscall"
	"unsafe"
)

func nativeWidth(writer io.Writer) int {
	var file *os.File
	var valid bool
	file, valid = writer.(*os.File)
	if !valid {
		return 0
	}
	var dimensions [4]uint16
	var errno syscall.Errno
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&dimensions[0])))
	if errno != 0 {
		return 0
	}
	return int(dimensions[1])
}

func streamTerminal(writer io.Writer) bool {
	var file *os.File
	var ok bool
	file, ok = writer.(*os.File)
	if !ok {
		return true
	}
	var dimensions [4]uint16
	var errno syscall.Errno
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&dimensions[0])))
	return errno == 0
}
