// vaultlock-privileged is a small setuid-root helper that performs the few
// diskutil and tmutil operations vaultlock needs, for volumes an administrator
// has listed in /etc/vaultlock/volumes. Everything else is refused.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"

	"github.com/wolph/vaultlock/internal/privileged"
)

// Version is set when building a release binary.
var Version string = "dev"

const usage string = `Usage: vaultlock-privileged <operation> [operand]

Storage operations (installed setuid root, volumes must be allowed):
  unlock <uuid> [--nomount]   Unlock an APFS volume, passphrase on stdin.
  rotate <uuid>               Change the passphrase, old and new on stdin.
  lock <uuid>                 Lock an APFS volume.
  exclude-volume <uuid>       Exclude the mounted volume from Time Machine.
  delete-snapshots <uuid>     Delete local snapshots of the mounted volume.
  delete-data-snapshots       Delete local snapshots of /System/Volumes/Data.
  exclude-path <directory>    Exclude your own directory from Time Machine.

Administration (run with sudo):
  install                     Copy this binary to ` + privileged.HelperPath + ` as root 4755.
  uninstall                   Remove the installed helper.
  allow <uuid> [uid]          Allow a volume for the sudo caller or the given user.
  revoke <uuid>               Remove every entry for a volume.
  list                        Print the allowed volumes and their users.
`

type identity struct {
	realUID, effectiveUID int
	groups                []int
	sudoUser              string
}

func main() {
	var groups []int
	groups, _ = syscall.Getgroups()
	var ids identity = identity{os.Getuid(), os.Geteuid(), groups, os.Getenv("SUDO_UID")}
	os.Exit(run(context.Background(), os.Args[1:], ids, os.Stdin, os.Stdout, os.Stderr))
}

func run(ctx context.Context, args []string, ids identity, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 1 && (args[0] == "--version" || args[0] == "version") {
		fmt.Fprintf(stdout, "vaultlock-privileged %s\n", Version)
		return 0
	}
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprint(stdout, usage)
		if len(args) == 0 {
			return 64
		}
		return 0
	}
	var err error
	switch args[0] {
	case "install", "uninstall", "allow", "revoke", "list":
		err = administer(args, ids, stdout)
	default:
		return operate(ctx, args, ids, stdin, stdout, stderr)
	}
	if err != nil {
		fmt.Fprintf(stderr, "vaultlock-privileged: %s\n", err)
		return 1
	}
	return 0
}

func operate(ctx context.Context, args []string, ids identity, stdin io.Reader, stdout, stderr io.Writer) int {
	var request privileged.Request
	var err error
	request, err = privileged.Parse(args)
	if err != nil {
		fmt.Fprintf(stderr, "vaultlock-privileged: %s\n", err)
		return 64
	}
	if ids.effectiveUID != 0 {
		fmt.Fprintf(stderr, "vaultlock-privileged: not running as root. Install it with: sudo %s install\n", executable())
		return 77
	}
	if request.UUID != "" {
		var data []byte
		data, _ = os.ReadFile(privileged.AllowlistPath)
		if !privileged.Allowed(data, request.UUID, ids.realUID) {
			fmt.Fprintf(stderr, "vaultlock-privileged: volume %s is not allowed for user %d. Run: sudo %s allow %s\n", request.UUID, ids.realUID, privileged.HelperPath, request.UUID)
			return 77
		}
	}
	if err = becomeRoot(); err != nil {
		fmt.Fprintf(stderr, "vaultlock-privileged: %s\n", err)
		return 77
	}
	var command privileged.Command
	command, err = privileged.Resolve(ctx, request, systemRunner{}, ids.realUID, ids.groups)
	if err != nil {
		fmt.Fprintf(stderr, "vaultlock-privileged: %s\n", err)
		return 1
	}
	var child *exec.Cmd = exec.CommandContext(ctx, command.Path, command.Args...)
	child.Env = minimalEnvironment()
	if command.Directory != nil {
		// Run inside the pinned directory: the child resolves "." through the
		// descriptor's directory, whatever the path is called by now.
		defer command.Directory.Close()
		if err = syscall.Fchdir(int(command.Directory.Fd())); err != nil {
			fmt.Fprintf(stderr, "vaultlock-privileged: cannot enter the verified directory: %s\n", err)
			return 1
		}
	} else {
		child.Dir = "/"
	}
	child.Stdin = stdin
	child.Stdout = stdout
	child.Stderr = stderr
	err = child.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	if err != nil {
		fmt.Fprintf(stderr, "vaultlock-privileged: %s\n", err)
		return 1
	}
	return 0
}

// becomeRoot makes the real and saved IDs root as well, so the child sees a
// plain root process rather than a setuid one.
func becomeRoot() error {
	if err := syscall.Setgid(0); err != nil {
		return fmt.Errorf("cannot assume root group: %w", err)
	}
	if err := syscall.Setuid(0); err != nil {
		return fmt.Errorf("cannot assume root: %w", err)
	}
	return nil
}

func minimalEnvironment() []string {
	return []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", "LANG=C"}
}

type systemRunner struct{}

func (systemRunner) Run(ctx context.Context, path string, args []string) ([]byte, error) {
	var command *exec.Cmd = exec.CommandContext(ctx, path, args...)
	command.Env = minimalEnvironment()
	command.Dir = "/"
	return command.Output()
}

