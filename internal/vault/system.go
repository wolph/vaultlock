package vault

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/wolph/vaultlock/internal/privileged"
	"github.com/wolph/vaultlock/internal/progress"
	"howett.net/plist"
)

type systemRunner struct{}

func (systemRunner) Run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	var command *exec.Cmd = exec.CommandContext(ctx, path, args...)
	command.Stdin = bytes.NewReader(input)
	command.Env = cleanEnvironment(os.Environ())
	var output []byte
	var err error

	output, err = command.Output()
	return output, err
}
func cleanEnvironment(environment []string) []string {
	var result []string
	for _, entry := range environment {
		var key string

		key, _, _ = strings.Cut(entry, "=")
		var upper string = strings.ToUpper(key)
		if strings.Contains(upper, "PASSPHRASE") || strings.Contains(upper, "PLAINTEXT") || strings.Contains(upper, "RECOVERY") || strings.Contains(upper, "SECRET") || strings.Contains(upper, "TOKEN") || strings.Contains(upper, "PASSWORD") {
			continue
		}
		result = append(result, entry)
	}
	return result
}
func (a *App) run(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	var output []byte
	var err error

	output, err = a.execute(ctx, path, args, input)
	if err != nil {
		// Unmount has no secret input. Other commands keep their diagnostics private.
		if path == "/usr/sbin/diskutil" && len(args) == 2 && args[0] == "unmount" && devicePattern.MatchString(args[1]) && len(input) == 0 {
			return nil, unmountError(args[1], output, err)
		}
		return nil, fmt.Errorf("%s operation failed", path)
	}
	return output, nil
}

func unmountError(device string, output []byte, failure error) error {
	var diagnostic string = string(output)
	var exit *exec.ExitError
	if errors.As(failure, &exit) {
		diagnostic += "\n" + string(exit.Stderr)
	}
	var text []rune = []rune(progress.SanitiseText(strings.TrimSpace(diagnostic)))
	if len(text) > 4096 {
		text = append(text[:4096], []rune("\n[diagnostic truncated]")...)
	}
	if len(text) == 0 {
		return fmt.Errorf("APFS unmount failed for %s. Close applications using the vault and retry lock", device)
	}
	return fmt.Errorf("APFS unmount failed for %s: %s\nClose the reported process or its working directory and retry lock", device, string(text))
}
func (a *App) sudo(ctx context.Context, path string, args []string, input []byte) error {
	var err error

	_, err = a.run(ctx, "/usr/bin/sudo", append([]string{path}, args...), input)
	return err
}

type VolumeInfo struct {
	UUID, Device, MountPoint, Name string
	Locked, FileVault              bool
}

var devicePattern *regexp.Regexp = regexp.MustCompile(`^disk[0-9]+s[0-9]+(?:s[0-9]+)?$`)

