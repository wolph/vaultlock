package vault

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/wolph/vaultlock/internal/deadline"
	"github.com/wolph/vaultlock/internal/timelock"
	"howett.net/plist"
)

type observation struct {
	state      State
	info       VolumeInfo
	files      map[string]string
	identities map[string]os.FileInfo
	directory  os.FileInfo
	keychain   string
	keyPresent bool
}

func (a *App) observe(ctx context.Context) (observation, error) {
	defer a.wait("Inspect protected recovery state and APFS identity")()
	var o observation
	var s State
	var err error

	s, err = a.ReadState()
	if err != nil {
		return o, err
	}
	var info VolumeInfo

	info, err = a.CheckMount(ctx, s)
	if err != nil {
		return o, err
	}
	o.state = s
	o.info = info
	o.files = make(map[string]string)
	o.identities = make(map[string]os.FileInfo)
	o.directory, err = privateInfo(a.Config.StateDir, true)
	if err != nil {
		return o, err
	}
	for _, name := range []string{"state.json", "passphrase.txt", "passphrase.sha256", "passphrase.tle", "passphrase-new.txt"} {
		var data []byte
		var err error

		data, err = a.read(name)
		if os.IsNotExist(err) {
			o.files[name] = "absent"
			continue
		}
		if err != nil {
			return o, err
		}
		o.files[name] = digest(data)
		o.identities[name], err = privateInfo(a.path(name), false)
		if err != nil {
			return o, err
		}
	}
	var entries []os.DirEntry

	entries, err = os.ReadDir(a.Config.StateDir)
	if err != nil {
		return o, err
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".lock-") || strings.HasPrefix(entry.Name(), ".unlock-recovery.") || strings.HasPrefix(entry.Name(), ".stage-") {
			return o, errors.New("staged recovery material exists, inspect it before continuing")
		}
	}
	var key []byte
	var present bool

	key, present, err = a.keychain(ctx)
	if err != nil {
		return o, err
	}
	o.keyPresent = present
	if present {
		o.keychain = digest(key)
	}
	return o, nil
}
func (a *App) unchanged(ctx context.Context, wanted observation) error {
	defer a.wait("Revalidate the planned storage and recovery state")()
	var current observation
	var err error

	current, err = a.observe(ctx)
	if err != nil {
		return err
	}
	if current.info != wanted.info || current.keyPresent != wanted.keyPresent || current.keychain != wanted.keychain {
		return errors.New("vault observations changed after planning")
	}
	if !os.SameFile(current.directory, wanted.directory) || current.directory.Mode() != wanted.directory.Mode() {
		return errors.New("protected state directory identity changed")
	}
	for name, hash := range wanted.files {
		var before os.FileInfo
		var after os.FileInfo

		before, after = wanted.identities[name], current.identities[name]
		if (before == nil) != (after == nil) || (before != nil && (!os.SameFile(before, after) || before.Mode() != after.Mode())) {
			return errors.New("protected file identity changed after planning")
		}
		if current.files[name] != hash {
			return errors.New("protected recovery state changed after planning")
		}
	}
	return nil
}
func (a *App) plaintext() ([]byte, error) {
	var data []byte
	var err error

	data, err = a.read("passphrase.txt")
	if err != nil {
		return nil, errors.New("plaintext recovery is missing or unsafe")
	}
	var pass []byte

	pass, err = normaliseSecret(data)
	if err != nil {
		return nil, err
	}
	if err = a.verifyPass(pass); err != nil {
		return nil, err
	}
	return pass, nil
}
func randomPass() ([]byte, error) {
	var buffer []byte = make([]byte, 48)
	if _, err := rand.Read(buffer); err != nil {
		return nil, err
	}
	return []byte(base64.StdEncoding.EncodeToString(buffer)), nil
}
func (a *App) mount(ctx context.Context, s State, info VolumeInfo) (VolumeInfo, error) {
	if info.Locked {
		return info, errors.New("cannot mount a locked volume")
	}
	if info.MountPoint == "" {
		if _, err := a.expected(ctx, s, info); err != nil {
			return info, err
		}
		if _, err := a.run(ctx, "/usr/sbin/diskutil", []string{"mount", info.Device}, nil); err != nil {
			return info, err
		}
	}
	var current VolumeInfo
	var err error

	current, err = a.CheckMount(ctx, s)
	if err != nil {
		return current, err
	}
	if current.Locked || current.MountPoint != a.Config.MountPoint {
		return current, errors.New("vault did not reach the expected mounted state")
	}
	return current, nil
}
func (a *App) unlockWith(ctx context.Context, s State, info VolumeInfo, pass []byte) (VolumeInfo, error) {
	if info.Locked {
		if _, err := a.expected(ctx, s, info); err != nil {
			return info, err
		}
		if err := a.sudo(ctx, "/usr/sbin/diskutil", []string{"apfs", "unlockVolume", info.Device, "-stdinpassphrase"}, pass); err != nil {
			return info, err
		}
		var err error
		info, err = a.CheckMount(ctx, s)
		if err != nil {
			return info, err
		}
		if info.Locked {
			return info, errors.New("APFS unlock did not unlock the volume")
		}
	}
	return a.mount(ctx, s, info)
}
func (a *App) unlock(ctx context.Context) error {
	var o observation
	var err error

	o, err = a.observe(ctx)
	if err != nil {
		return err
	}
	var s State
	var info VolumeInfo

	s, info = o.state, o.info
	if err = a.showPlan("unlock", s, info); err != nil {
		return err
	}
	if !s.Locked {
		var pass []byte
		var err error

		pass, err = a.plaintext()
		if err != nil {
			return err
		}
		if o.keyPresent && o.keychain != digest(pass) {
			return errors.New("Keychain recovery does not match protected plaintext")
		}
		if a.Options.DryRun {
			a.Report("Would converge %s to unlocked and mounted at %s", s.VolumeUUID, a.Config.MountPoint)
			a.Report("Result: no changes made")
			return nil
		}
		if err = a.unchanged(ctx, o); err != nil {
			return err
		}
		info, s, err = a.convergeUnlocked(ctx, s, info, pass)
		if err != nil {
			return err
		}
		return a.finishUnlock(ctx, s, info)
	}
	var cipher []byte

	cipher, err = a.read("passphrase.tle")
	if err != nil || len(cipher) == 0 {
		return errors.New("time-lock ciphertext is missing or unsafe")
	}
	if _, err = a.read("passphrase.sha256"); err != nil {
		return errors.New("recovery hash is missing or unsafe")
	}
	var when time.Time = time.Unix(*s.DeadlineEpoch, 0)

	a.Report("Unlock %s after %s, drand round %d", s.VolumeUUID, deadline.Format(when, a.Now()), *s.Round)
	if a.Options.DryRun {
		a.Report("Would recover the passphrase and unlock %s", s.VolumeUUID)
		a.Report("Result: no changes made")
		return nil
	}
	if a.Crypto == nil {
		return errors.New("time-lock library is unavailable")
	}
	if err = a.RunHooks(ctx, "pre-unlock", s, info); err != nil {
		return err
	}
	if err = a.unchanged(ctx, o); err != nil {
		return err
	}
	var pass []byte

	pass, err = a.decryptRecovery(ctx, cipher)
	if errors.Is(err, timelock.ErrTooEarly) {
		return fmt.Errorf("still locked until %s - this failure is the lock working", deadline.Format(when, a.Now()))
	}
	if err != nil {
		return fmt.Errorf("time-lock recovery failed, the beacon may not be available yet, locked until %s: %w", deadline.Format(when, a.Now()), err)
	}
	pass, err = normaliseSecret(pass)
	if err != nil {
		return err
	}
	if err = a.verifyPass(pass); err != nil {
		return err
	}
	if err = a.unchanged(ctx, o); err != nil {
		return err
	}
	// Retain verified recovery before an external operation can partially succeed.
	if err = a.write("passphrase.txt", append(append([]byte{}, pass...), '\n')); err != nil {
		return err
	}
	info, s, err = a.convergeUnlocked(ctx, s, info, pass)
	if err != nil {
		return err
	}
	return a.finishUnlock(ctx, s, info)
}

