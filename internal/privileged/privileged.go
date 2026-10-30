// Package privileged describes the small set of storage operations that the
// setuid helper performs for vaultlock, and validates every request before a
// root process acts on it.
package privileged

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unicode"

	"golang.org/x/sys/unix"
	"howett.net/plist"
)

const (
	// HelperPath is where install places the setuid helper.
	HelperPath string = "/Library/PrivilegedHelperTools/vaultlock-privileged"
	// AllowlistPath lists the volume UUIDs the helper may act on, one per line.
	AllowlistPath string = "/etc/vaultlock/volumes"
	// DataVolume is the only path outside an allowed volume that snapshots are deleted from.
	DataVolume string = "/System/Volumes/Data"

	diskutilPath string = "/usr/sbin/diskutil"
	tmutilPath   string = "/usr/bin/tmutil"
)

// Kind identifies one privileged operation.
type Kind int

const (
	KindUnlock Kind = iota + 1
	KindUnlockNoMount
	KindRotate
	KindLock
	KindExcludeVolume
	KindDeleteSnapshots
	KindDeleteDataSnapshots
	KindExcludePath
)

// Request is a parsed helper invocation.
type Request struct {
	Kind Kind
	UUID string
	Path string
}

// Command is the system command the helper runs for a verified request.
// Directory, when set, is the pinned directory the command must run in so a
// relative operand cannot be redirected after verification. The caller closes it.
type Command struct {
	Path      string
	Args      []string
	Directory *os.File
}

// Runner executes a read-only inspection command and returns its output.
type Runner interface {
	Run(context.Context, string, []string) ([]byte, error)
}