func (a *App) Inspect(ctx context.Context, target string) (VolumeInfo, error) {
	var info VolumeInfo
	var data []byte
	var err error

	data, err = a.run(ctx, "/usr/sbin/diskutil", []string{"info", "-plist", target}, nil)
	if err != nil {
		return info, err
	}
	var fields map[string]any
	if _, err = plist.Unmarshal(data, &fields); err != nil {
		return info, errors.New("diskutil returned a malformed property list")
	}
	var ok bool
	info.UUID, ok = fields["VolumeUUID"].(string)
	if !ok || info.UUID == "" {
		return info, errors.New("APFS volume UUID is missing")
	}
	info.Device, ok = fields["DeviceIdentifier"].(string)
	if !ok || !devicePattern.MatchString(info.Device) {
		return info, errors.New("APFS device identifier is malformed")
	}
	info.Locked, ok = fields["Locked"].(bool)
	if !ok {
		return info, errors.New("APFS locked observation is missing")
	}
	if mount, present := fields["MountPoint"]; present {
		info.MountPoint, ok = mount.(string)
		if !ok {
			return info, errors.New("APFS mount observation is malformed")
		}
	}
	info.Name, _ = fields["VolumeName"].(string)
	info.FileVault, _ = fields["FileVault"].(bool)
	if !info.FileVault {
		info.FileVault, _ = fields["Encrypted"].(bool)
	}
	if kind, present := fields["FilesystemType"]; present && kind != "apfs" {
		return info, errors.New("expected an APFS volume")
	}
	return info, nil
}
func (a *App) CheckMount(ctx context.Context, state State) (VolumeInfo, error) {
	var info VolumeInfo
	var err error

	info, err = a.Inspect(ctx, state.VolumeUUID)
	if err != nil {
		return info, err
	}
	if info.UUID != state.VolumeUUID {
		return info, errors.New("APFS volume UUID changed")
	}
	if info.MountPoint != "" && info.MountPoint != a.Config.MountPoint {
		return info, errors.New("APFS volume is mounted at an unexpected path")
	}
	if info.MountPoint != "" {
		var mounted VolumeInfo
		var err error

		mounted, err = a.Inspect(ctx, a.Config.MountPoint)
		if err != nil || mounted.UUID != info.UUID || mounted.Device != info.Device {
			return info, errors.New("vault mount identity does not match")
		}
	}
	if info.Locked && info.MountPoint != "" {
		return info, errors.New("locked APFS volume unexpectedly reports a mount")
	}
	return info, nil
}
func (a *App) expected(ctx context.Context, state State, expected VolumeInfo) (VolumeInfo, error) {
	var current VolumeInfo
	var err error

	current, err = a.CheckMount(ctx, state)
	if err != nil {
		return current, err
	}
	if current.UUID != expected.UUID || current.Device != expected.Device || current.Locked != expected.Locked || current.MountPoint != expected.MountPoint {
		return current, errors.New("APFS identity or state changed during operation")
	}
	return current, nil
}
func (a *App) keychain(ctx context.Context) ([]byte, bool, error) {
	var output []byte
	var err error

	output, err = a.execute(ctx, "/usr/bin/security", []string{"find-generic-password", "-a", a.Config.User, "-s", "vaultlock-" + a.Config.Volume, "-w"}, nil)
	if err != nil {
		var exit interface{ ExitCode() int }
		if errors.As(err, &exit) && exit.ExitCode() == 44 {
			return nil, false, nil
		}
		return nil, false, errors.New("cannot inspect Keychain recovery entry")
	}
	var pass []byte

	pass, err = normaliseSecret(output)
	return pass, true, err
}
func (a *App) storeKeychain(ctx context.Context, pass []byte) error {
	var input []byte = []byte(fmt.Sprintf("add-generic-password -a %s -s vaultlock-%s -w %s -U\n", a.Config.User, a.Config.Volume, pass))
	var err error

	_, err = a.run(ctx, "/usr/bin/security", []string{"-i"}, input)
	return err
}
func (a *App) deleteKeychain(ctx context.Context) error {
	var err error

	_, err = a.run(ctx, "/usr/bin/security", []string{"delete-generic-password", "-a", a.Config.User, "-s", "vaultlock-" + a.Config.Volume}, nil)
	return err
}

// HookRunner preserves the interactive streams of trusted lifecycle hooks.
type HookRunner interface {
	RunHook(context.Context, string, []string, io.Reader, io.Writer, io.Writer) error
}

func (systemRunner) RunHook(ctx context.Context, path string, args []string, input io.Reader, output, diagnostics io.Writer) error {
	var command *exec.Cmd = exec.CommandContext(ctx, path, args...)
	command.Stdin = input
	command.Stdout = output
	command.Stderr = diagnostics
	command.Env = cleanEnvironment(os.Environ())
	if handled, err := runTerminalHook(ctx, command, input); handled {
		if err != nil {
			return errors.New("lifecycle hook failed")
		}
		return nil
	}
	if err := command.Run(); err != nil {
		return errors.New("lifecycle hook failed")
	}
	return nil
}

func (a *App) execute(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	var task *progress.Task = a.beginProgress(operationLabel(path, args), 0, 0)
	defer task.Close()
	if err := a.checkProgress(); err != nil {
		return nil, err
	}
	var output []byte
	var err error
	var actualArgs []string = args
	if path == "/usr/bin/sudo" {
		if runner, ok := a.Runner.(AdministratorAuthoriser); ok {
			if err := a.authoriseAdministrator(ctx, runner); err != nil {
				return nil, err
			}
			actualArgs = append([]string{"-n"}, args...)
		}
	}
	if mutatesStorage(path, args) {
		if err := a.beforeMutation(); err != nil {
			return nil, err
		}
	}
	output, err = a.Runner.Run(ctx, path, actualArgs, input)
	if err == nil {
		task.Complete()
	}
	return output, err
}
func operationLabel(path string, args []string) string {
	if path == "/usr/bin/sudo" && len(args) > 0 {
		return "Wait for administrator authorisation and " + operationLabel(args[0], args[1:])
	}
	if path == privileged.HelperPath {
		return helperLabel(args)
	}
	if len(args) == 0 {
		return "Wait for a system operation"
	}
	switch path {
	case "/usr/sbin/diskutil":
		switch args[0] {
		case "info":
			return "Inspect APFS volume identity and mount state"
		case "mount":
			return "Mount the APFS volume and verify access"
		case "unmount":
			return "Unmount the APFS vault"
		case "apfs":
			if len(args) > 1 {
				switch args[1] {
				case "list":
					return "Inspect the APFS container and existing volumes"
				case "addVolume":
					return "Create the encrypted APFS volume"
				case "changePassphrase":
					return "Rotate the APFS recovery passphrase"
				case "unlockVolume":
					for _, arg := range args[2:] {
						if arg == "-nomount" {
							return "Load APFS encryption keys without mounting for passphrase rotation"
						}
					}
					return "Unlock the encrypted APFS volume"
				case "lockVolume":
					return "Seal the encrypted APFS volume"
				}
			}
		}
	case "/usr/bin/security":
		switch args[0] {
		case "find-generic-password":
			return "Read the protected Keychain recovery entry"
		case "delete-generic-password":
			return "Remove the Keychain recovery entry"
		case "-i":
			return "Store the protected Keychain recovery entry"
		}
	case "/usr/bin/tmutil":
		switch args[0] {
		case "addexclusion":
			return "Exclude protected storage from Time Machine"
		case "isexcluded":
			return "Verify the Time Machine exclusion"
		case "deletelocalsnapshots":
			return "Delete local Time Machine snapshots"
		}
	}
	return "Wait for a trusted lifecycle hook"
}

