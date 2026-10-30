package vault

import (
	"context"
	"errors"
	"os"

	"github.com/wolph/vaultlock/internal/privileged"
)

const helperAllowCommand string = "vaultlock privileged allow"

// helperUsable reports whether the setuid helper is installed safely and, for
// a volume operation, whether the allowlist grants the volume to this user.
// HelperProbe replaces the file checks in tests.
func (a *App) helperUsable(uuid string) bool {
	if a.HelperProbe != nil {
		return a.HelperProbe(uuid)
	}
	if err := privileged.UsablePath(privileged.HelperPath); err != nil {
		return false
	}
	if uuid == "" {
		return true
	}
	var data []byte
	var err error
	data, err = os.ReadFile(privileged.AllowlistPath)
	if err != nil {
		return false
	}
	return privileged.Allowed(data, uuid, os.Getuid())
}

// privileged runs a storage operation through the setuid helper when it can,
// and otherwise through sudo with the given command, exactly as before the
// helper existed.
func (a *App) privileged(ctx context.Context, request privileged.Request, sudoPath string, sudoArgs []string, input []byte) error {
	var wellFormed bool = request.UUID == "" || privileged.ValidUUID(request.UUID)
	if wellFormed && a.helperUsable(request.UUID) {
		var err error
		_, err = a.run(ctx, privileged.HelperPath, request.Args(), input)
		return err
	}
	return a.sudo(ctx, sudoPath, sudoArgs, input)
}

func (a *App) helperInstalled() bool { return a.helperUsable("") }

// helperStatus is the one-line summary that status prints.
func (a *App) helperStatus(uuid string) string {
	if !a.helperInstalled() {
		return "Privileged helper: not installed, storage operations use sudo"
	}
	if a.helperUsable(uuid) {
		return "Privileged helper: installed, volume allowed"
	}
	return "Privileged helper: installed, volume not allowed. Run: " + helperAllowCommand
}

// registerHelperVolume adds a freshly created volume to the helper allowlist
// when the helper is installed. A failure is reported rather than fatal: the
// vault keeps working through sudo.
func (a *App) registerHelperVolume(ctx context.Context, uuid string) {
	if !a.helperInstalled() || a.helperUsable(uuid) {
		return
	}
	if err := a.allowHelperVolume(ctx, uuid); err != nil {
		a.Report("Privileged helper: volume not allowed, %s. Run: %s", err, helperAllowCommand)
		return
	}
	a.Report("Privileged helper: volume %s allowed", uuid)
}

func (a *App) allowHelperVolume(ctx context.Context, uuid string) error {
	if !privileged.ValidUUID(uuid) {
		return errors.New("volume UUID is malformed")
	}
	if _, err := a.run(ctx, "/usr/bin/sudo", []string{privileged.HelperPath, "allow", uuid}, nil); err != nil {
		return errors.New("registration through sudo failed")
	}
	if !a.helperUsable(uuid) {
		return errors.New("allowlist does not list the volume after registration")
	}
	return nil
}

// allowHelper implements "vaultlock privileged allow" for an existing vault.
func (a *App) allowHelper(ctx context.Context) error {
	var s State
	var err error
	s, err = a.ReadState()
	if err != nil {
		return err
	}
	if !a.helperInstalled() {
		return errors.New("privileged helper is not installed at " + privileged.HelperPath + ". Run: sudo make install-helper")
	}
	if a.helperUsable(s.VolumeUUID) {
		a.Report("Privileged helper: volume %s already allowed", s.VolumeUUID)
		return nil
	}
	if a.Options.DryRun {
		a.Report("Would allow %s in %s through sudo", s.VolumeUUID, privileged.AllowlistPath)
		a.Report("Result: no changes made")
		return nil
	}
	if err = a.allowHelperVolume(ctx, s.VolumeUUID); err != nil {
		return err
	}
	a.Report("Privileged helper: volume %s allowed", s.VolumeUUID)
	return nil
}