var uuidPattern *regexp.Regexp = regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$`)
var devicePattern *regexp.Regexp = regexp.MustCompile(`^disk[0-9]+s[0-9]+(?:s[0-9]+)?$`)

var operationNames map[Kind]string = map[Kind]string{
	KindUnlock:              "unlock",
	KindUnlockNoMount:       "unlock",
	KindRotate:              "rotate",
	KindLock:                "lock",
	KindExcludeVolume:       "exclude-volume",
	KindDeleteSnapshots:     "delete-snapshots",
	KindDeleteDataSnapshots: "delete-data-snapshots",
	KindExcludePath:         "exclude-path",
}

// ValidUUID reports whether text is an upper-case APFS volume UUID.
func ValidUUID(text string) bool { return uuidPattern.MatchString(text) }

// Parse turns helper arguments into a Request, refusing anything outside the
// fixed operation table.
func Parse(args []string) (Request, error) {
	if len(args) == 0 {
		return Request{}, errors.New("an operation is required")
	}
	var name string = args[0]
	var operands []string = args[1:]
	switch name {
	case "unlock":
		var request Request
		var err error
		request, err = volumeRequest(KindUnlock, operands, 1)
		if err == nil && len(operands) == 2 {
			if operands[1] != "--nomount" {
				return Request{}, fmt.Errorf("unknown unlock option: %s", operands[1])
			}
			request.Kind = KindUnlockNoMount
		}
		return request, err
	case "rotate":
		return volumeRequest(KindRotate, operands, 0)
	case "lock":
		return volumeRequest(KindLock, operands, 0)
	case "exclude-volume":
		return volumeRequest(KindExcludeVolume, operands, 0)
	case "delete-snapshots":
		return volumeRequest(KindDeleteSnapshots, operands, 0)
	case "delete-data-snapshots":
		if len(operands) != 0 {
			return Request{}, errors.New("delete-data-snapshots takes no operands")
		}
		return Request{Kind: KindDeleteDataSnapshots}, nil
	case "exclude-path":
		if len(operands) != 1 {
			return Request{}, errors.New("exclude-path requires one directory")
		}
		if err := validPath(operands[0]); err != nil {
			return Request{}, err
		}
		return Request{Kind: KindExcludePath, Path: operands[0]}, nil
	}
	return Request{}, fmt.Errorf("unknown operation: %s", name)
}

func volumeRequest(kind Kind, operands []string, optional int) (Request, error) {
	if len(operands) < 1 || len(operands) > 1+optional {
		return Request{}, fmt.Errorf("%s requires a volume UUID", operationNames[kind])
	}
	if !ValidUUID(operands[0]) {
		return Request{}, errors.New("volume UUID is malformed")
	}
	return Request{Kind: kind, UUID: operands[0]}, nil
}

func validPath(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || strings.IndexFunc(path, unicode.IsControl) >= 0 {
		return errors.New("path must be absolute, clean, and free of control characters")
	}
	return nil
}

// Args renders the request as helper arguments. Parse(request.Args()) yields
// the same request.
func (r Request) Args() []string {
	var args []string = []string{operationNames[r.Kind]}
	switch r.Kind {
	case KindDeleteDataSnapshots:
	case KindExcludePath:
		args = append(args, r.Path)
	case KindUnlockNoMount:
		args = append(args, r.UUID, "--nomount")
	default:
		args = append(args, r.UUID)
	}
	return args
}

// Entry is one allowlist line: a volume and the user who may drive it.
type Entry struct {
	UUID  string
	Owner int
}

// AdminGroup is the macOS admin group. Operations that touch the whole machine
// rather than an allowed volume require membership.
const AdminGroup int = 80

// Allowed reports whether the allowlist grants uuid to the user with realUID.
func Allowed(data []byte, uuid string, realUID int) bool {
	for _, entry := range Entries(data) {
		if entry.UUID == uuid && entry.Owner == realUID {
			return true
		}
	}
	return false
}

// Entries parses allowlist contents, skipping blank lines, comments, and
// malformed lines so a damaged file grants nothing it should not.
func Entries(data []byte) []Entry {
	var result []Entry
	for _, line := range strings.Split(string(data), "\n") {
		var text string = strings.TrimSpace(line)
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		var fields []string = strings.Fields(text)
		if len(fields) != 2 || !ValidUUID(fields[0]) {
			continue
		}
		var owner int
		var err error
		owner, err = strconv.Atoi(fields[1])
		if err != nil || owner < 0 || strconv.Itoa(owner) != fields[1] {
			continue
		}
		result = append(result, Entry{fields[0], owner})
	}
	return result
}

// Allow returns the allowlist contents with the entry added once.
func Allow(data []byte, uuid string, owner int) ([]byte, error) {
	if !ValidUUID(uuid) {
		return nil, errors.New("volume UUID is malformed")
	}
	if owner < 0 {
		return nil, errors.New("owner must be a user ID")
	}
	if Allowed(data, uuid, owner) {
		return data, nil
	}
	return render(append(Entries(data), Entry{uuid, owner})), nil
}

// Revoke returns the allowlist contents without any entry for uuid.
func Revoke(data []byte, uuid string) []byte {
	var kept []Entry
	var removed bool
	for _, entry := range Entries(data) {
		if entry.UUID == uuid {
			removed = true
			continue
		}
		kept = append(kept, entry)
	}
	if !removed {
		return data
	}
	return render(kept)
}

func render(list []Entry) []byte {
	sort.Slice(list, func(i, j int) bool {
		if list[i].UUID != list[j].UUID {
			return list[i].UUID < list[j].UUID
		}
		return list[i].Owner < list[j].Owner
	})
	var text string = "# APFS volume UUIDs that vaultlock-privileged may operate on, with the owning user ID.\n"
	for _, entry := range list {
		text += entry.UUID + " " + strconv.Itoa(entry.Owner) + "\n"
	}
	return []byte(text)
}

// AdminMember reports whether a process's supplementary groups include the
// admin group. The setuid helper inherits the caller's groups unchanged, so
// this answers for the invoking user.
func AdminMember(groups []int) bool {
	for _, gid := range groups {
		if gid == AdminGroup {
			return true
		}
	}
	return false
}

// Resolve verifies the request against the live system and returns the
// command to run. Volume operations take their device and mount point from
// diskutil, never from the caller. realUID and groups describe the invoking
// user. The allowlist is checked by the caller before Resolve.
func Resolve(ctx context.Context, request Request, runner Runner, realUID int, groups []int) (Command, error) {
	switch request.Kind {
	case KindDeleteDataSnapshots:
		if !AdminMember(groups) {
			return Command{}, errors.New("deleting data-volume snapshots requires an administrator account")
		}
		return Command{Path: tmutilPath, Args: []string{"deletelocalsnapshots", DataVolume}}, nil
	case KindExcludePath:
		var directory *os.File
		var err error
		directory, err = openOwnedDirectory(request.Path, realUID)
		if err != nil {
			return Command{}, err
		}
		return Command{Path: tmutilPath, Args: []string{"addexclusion", "-p", "."}, Directory: directory}, nil
	}
	var device, mount string
	var err error
	device, mount, err = inspect(ctx, runner, request.UUID)
	if err != nil {
		return Command{}, err
	}
	switch request.Kind {
	case KindUnlock:
		return Command{Path: diskutilPath, Args: []string{"apfs", "unlockVolume", device, "-stdinpassphrase"}}, nil
	case KindUnlockNoMount:
		return Command{Path: diskutilPath, Args: []string{"apfs", "unlockVolume", device, "-nomount", "-stdinpassphrase"}}, nil
	case KindRotate:
		return Command{Path: diskutilPath, Args: []string{"apfs", "changePassphrase", device, "-user", "disk", "-oldStdinpassphrase", "-newStdinpassphrase"}}, nil
	case KindLock:
		return Command{Path: diskutilPath, Args: []string{"apfs", "lockVolume", device}}, nil
	case KindExcludeVolume, KindDeleteSnapshots:
		if mount == "" {
			return Command{}, errors.New("volume is not mounted")
		}
		if request.Kind == KindExcludeVolume {
			return Command{Path: tmutilPath, Args: []string{"addexclusion", "-v", mount}}, nil
		}
		return Command{Path: tmutilPath, Args: []string{"deletelocalsnapshots", mount}}, nil
	}
	return Command{}, errors.New("unknown operation")
}

func inspect(ctx context.Context, runner Runner, uuid string) (string, string, error) {
	var data []byte
	var err error
	data, err = runner.Run(ctx, diskutilPath, []string{"info", "-plist", uuid})
	if err != nil {
		return "", "", fmt.Errorf("cannot inspect volume %s", uuid)
	}
	var fields map[string]any
	if _, err = plist.Unmarshal(data, &fields); err != nil {
		return "", "", errors.New("diskutil returned a malformed property list")
	}
	var actual string
	var ok bool
	actual, ok = fields["VolumeUUID"].(string)
	if !ok || actual != uuid {
		return "", "", errors.New("volume UUID does not match")
	}
	var device string
	device, ok = fields["DeviceIdentifier"].(string)
	if !ok || !devicePattern.MatchString(device) {
		return "", "", errors.New("device identifier is malformed")
	}
	if kind, present := fields["FilesystemType"]; present && kind != "apfs" {
		return "", "", errors.New("expected an APFS volume")
	}
	var mount string
	if value, present := fields["MountPoint"]; present {
		mount, ok = value.(string)
		if !ok {
			return "", "", errors.New("mount point is malformed")
		}
		if mount != "" {
			if err = validPath(mount); err != nil {
				return "", "", errors.New("mount point is malformed")
			}
		}
	}
	return device, mount, nil
}

// openOwnedDirectory opens path one component at a time without following
// symlinks, then checks on the descriptor that it is a directory owned by the
// invoking user. The descriptor pins that directory, so the command that runs
// in it cannot be redirected by renaming a component afterwards.
func openOwnedDirectory(path string, realUID int) (*os.File, error) {
	if err := validPath(path); err != nil {
		return nil, err
	}
	if path == "/" {
		return nil, errors.New("the root directory cannot be excluded")
	}
	var fd int
	var err error
	fd, err = unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	for _, component := range strings.Split(strings.TrimPrefix(path, "/"), "/") {
		var next int
		next, err = unix.Openat(fd, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		unix.Close(fd)
		if err != nil {
			return nil, fmt.Errorf("cannot open %s as a directory without following symlinks", path)
		}
		fd = next
	}
	var stat unix.Stat_t
	if err = unix.Fstat(fd, &stat); err != nil {
		unix.Close(fd)
		return nil, err
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFDIR {
		unix.Close(fd)
		return nil, errors.New("path must be a directory")
	}
	if int(stat.Uid) != realUID {
		unix.Close(fd)
		return nil, errors.New("directory must belong to the invoking user")
	}
	return os.NewFile(uintptr(fd), path), nil
}

// Usable reports whether the helper's file metadata makes it safe to invoke:
// a root-owned regular file with the setuid bit, executable, and writable by
// nobody but root.
func Usable(stat *syscall.Stat_t) error {
	if stat == nil {
		return errors.New("helper metadata is unavailable")
	}
	if stat.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return errors.New("helper is not a regular file")
	}
	if stat.Uid != 0 {
		return errors.New("helper is not owned by root")
	}
	if stat.Mode&syscall.S_ISUID == 0 {
		return errors.New("helper is not setuid")
	}
	if stat.Mode&0022 != 0 {
		return errors.New("helper is writable by other users")
	}
	if stat.Mode&0111 == 0 {
		return errors.New("helper is not executable")
	}
	return nil
}

// UsablePath applies Usable to the file at path without following symlinks.
func UsablePath(path string) error {
	var info os.FileInfo
	var err error
	info, err = os.Lstat(path)
	if err != nil {
		return err
	}
	var stat *syscall.Stat_t
	var ok bool
	stat, ok = info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("helper metadata is unavailable")
	}
	return Usable(stat)
}