// AdministratorAuthoriser separates interactive authentication from secret stdin.
type AdministratorAuthoriser interface {
	CheckAdministrator(context.Context) error
	AuthoriseAdministrator(context.Context, io.Reader, io.Writer, io.Writer) error
}

func (systemRunner) CheckAdministrator(ctx context.Context) error {
	var command *exec.Cmd = exec.CommandContext(ctx, "/usr/bin/sudo", "-n", "-v")
	command.Env = cleanEnvironment(os.Environ())
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	return command.Run()
}
func (systemRunner) AuthoriseAdministrator(ctx context.Context, input io.Reader, output, diagnostics io.Writer) error {
	var command *exec.Cmd = exec.CommandContext(ctx, "/usr/bin/sudo", "-v")
	command.Env = cleanEnvironment(os.Environ())
	command.Stdin = input
	command.Stdout = output
	command.Stderr = diagnostics
	if err := command.Run(); err != nil {
		return errors.New("administrator authorisation failed")
	}
	return nil
}
func (a *App) authoriseAdministrator(ctx context.Context, runner AdministratorAuthoriser) error {
	var task *progress.Task = a.beginProgress("Check administrator authorisation", 0, 0)
	var err error = runner.CheckAdministrator(ctx)
	if err == nil {
		task.Complete()
		return nil
	}
	task.Close()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	var waiting *progress.Task = a.beginProgress("Wait for administrator authorisation", 0, 0)
	defer waiting.Close()
	fmt.Fprintln(a.Err, a.diagnosticPalette().Warning("Waiting for administrator authorisation.")+" Enter your password at the sudo prompt.")
	var resume func() = func() {}
	if a.display != nil {
		resume = a.display.Pause()
	}
	defer resume()
	defer func() { fmt.Fprintln(a.Err) }()
	err = runner.AuthoriseAdministrator(ctx, os.Stdin, a.Out, a.Err)
	if err == nil {
		waiting.Complete()
	}
	return err
}

func mutatesStorage(path string, args []string) bool {
	if path == "/usr/bin/sudo" && len(args) > 0 {
		return mutatesStorage(args[0], args[1:])
	}
	if path == privileged.HelperPath {
		return true
	}
	if len(args) == 0 {
		return false
	}
	switch path {
	case "/usr/sbin/diskutil":
		return args[0] != "info" && !(args[0] == "apfs" && len(args) > 1 && args[1] == "list")
	case "/usr/bin/security":
		return args[0] != "find-generic-password"
	case "/usr/bin/tmutil":
		return args[0] != "isexcluded"
	}
	return false
}

// helperLabel names the storage operation behind a privileged helper call
// the same way the direct command would, without the sudo wait.
func helperLabel(args []string) string {
	var request privileged.Request
	var err error
	request, err = privileged.Parse(args)
	if err != nil {
		return "Wait for the privileged helper"
	}
	switch request.Kind {
	case privileged.KindUnlock:
		return "Unlock the encrypted APFS volume"
	case privileged.KindUnlockNoMount:
		return "Load APFS encryption keys without mounting for passphrase rotation"
	case privileged.KindRotate:
		return "Rotate the APFS recovery passphrase"
	case privileged.KindLock:
		return "Seal the encrypted APFS volume"
	case privileged.KindExcludeVolume, privileged.KindExcludePath:
		return "Exclude protected storage from Time Machine"
	case privileged.KindDeleteSnapshots, privileged.KindDeleteDataSnapshots:
		return "Delete local Time Machine snapshots"
	}
	return "Wait for the privileged helper"
}