func (a *App) finishUnlock(ctx context.Context, state State, info VolumeInfo) error {
	a.Report("UNLOCKED at %s", info.MountPoint)
	if err := a.RunHooks(ctx, "post-unlock", state, info); err != nil {
		return fmt.Errorf("vault is unlocked and mounted, but post-unlock hooks failed. Run vaultlock unlock to retry: %w", err)
	}
	return nil
}
func (a *App) convergeUnlocked(ctx context.Context, state State, info VolumeInfo, pass []byte) (VolumeInfo, State, error) {
	var boundary protectedSnapshot
	var err error
	boundary, err = a.captureFiles("state.json", "passphrase.txt", "passphrase.sha256", "passphrase.tle", "passphrase-new.txt")
	if err != nil {
		return info, state, err
	}
	info, err = a.unlockWith(ctx, state, info, pass)
	if err != nil {
		return info, state, err
	}
	if err = a.verifyFiles(boundary); err != nil {
		return info, state, err
	}
	if err = a.storeKeychain(ctx, pass); err != nil {
		return info, state, err
	}
	if err = a.verifyUnlockRecovery(ctx, boundary, pass); err != nil {
		return info, state, err
	}
	if state.Locked {
		state.Locked = false
		state.Deadline = nil
		state.DeadlineEpoch = nil
		state.Round = nil
		if err = a.writeState(state); err != nil {
			return info, state, err
		}
		delete(boundary.entries, "state.json")
		if err = a.verifyFiles(boundary); err != nil {
			return info, state, err
		}
		boundary, err = a.captureFiles("state.json", "passphrase.txt", "passphrase.sha256", "passphrase.tle", "passphrase-new.txt")
		if err != nil {
			return info, state, err
		}
	}
	info, err = a.CheckMount(ctx, state)
	if err != nil || info.Locked || info.MountPoint != a.Config.MountPoint {
		return info, state, errors.New("unlocked target is unverified")
	}
	if err = a.verifyUnlockRecovery(ctx, boundary, pass); err != nil {
		return info, state, err
	}
	return info, state, nil
}
func (a *App) verifyUnlockRecovery(ctx context.Context, boundary protectedSnapshot, pass []byte) error {
	if err := a.verifyFiles(boundary); err != nil {
		return err
	}
	if err := a.verifyPass(pass); err != nil {
		return err
	}
	var stored []byte
	var present bool
	var err error
	stored, present, err = a.keychain(ctx)
	if err != nil || !present || digest(stored) != digest(pass) {
		return errors.New("unlocked Keychain recovery is unverified")
	}
	return a.verifyFiles(boundary)
}
func (a *App) lock(ctx context.Context, expression string) error {
	var o observation
	var err error

	o, err = a.observe(ctx)
	if err != nil {
		return err
	}
	var s State
	var info VolumeInfo

	s, info = o.state, o.info
	if s.Locked {
		if !info.Locked || info.MountPoint != "" || o.files["passphrase.txt"] != "absent" || o.files["passphrase-new.txt"] != "absent" || o.files["passphrase.tle"] == "absent" || o.files["passphrase.sha256"] == "absent" || o.keyPresent {
			return errors.New("recorded-locked vault is inconsistent, recover with unlock after the recorded deadline")
		}
		if err = a.secureTarget(ctx, s, info); err != nil {
			return err
		}
		a.Report("LOCKED until %s (existing deadline retained)", deadline.Format(time.Unix(*s.DeadlineEpoch, 0), a.Now()))
		return nil
	}
	var target time.Time

	target, err = deadline.Resolve(expression, a.Now())
	if err != nil {
		return err
	}
	var round uint64 = timelock.Round(target.Unix())
	var pass []byte

	pass, err = a.plaintext()
	if err != nil {
		return err
	}
	if !o.keyPresent || o.keychain != digest(pass) {
		return errors.New("Keychain recovery is absent or differs from protected plaintext")
	}
	if o.files["passphrase-new.txt"] != "absent" {
		return errors.New("staged recovery already exists, inspect passphrase-new.txt")
	}
	var stamp string = target.Format(time.RFC3339)
	var epoch int64 = target.Unix()
	var planned State = s
	planned.Locked = true
	planned.Deadline = &stamp
	planned.DeadlineEpoch = &epoch
	planned.Round = &round
	if err = a.showPlan("lock", planned, info); err != nil {
		return err
	}
	a.Report("Lock %s until %s, drand round %d", s.VolumeUUID, deadline.Format(target, a.Now()), round)
	if a.Options.DryRun {
		a.Report("Result: no changes made")
		return nil
	}
	if a.Crypto == nil {
		return errors.New("time-lock library is unavailable")
	}
	if err = a.confirm("Rotate the APFS passphrase and seal the vault until " + stamp + "?"); err != nil {
		return err
	}
	if err = a.unchanged(ctx, o); err != nil {
		return err
	}
	if err = a.validateHookPlans(); err != nil {
		return err
	}
	info, o, err = a.prepareLock(ctx, planned, s, info, pass, o)
	if err != nil {
		return err
	}
	var fresh []byte
	fresh, err = a.rotateRecovery(ctx, s, info, pass, o)
	if err != nil {
		return err
	}
	var sealed observation
	sealed, err = a.persistRecovery(ctx, planned, info, fresh)
	if err != nil {
		return err
	}
	return a.sealRecovery(ctx, planned, info, sealed)
}
func (a *App) prepareLock(ctx context.Context, planned, s State, info VolumeInfo, pass []byte, o observation) (VolumeInfo, observation, error) {
	var err error
	info, err = a.unlockWith(ctx, s, info, pass)
	if err != nil {
		return info, o, err
	}
	if err = a.RunHooks(ctx, "pre-lock", planned, info); err != nil {
		return info, o, err
	}
	o, err = a.observe(ctx)
	if err != nil {
		return info, o, err
	}
	if o.state.Locked || o.info.UUID != info.UUID || o.info.Device != info.Device {
		return info, o, errors.New("vault identity changed during pre-lock hooks")
	}
	var verified []byte

	verified, err = a.plaintext()
	if err != nil || digest(verified) != digest(pass) {
		return info, o, errors.New("recovery state changed during pre-lock hooks")
	}
	if err = a.excludeSnapshots(ctx); err != nil {
		return info, o, err
	}
	if err = a.unchanged(ctx, o); err != nil {
		return info, o, err
	}
	info, err = a.unmountForRotation(ctx, s, info, pass)
	return info, o, err
}