func executable() string {
	var path string
	var err error
	path, err = os.Executable()
	if err != nil {
		return "vaultlock-privileged"
	}
	return path
}

func administer(args []string, ids identity, stdout io.Writer) error {
	if ids.realUID != 0 || ids.effectiveUID != 0 {
		return fmt.Errorf("%s requires administrator rights, run it with sudo", args[0])
	}
	switch args[0] {
	case "install":
		if len(args) != 1 {
			return errors.New("install takes no operands")
		}
		return install(stdout)
	case "uninstall":
		if len(args) != 1 {
			return errors.New("uninstall takes no operands")
		}
		if err := os.Remove(privileged.HelperPath); err != nil && !os.IsNotExist(err) {
			return err
		}
		fmt.Fprintf(stdout, "Removed %s, %s is kept\n", privileged.HelperPath, privileged.AllowlistPath)
		return nil
	case "list":
		if len(args) != 1 {
			return errors.New("list takes no operands")
		}
		var data []byte
		data, _ = os.ReadFile(privileged.AllowlistPath)
		for _, entry := range privileged.Entries(data) {
			fmt.Fprintf(stdout, "%s %d\n", entry.UUID, entry.Owner)
		}
		return nil
	}
	if len(args) < 2 || len(args) > 3 || !privileged.ValidUUID(args[1]) {
		return fmt.Errorf("%s requires an upper-case volume UUID and, for allow, optionally the owning user ID", args[0])
	}
	if args[0] == "revoke" && len(args) != 2 {
		return errors.New("revoke takes only the volume UUID")
	}
	var data []byte
	var err error
	data, err = os.ReadFile(privileged.AllowlistPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var updated []byte
	var owner int
	if args[0] == "allow" {
		owner, err = allowOwner(args, ids)
		if err != nil {
			return err
		}
		updated, err = privileged.Allow(data, args[1], owner)
		if err != nil {
			return err
		}
	} else {
		updated = privileged.Revoke(data, args[1])
	}
	if err = writeRootFile(privileged.AllowlistPath, updated, 0644); err != nil {
		return err
	}
	if args[0] == "allow" {
		fmt.Fprintf(stdout, "Allowed %s for user %d in %s\n", args[1], owner, privileged.AllowlistPath)
	} else {
		fmt.Fprintf(stdout, "Revoked %s in %s\n", args[1], privileged.AllowlistPath)
	}
	return nil
}

// allowOwner is the user an allow entry is for: the explicit operand, or the
// user who invoked sudo.
func allowOwner(args []string, ids identity) (int, error) {
	var text string = ids.sudoUser
	if len(args) == 3 {
		text = args[2]
	}
	if text == "" {
		return 0, errors.New("allow needs the owning user ID when not run through sudo")
	}
	var owner int
	var err error
	owner, err = strconv.Atoi(text)
	if err != nil || owner < 0 || strconv.Itoa(owner) != text {
		return 0, fmt.Errorf("owner %q is not a user ID", text)
	}
	if owner == 0 {
		return 0, errors.New("root does not need an allowlist entry")
	}
	return owner, nil
}

func install(stdout io.Writer) error {
	var source string
	var err error
	source, err = os.Executable()
	if err != nil {
		return err
	}
	var data []byte
	data, err = os.ReadFile(source)
	if err != nil {
		return err
	}
	if err = writeRootFile(privileged.HelperPath, data, 0755|os.ModeSetuid); err != nil {
		return err
	}
	if _, err = os.Stat(privileged.AllowlistPath); os.IsNotExist(err) {
		var empty []byte
		empty, _ = privileged.Allow(nil, "00000000-0000-0000-0000-000000000000", 1)
		if err = writeRootFile(privileged.AllowlistPath, privileged.Revoke(empty, "00000000-0000-0000-0000-000000000000"), 0644); err != nil {
			return err
		}
	}
	if err = privileged.UsablePath(privileged.HelperPath); err != nil {
		return fmt.Errorf("installed helper is not usable: %w", err)
	}
	fmt.Fprintf(stdout, "Installed %s (root, setuid)\nAllowed volumes are listed in %s\n", privileged.HelperPath, privileged.AllowlistPath)
	return nil
}

// writeRootFile stages the content next to the destination, fixes ownership
// and mode, and renames it into place so no partially written file is ever
// executable or readable with the final name.
func writeRootFile(destination string, data []byte, mode os.FileMode) error {
	var directory string = filepath.Dir(destination)
	if err := os.MkdirAll(directory, 0755); err != nil {
		return err
	}
	if err := os.Chown(directory, 0, 0); err != nil {
		return err
	}
	var staged *os.File
	var err error
	staged, err = os.CreateTemp(directory, "."+filepath.Base(destination)+"-*")
	if err != nil {
		return err
	}
	var stagedPath string = staged.Name()
	defer os.Remove(stagedPath)
	if _, err = staged.Write(data); err != nil {
		staged.Close()
		return err
	}
	if err = staged.Sync(); err != nil {
		staged.Close()
		return err
	}
	if err = staged.Chown(0, 0); err != nil {
		staged.Close()
		return err
	}
	if err = staged.Chmod(mode); err != nil {
		staged.Close()
		return err
	}
	if err = staged.Close(); err != nil {
		return err
	}
	return os.Rename(stagedPath, destination)
}