func (a *App) unmountForRotation(ctx context.Context, s State, info VolumeInfo, pass []byte) (VolumeInfo, error) {
	var device string = info.Device
	if _, err := a.run(ctx, "/usr/sbin/diskutil", []string{"unmount", device}, nil); err != nil {
		return info, err
	}
	var err error
	info, err = a.CheckMount(ctx, s)
	if err != nil {
		return info, err
	}
	if info.Device != device || info.MountPoint != "" {
		return info, errors.New("vault did not unmount safely")
	}
	// Encrypted APFS can lock automatically on unmount. Rotation needs its keys
	// loaded, while the filesystem stays unmounted so applications cannot reopen it.
	if info.Locked {
		if err = a.sudo(ctx, "/usr/sbin/diskutil", []string{"apfs", "unlockVolume", device, "-nomount", "-stdinpassphrase"}, pass); err != nil {
			return info, errors.New("cannot unlock unmounted APFS volume for rotation, original recovery retained")
		}
		info.Locked = false
		return a.expected(ctx, s, info)
	}
	return info, nil
}
func (a *App) rotateRecovery(ctx context.Context, s State, info VolumeInfo, pass []byte, o observation) ([]byte, error) {
	var err error
	var fresh []byte

	fresh, err = a.generatePassphrase()
	if err != nil {
		return nil, err
	}
	o.info = info
	if err = a.unchanged(ctx, o); err != nil {
		return nil, err
	}
	if err = a.writeNew("passphrase-new.txt", append(append([]byte{}, fresh...), '\n')); err != nil {
		return nil, err
	}
	var boundary protectedSnapshot
	boundary, err = a.captureFiles("state.json", "passphrase.txt", "passphrase.sha256", "passphrase-new.txt", "passphrase.tle")
	if err != nil {
		return nil, err
	}
	if _, err = a.expected(ctx, s, info); err != nil {
		return nil, err
	}
	if err = a.verifyFiles(boundary); err != nil {
		return nil, err
	}
	var rotationInput []byte = append(append(append([]byte{}, pass...), '\n'), fresh...)
	rotationInput = append(rotationInput, '\n')
	if err = a.sudo(ctx, "/usr/sbin/diskutil", []string{"apfs", "changePassphrase", info.Device, "-user", "disk", "-oldStdinpassphrase", "-newStdinpassphrase"}, rotationInput); err != nil {
		return nil, errors.New("APFS passphrase rotation failed, staged recovery retained at passphrase-new.txt")
	}
	// Every error after rotation retains the new plaintext until all durable artefacts verify.
	if err = a.write("passphrase.txt", append(append([]byte{}, fresh...), '\n')); err != nil {
		return nil, errors.New("cannot install rotated plaintext, recovery remains at passphrase-new.txt")
	}
	if err = a.storeKeychain(ctx, fresh); err != nil {
		return nil, errors.New("Keychain update failed, rotated plaintext recovery retained")
	}
	return fresh, nil
}
func (a *App) persistRecovery(ctx context.Context, planned State, info VolumeInfo, fresh []byte) (observation, error) {
	var err error
	var cipher []byte

	cipher, err = a.encryptRecovery(ctx, fresh, *planned.Round)
	if err != nil || len(cipher) == 0 {
		return observation{}, errors.New("time-lock encryption failed, rotated plaintext recovery retained")
	}
	if err = a.verifyFutureRecovery(ctx, cipher, *planned.Round); err != nil {
		return observation{}, errors.New("future time-lock verification failed, rotated plaintext recovery retained")
	}
	if err = a.write("passphrase.tle", cipher); err != nil {
		return observation{}, err
	}
	if err = a.write("passphrase.sha256", []byte(digest(fresh)+"\n")); err != nil {
		return observation{}, err
	}
	if err = a.writeState(planned); err != nil {
		return observation{}, err
	}
	var installed []byte

	installed, err = a.read("passphrase.tle")
	if err != nil || digest(installed) != digest(cipher) {
		return observation{}, errors.New("durable ciphertext verification failed, plaintext recovery retained")
	}
	if err = a.verifyPass(fresh); err != nil {
		return observation{}, err
	}
	var recorded State

	recorded, err = a.ReadState()
	if err != nil || !recorded.Locked || recorded.Round == nil || *recorded.Round != *planned.Round || recorded.VolumeUUID != planned.VolumeUUID || recorded.Deadline == nil || *recorded.Deadline != *planned.Deadline || recorded.DeadlineEpoch == nil || *recorded.DeadlineEpoch != *planned.DeadlineEpoch {
		return observation{}, errors.New("durable locked state verification failed, plaintext recovery retained")
	}
	if _, err = a.expected(ctx, planned, info); err != nil {
		return observation{}, err
	}
	var sealed observation

	sealed, err = a.observe(ctx)
	if err != nil {
		return observation{}, err
	}
	if sealed.files["passphrase.tle"] != digest(cipher) || sealed.files["passphrase.sha256"] != digest([]byte(digest(fresh)+"\n")) || sealed.files["passphrase.txt"] != digest(append(append([]byte{}, fresh...), '\n')) || sealed.files["passphrase-new.txt"] != sealed.files["passphrase.txt"] || !sealed.keyPresent || sealed.keychain != digest(fresh) {
		return observation{}, errors.New("durable recovery changed, plaintext recovery retained")
	}
	if err = a.unchanged(ctx, sealed); err != nil {
		return observation{}, err
	}
	return sealed, nil
}
func (a *App) sealRecovery(ctx context.Context, planned State, info VolumeInfo, sealed observation) error {
	a.sealing = true
	defer func() { a.sealing = false }()
	defer a.wait("Seal the APFS volume and verify its security")()
	var err error
	var operationContext context.Context = ctx
	var sealContext context.Context
	var cancelSeal context.CancelFunc

	sealContext, cancelSeal = context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer cancelSeal()
	ctx = sealContext
	if err = a.deleteKeychain(ctx); err != nil {
		return errors.New("cannot delete Keychain recovery, plaintext recovery retained")
	}
	var present bool

	_, present, err = a.keychain(ctx)
	if err != nil || present {
		return errors.New("Keychain recovery deletion is unverified, plaintext recovery retained")
	}
	sealed.keyPresent = false
	sealed.keychain = ""
	if err = a.unchanged(ctx, sealed); err != nil {
		return err
	}
	if err = a.remove("passphrase-new.txt"); err != nil {
		return err
	}
	sealed.files["passphrase-new.txt"] = "absent"
	delete(sealed.identities, "passphrase-new.txt")
	if err = a.unchanged(ctx, sealed); err != nil {
		return err
	}
	if err = a.remove("passphrase.txt"); err != nil {
		return err
	}
	sealed.files["passphrase.txt"] = "absent"
	delete(sealed.identities, "passphrase.txt")
	var cleanupContext context.Context
	var cancelCleanup context.CancelFunc
	cleanupContext, cancelCleanup = context.WithTimeout(context.WithoutCancel(operationContext), 30*time.Second)
	var cleanupErr error = a.sudo(cleanupContext, "/usr/bin/tmutil", []string{"deletelocalsnapshots", "/System/Volumes/Data"}, nil)
	cancelCleanup()
	var lockContext context.Context
	var cancelLock context.CancelFunc
	lockContext, cancelLock = context.WithTimeout(context.WithoutCancel(operationContext), 2*time.Minute)
	defer cancelLock()
	ctx = lockContext
	if _, err = a.expected(ctx, planned, info); err != nil {
		return err
	}
	if err = a.unchanged(ctx, sealed); err != nil {
		return err
	}
	if err = a.sudo(ctx, "/usr/sbin/diskutil", []string{"apfs", "lockVolume", info.Device}, nil); err != nil {
		return errors.New("APFS lock failed after recovery removal, target security is unverified")
	}
	info, err = a.CheckMount(ctx, planned)
	if err != nil {
		return err
	}
	if err = a.secureTarget(ctx, planned, info); err != nil {
		return err
	}
	a.Report("LOCKED until %s", deadline.Format(time.Unix(*planned.DeadlineEpoch, 0), a.Now()))
	if cleanupErr != nil {
		return errors.New("vault sealed, data-volume snapshot cleanup failed")
	}
	if operationContext.Err() != nil {
		return fmt.Errorf("vault sealed after cancellation: %w", operationContext.Err())
	}
	return a.RunHooks(ctx, "post-lock", planned, info)
}
func (a *App) excludeSnapshots(ctx context.Context) error {
	var canonical string
	var err error

	canonical, err = filepath.EvalSymlinks(a.Config.StateDir)
	if err != nil {
		return err
	}
	if err = a.sudo(ctx, "/usr/bin/tmutil", []string{"addexclusion", "-p", canonical}, nil); err != nil {
		return err
	}
	var output []byte

	output, err = a.run(ctx, "/usr/bin/tmutil", []string{"isexcluded", "-X", canonical}, nil)
	if err != nil {
		return err
	}
	var result []map[string]any
	if _, err = plist.Unmarshal(output, &result); err != nil || len(result) != 1 || result[0]["Path"] != canonical || fmt.Sprint(result[0]["IsExcluded"]) != "1" {
		return errors.New("Time Machine state-directory exclusion is unverified")
	}
	if err = a.sudo(ctx, "/usr/bin/tmutil", []string{"addexclusion", "-v", a.Config.MountPoint}, nil); err != nil {
		return err
	}
	return a.sudo(ctx, "/usr/bin/tmutil", []string{"deletelocalsnapshots", a.Config.MountPoint}, nil)
}
func (a *App) secureTarget(ctx context.Context, s State, info VolumeInfo) error {
	if !info.Locked || info.MountPoint != "" || !info.FileVault {
		return errors.New("APFS encryption or locked state is unverified")
	}
	if a.Options.DryRun {
		return nil
	}
	if _, err := a.execute(ctx, "/usr/sbin/diskutil", []string{"mount", info.Device}, nil); err == nil {
		return errors.New("locked volume mounted without a passphrase")
	}
	var current VolumeInfo
	var err error

	current, err = a.CheckMount(ctx, s)
	if err != nil || !current.Locked || current.MountPoint != "" {
		return errors.New("locked volume state changed during mount resistance check")
	}
	return nil
}
func (a *App) init(ctx context.Context) error {
	if _, err := os.Lstat(a.path("state.json")); err == nil {
		return errors.New("vault state already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	var initialDirectory os.FileInfo
	var initialDirectoryErr error

	initialDirectory, initialDirectoryErr = os.Lstat(a.Config.StateDir)
	if initialDirectoryErr == nil {
		if err := a.checkDir(); err != nil {
			return err
		}
		var entries []os.DirEntry
		var e error

		entries, e = os.ReadDir(a.Config.StateDir)
		if e != nil {
			return e
		}
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), "passphrase") || strings.HasPrefix(entry.Name(), ".stage-") {
				return errors.New("recovery artefacts already exist, refusing to initialise")
			}
		}
	} else if !os.IsNotExist(initialDirectoryErr) {
		return initialDirectoryErr
	}
	if err := a.checkVolumeAbsent(ctx); err != nil {
		return err
	}
	if err := a.showPlan("init", State{}, VolumeInfo{}); err != nil {
		return err
	}
	a.Report("Create encrypted APFS volume %s in %s at %s", a.Config.Volume, a.Config.Container, a.Config.MountPoint)
	if a.Options.DryRun {
		a.Report("Result: no changes made")
		return nil
	}
	if err := a.confirm("Create the configured encrypted APFS volume?"); err != nil {
		return err
	}
	if err := a.checkVolumeAbsent(ctx); err != nil {
		return err
	}
	var currentDirectory os.FileInfo
	var currentDirectoryErr error

	currentDirectory, currentDirectoryErr = os.Lstat(a.Config.StateDir)
	if initialDirectory == nil {
		if !os.IsNotExist(currentDirectoryErr) {
			return errors.New("state directory appeared after planning")
		}
	} else if currentDirectoryErr != nil || !os.SameFile(initialDirectory, currentDirectory) {
		return errors.New("state directory identity changed after planning")
	}
	if err := a.beforeMutation(); err != nil {
		return err
	}
	if err := os.Mkdir(a.Config.StateDir, 0700); err != nil && !os.IsExist(err) {
		return err
	}
	if err := a.checkDir(); err != nil {
		return err
	}
	if _, err := os.Lstat(a.path("state.json")); !os.IsNotExist(err) {
		return errors.New("state appeared after planning")
	}
	var pass []byte
	var err error

	pass, err = a.generatePassphrase()
	if err != nil {
		return err
	}
	if err = a.writeNew("passphrase.txt", append(append([]byte{}, pass...), '\n')); err != nil {
		return err
	}
	if err = a.writeNew("passphrase.sha256", []byte(digest(pass)+"\n")); err != nil {
		return err
	}
	var boundary protectedSnapshot

	boundary, err = a.captureFiles("passphrase.txt", "passphrase.sha256", "state.json")
	if err != nil {
		return err
	}
	if err = a.storeKeychain(ctx, pass); err != nil {
		return errors.New("Keychain storage failed, plaintext recovery retained")
	}
	if err = a.verifyFiles(boundary); err != nil {
		return err
	}
	var stored []byte
	var present bool

	stored, present, err = a.keychain(ctx)
	if err != nil || !present || digest(stored) != digest(pass) {
		return errors.New("Keychain recovery storage is unverified")
	}
	var output []byte

	output, err = a.run(ctx, "/usr/bin/sudo", []string{"/usr/sbin/diskutil", "apfs", "addVolume", a.Config.Container, "APFS", a.Config.Volume, "-stdinpassphrase"}, pass)
	if err != nil {
		return errors.New("APFS creation failed, plaintext recovery retained")
	}
	if err = a.verifyFiles(boundary); err != nil {
		return err
	}
	stored, present, err = a.keychain(ctx)
	if err != nil || !present || digest(stored) != digest(pass) {
		return errors.New("created volume recovery is unverified")
	}
	var matches [][][]byte = regexp.MustCompile(`(?m)Created new APFS Volume (disk[0-9]+s[0-9]+(?:s[0-9]+)?)`).FindAllSubmatch(output, -1)
	if len(matches) != 1 {
		return errors.New("APFS creation returned no unique device, plaintext recovery retained")
	}
	var info VolumeInfo

	info, err = a.Inspect(ctx, string(matches[0][1]))
	if err != nil {
		return err
	}
	if info.Name != a.Config.Volume || info.Device != string(matches[0][1]) || info.MountPoint != a.Config.MountPoint || info.Locked || !info.FileVault {
		return errors.New("created APFS volume identity is unexpected, plaintext recovery retained")
	}
	var s State = State{VolumeUUID: info.UUID, Extra: map[string]json.RawMessage{}}
	var created []byte

	created, _ = json.Marshal(a.Now().Format(time.RFC3339))
	s.Extra["created"] = created
	if _, err = a.CheckMount(ctx, s); err != nil {
		return err
	}
	if err = a.verifyFiles(boundary); err != nil {
		return err
	}
	var stateData []byte

	stateData, err = json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err = a.writeNew("state.json", append(stateData, '\n')); err != nil {
		return err
	}
	boundary, err = a.captureFiles("passphrase.txt", "passphrase.sha256", "state.json")
	if err != nil {
		return err
	}
	if err = a.verifyFiles(boundary); err != nil {
		return err
	}
	if _, err = a.CheckMount(ctx, s); err != nil {
		return err
	}
	if err = a.verifyFiles(boundary); err != nil {
		return err
	}
	a.Report("UNLOCKED at %s", info.MountPoint)
	return nil
}
func (a *App) checkVolumeAbsent(ctx context.Context) error {
	var data []byte
	var err error

	data, err = a.run(ctx, "/usr/sbin/diskutil", []string{"apfs", "list", "-plist", a.Config.Container}, nil)
	if err != nil {
		return err
	}
	var fields map[string]any
	if _, err = plist.Unmarshal(data, &fields); err != nil {
		return errors.New("APFS container list is malformed")
	}
	var containers []any
	var valid bool
	containers, valid = fields["Containers"].([]any)
	if !valid || len(containers) != 1 {
		return errors.New("APFS container list is missing or ambiguous")
	}
	var container map[string]any
	container, valid = containers[0].(map[string]any)
	if !valid || container["ContainerReference"] != a.Config.Container {
		return errors.New("APFS container identity does not match configuration")
	}
	if _, valid = container["Volumes"].([]any); !valid {
		return errors.New("APFS container volume list is malformed")
	}
	var walk func(any) bool
	walk = func(value any) bool {
		switch x := value.(type) {
		case map[string]any:
			if x["Name"] == a.Config.Volume || x["VolumeName"] == a.Config.Volume || x["MountPoint"] == a.Config.MountPoint {
				return true
			}
			for _, child := range x {
				if walk(child) {
					return true
				}
			}
		case []any:
			for _, child := range x {
				if walk(child) {
					return true
				}
			}
		}
		return false
	}
	if walk(fields) {
		return errors.New("a volume with the configured name or mount point already exists")
	}
	return nil
}
func (a *App) status(ctx context.Context) error {
	defer a.wait("Inspect current vault status")()
	var s State
	var err error

	s, err = a.ReadState()
	if err != nil {
		a.Report("INCONSISTENT: %s", err)
		return nil
	}
	var info VolumeInfo

	info, err = a.CheckMount(ctx, s)
	if err != nil {
		a.Report("INCONSISTENT: %s", err)
		return nil
	}
	var plain bool
	var cipher bool
	var hash bool

	plain, cipher, hash = false, false, false
	var unsafe bool = false
	for name, target := range map[string]*bool{"passphrase.txt": &plain, "passphrase.tle": &cipher, "passphrase.sha256": &hash} {
		var err error

		_, err = os.Lstat(a.path(name))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			unsafe = true
			continue
		}
		*target = true
		if _, err = privateInfo(a.path(name), false); err != nil {
			unsafe = true
		}
	}
	var entries []os.DirEntry

	entries, err = os.ReadDir(a.Config.StateDir)
	if err != nil {
		unsafe = true
	}
	for _, entry := range entries {
		if entry.Name() == "passphrase-new.txt" || strings.HasPrefix(entry.Name(), ".stage-") || strings.HasPrefix(entry.Name(), ".lock-") || strings.HasPrefix(entry.Name(), ".unlock-recovery.") {
			unsafe = true
		}
	}
	if unsafe {
		a.Report("INCONSISTENT: unsafe recovery metadata or staged recovery material exists")
		return nil
	}
	switch {
	case s.Locked && info.Locked && info.MountPoint == "" && !plain && cipher && hash:
		a.Report("LOCKED until %s", deadline.Format(time.Unix(*s.DeadlineEpoch, 0), a.Now()))
	case !s.Locked && !info.Locked && info.MountPoint == a.Config.MountPoint && plain:
		a.Report("UNLOCKED at %s", info.MountPoint)
	case !s.Locked && plain && hash:
		a.Report("REPAIRABLE: run vaultlock unlock")
	default:
		a.Report("INCONSISTENT: recorded and observed vault states differ")
	}
	if a.Options.Verbosity > 0 {
		a.Report("Recorded locked: %t\nAPFS locked: %t\nDevice: %s\nMount: %s\nExpected mount: %s\nPlaintext: %t\nCiphertext: %t\nHash: %t", s.Locked, info.Locked, info.Device, info.MountPoint, a.Config.MountPoint, plain, cipher, hash)
		if s.Round != nil {
			a.Report("Target round: %d\nCurrent round: %d", *s.Round, timelock.Round(a.Now().Unix()))
		}
	}
	return nil
}
