package vault

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"unicode/utf8"
)

type adoptPlan struct {
	Source              string
	Parent              string
	Destination         string
	DestinationIdentity *adoptMetadata
	AdoptBackup         string
	MetadataArchive     string
	State               State
	Volume              VolumeInfo
	SourceIdentity      adoptMetadata
	ParentIdentity      adoptMetadata
	MountIdentity       adoptMetadata
	StateIdentity       adoptMetadata
	Recovery            observation
	Controls            map[string]adoptMetadata
}

func adoptContains(parent string, path string) bool {
	var relative string
	var err error
	relative, err = filepath.Rel(parent, path)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func adoptAbsent(path string) error {
	var err error
	_, err = os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("destination already exists: %s", path)
}

func (a *App) inspectAdopt(ctx context.Context, raw string) (adoptPlan, error) {
	var plan adoptPlan
	if raw == "" || strings.IndexFunc(raw, func(value rune) bool { return value < 32 || value == 127 }) >= 0 {
		return plan, errors.New("adopt source is empty or contains control characters")
	}
	if !utf8.ValidString(raw) {
		return plan, errors.New("adopt source path must be valid UTF-8")
	}
	var absolute string
	var err error
	absolute, err = filepath.Abs(raw)
	if err != nil {
		return plan, err
	}
	if absolute == string(filepath.Separator) {
		return plan, errors.New("cannot adopt the filesystem root")
	}
	plan.Parent, err = filepath.EvalSymlinks(filepath.Dir(absolute))
	if err != nil {
		return plan, err
	}
	plan.Source = filepath.Join(plan.Parent, filepath.Base(absolute))
	var info os.FileInfo
	info, err = os.Lstat(plan.Source)
	if err != nil {
		return plan, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return plan, errors.New("adopt source must be a real directory")
	}
	var home string
	home, err = filepath.EvalSymlinks(a.Config.Home)
	if err != nil {
		return plan, err
	}
	var operationLock string = filepath.Join(home, ".vaultlock-operation.lock")
	if adoptContains(plan.Source, operationLock) || adoptContains(operationLock, plan.Source) {
		return plan, errors.New("adopt source overlaps the reserved operation lock")
	}
	if adoptContains(plan.Source, home) {
		return plan, errors.New("cannot adopt the home directory or its parents")
	}
	var stateDir string
	stateDir, err = filepath.EvalSymlinks(a.Config.StateDir)
	if err != nil {
		return plan, err
	}
	if adoptContains(plan.Source, stateDir) || adoptContains(stateDir, plan.Source) {
		return plan, errors.New("adopt source overlaps the reserved vaultlock state directory")
	}
	var mount string
	mount, err = filepath.EvalSymlinks(a.Config.MountPoint)
	if err != nil {
		return plan, err
	}
	if adoptContains(plan.Source, mount) || adoptContains(mount, plan.Source) {
		return plan, errors.New("adopt source overlaps the mounted vault")
	}
	plan.Destination = filepath.Join(mount, filepath.Base(plan.Source))
	plan.DestinationIdentity, err = existingAdoptDestination(plan.Destination)
	if err != nil {
		return plan, err
	}
	plan.State, err = a.ReadState()
	if err != nil {
		return plan, err
	}
	if plan.State.Locked {
		return plan, errors.New("adopt requires an unlocked mounted vault")
	}
	plan.Volume, err = a.CheckMount(ctx, plan.State)
	if err != nil {
		return plan, err
	}
	if plan.Volume.Locked || plan.Volume.MountPoint != a.Config.MountPoint || !plan.Volume.FileVault {
		return plan, errors.New("adopt requires an unlocked encrypted vault at the configured mount point")
	}
	if _, err = a.plaintext(); err != nil {
		return plan, err
	}
	plan.Recovery, err = a.observe(ctx)
	if err != nil {
		return plan, err
	}
	plan.SourceIdentity, err = adoptStat(plan.Source)
	if err != nil {
		return plan, err
	}
	plan.ParentIdentity, err = adoptStat(plan.Parent)
	if err != nil {
		return plan, err
	}
	plan.MountIdentity, err = adoptStat(mount)
	if err != nil {
		return plan, err
	}
	if plan.DestinationIdentity != nil && plan.DestinationIdentity.Device != plan.MountIdentity.Device {
		return plan, errors.New("existing destination is outside the verified mounted filesystem")
	}
	plan.StateIdentity, err = adoptStat(stateDir)
	if err != nil {
		return plan, err
	}
	plan.Controls = make(map[string]adoptMetadata)
	var path string
	for _, path = range []string{filepath.Join(stateDir, "state.json"), operationLock} {
		var metadata adoptMetadata
		metadata, err = adoptStat(path)
		if errors.Is(err, os.ErrNotExist) && path == operationLock {
			continue
		}
		if err != nil {
			return plan, err
		}
		plan.Controls[path] = metadata
	}
	return plan, nil
}

func (a *App) checkAdopt(ctx context.Context, plan adoptPlan) error {
	if plan.DestinationIdentity != nil {
		var actual adoptMetadata
		var err error
		actual, err = adoptStat(plan.Destination)
		if err != nil || !adoptIdentityEqual(actual, *plan.DestinationIdentity) {
			return errors.New("existing destination identity changed during adoption")
		}
	}
	var path string
	var wanted adoptMetadata
	for path, wanted = range plan.Controls {
		var actual adoptMetadata
		var err error
		actual, err = adoptStat(path)
		if err != nil || !adoptIdentityEqual(wanted, actual) {
			return fmt.Errorf("reserved control identity changed: %s", path)
		}
	}
	var recoveryErr error = a.unchanged(ctx, plan.Recovery)
	if recoveryErr != nil {
		return recoveryErr
	}
	var current State
	var err error
	current, err = a.ReadState()
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(plan.State, current) {
		return errors.New("vault state changed during adoption")
	}
	var info VolumeInfo
	info, err = a.CheckMount(ctx, current)
	if err != nil {
		return err
	}
	if info.UUID != plan.Volume.UUID || info.Device != plan.Volume.Device || info.MountPoint != plan.Volume.MountPoint || info.Locked || !info.FileVault {
		return errors.New("mounted vault identity changed during adoption")
	}
	var item struct {
		Path     string
		Identity adoptMetadata
	}
	for _, item = range []struct {
		Path     string
		Identity adoptMetadata
	}{
		{plan.Parent, plan.ParentIdentity}, {a.Config.MountPoint, plan.MountIdentity}, {a.Config.StateDir, plan.StateIdentity},
	} {
		var actual adoptMetadata
		actual, err = adoptStat(item.Path)
		if err != nil {
			return err
		}
		if !adoptIdentityEqual(actual, item.Identity) {
			return fmt.Errorf("control or parent identity changed: %s", item.Path)
		}
	}
	return nil
}

func adoptMatchesManifest(ctx context.Context, path string, expected adoptManifest, progress *adoptProgress, identities bool) (adoptManifest, error) {
	var actual adoptManifest
	var err error
	actual, err = stableAdoptManifest(ctx, path, progress)
	if err != nil {
		return actual, err
	}
	if expected.Digest != actual.Digest {
		return actual, fmt.Errorf("directory data or metadata changed: %s. %s", path, adoptDifferenceSummary(expected, actual))
	}
	if identities {
		var index int
		for index = range expected.Entries {
			if !adoptIdentityEqual(expected.Entries[index].Metadata, actual.Entries[index].Metadata) {
				return actual, fmt.Errorf("entry identity changed: %s", path)
			}
		}
	}
	return actual, nil
}

func (a *App) adopt(ctx context.Context, source string) (result error) {
	var plan adoptPlan
	var err error
	plan, err = a.inspectAdopt(ctx, source)
	if err != nil {
		return err
	}
	defer func() {
		if result != nil && plan.AdoptBackup != "" {
			result = fmt.Errorf("%w. Adoption backup and staging directory retained at %s", result, plan.AdoptBackup)
		}
		if result != nil && plan.MetadataArchive != "" {
			result = fmt.Errorf("%w. Original metadata archive retained at %s", result, plan.MetadataArchive)
		}
	}()
	a.Report("Adopt %s into %s", plan.Source, plan.Destination)
	if a.Options.DryRun {
		if plan.DestinationIdentity != nil {
			a.Report("Verify both directories. Reuse identical data, build differences from the authoritative source, and retain the previous destination in a private backup before replacing the source with a symlink")
		} else {
			a.Report("Copy with macOS ditto, verify content, metadata and hardlinks, then replace source with a symlink")
		}
		return nil
	}
	var progress *adoptProgress = a.adoptionProgress()
	defer progress.finish()
	progress.scan(ctx, plan.Source)
	progress.phasePasses("Manifest source", 2)
	var original adoptManifest
	original, err = stableAdoptManifest(ctx, plan.Source, progress)
	if err != nil {
		return fmt.Errorf("cannot verify source, source remains at %s: %w", plan.Source, err)
	}
	progress.manifestTotals(original)
	progress.complete()
	var existing adoptManifest
	var confirmation string = "Copy the directory into the vault and replace it with a symlink?"
	if plan.DestinationIdentity != nil {
		existing, err = a.verifyExistingAdopt(ctx, plan, original, progress)
		if err != nil {
			return err
		}
		if existing.Digest == original.Digest {
			confirmation = "The existing vault directory is identical. Replace the source with a symlink to that verified copy?"
		} else {
			confirmation = "Rebuild the vault copy from the source, preserve the previous destination in a private backup, and replace the verified source with a symlink?"
		}
	}
	if err = a.confirm(confirmation); err != nil {
		return err
	}
	if err = a.checkAdopt(ctx, plan); err != nil {
		return err
	}
	progress.phasePasses("Recheck source after confirmation", 2)
	if _, err = adoptMatchesManifest(ctx, plan.Source, original, progress, true); err != nil {
		return err
	}
	if plan.DestinationIdentity != nil {
		progress.phasePasses("Recheck existing destination after confirmation", 2)
		if _, err = adoptMatchesManifest(ctx, plan.Destination, existing, progress, true); err != nil {
			return err
		}
	}
	plan.MetadataArchive, err = a.archiveAdoptMetadata(ctx, plan, original, existing, progress)
	if err != nil {
		return err
	}
	if plan.DestinationIdentity != nil {
		if existing.Digest != original.Digest {
			plan, err = a.rebuildExistingAdopt(ctx, plan, original, existing, progress)
			if err != nil {
				return err
			}
		}
	} else if err = a.copyNewAdopt(ctx, plan, original, progress); err != nil {
		return err
	}
	if err = a.checkAdopt(ctx, plan); err != nil {
		return err
	}
	progress.phasePasses("Verify copied source", 6)
	if _, err = adoptMatchesManifest(ctx, plan.Source, original, progress, true); err != nil {
		return err
	}
	var copied adoptManifest
	copied, err = adoptMatchesManifest(ctx, plan.Destination, original, progress, false)
	if err != nil {
		return fmt.Errorf("copy verification failed, source remains at %s: %w", plan.Source, err)
	}
	if copied.Entries[0].Metadata.Device != plan.MountIdentity.Device {
		return errors.New("copied destination is outside the verified mounted filesystem")
	}
	if _, err = adoptMatchesManifest(ctx, plan.Source, original, progress, true); err != nil {
		return err
	}
	progress.phasePasses("Replace source with vault symlink", 11)
	return a.replaceAdoptSource(ctx, plan, original, copied, progress)
}

func adoptPrivate(meta adoptMetadata) bool {
	if meta.Mode&07777 != 0700 || meta.UID != uint32(os.Getuid()) {
		return false
	}
	return len(meta.ACL) == 0 || (len(meta.ACL) >= 44 && binary.LittleEndian.Uint32(meta.ACL[36:40]) == ^uint32(0))
}

func (a *App) replaceAdoptSource(ctx context.Context, plan adoptPlan, original adoptManifest, copied adoptManifest, progress *adoptProgress) (result error) {
	var initialErr error = a.checkAdopt(ctx, plan)
	if initialErr != nil {
		return initialErr
	}
	var reservation string
	var err error
	progress.current("reserve private backup", plan.Parent)
	if err = progress.checkMutation(); err != nil {
		return err
	}
	reservation, err = os.MkdirTemp(plan.Parent, ".vaultlock-backup-")
	if err != nil {
		return err
	}
	var reservationIdentity adoptMetadata
	reservationIdentity, err = adoptStat(reservation)
	if err != nil {
		return err
	}
	if !adoptPrivate(reservationIdentity) {
		return fmt.Errorf("backup directory has inherited ACLs or unsafe permissions, retained at %s", reservation)
	}
	var backup string = filepath.Join(reservation, "original")
	var staged string = filepath.Join(reservation, "link")
	var moved bool
	var installed bool
	var deleting bool
	var committed bool
	var linkIdentity adoptMetadata
	defer func() {
		if result == nil {
			return
		}
		if committed {
			result = fmt.Errorf("%w. Replacement installed at %s, copied data remains at %s", result, plan.Source, plan.Destination)
			return
		}
		if moved && !deleting {
			var rollbackTask *adoptProgress = progress.activity("Restore original source after failure")
			var rollbackErr error = rollbackAdopt(plan, backup, linkIdentity, installed)
			if rollbackErr == nil {
				rollbackTask.complete()
			} else {
				rollbackTask.finish()
			}
			if rollbackErr != nil {
				result = fmt.Errorf("%w. Original retained at %s, rollback failed: %v", result, backup, rollbackErr)
				return
			}
			moved = false
		}
		if deleting {
			result = fmt.Errorf("%w. Copied data remains at %s, inspect remaining original data at %s", result, plan.Destination, backup)
			return
		}
		if !moved {
			var actual adoptMetadata
			actual, err = adoptStat(reservation)
			if err == nil && adoptIdentityEqual(actual, reservationIdentity) {
				var stagedInfo adoptMetadata
				var stagedErr error
				stagedInfo, stagedErr = adoptStat(staged)
				if stagedErr == nil && adoptIdentityEqual(stagedInfo, linkIdentity) {
					_ = os.Remove(staged)
				}
				_ = os.Remove(reservation)
			}
		}
	}()
	if err = progress.checkMutation(); err != nil {
		return err
	}
	if err = os.Symlink(plan.Destination, staged); err != nil {
		return err
	}
	linkIdentity, err = adoptStat(staged)
	if err != nil {
		return err
	}
	if _, err = adoptMatchesManifest(ctx, plan.Source, original, progress, true); err != nil {
		return err
	}
	if err = a.checkAdopt(ctx, plan); err != nil {
		return err
	}
	if err = checkAdoptReservation(reservation, reservationIdentity); err != nil {
		return err
	}
	progress.current("quarantine original", plan.Source)
	if err = progress.checkMutation(); err != nil {
		return err
	}
	if err = adoptRenameExclusive(plan.Source, backup); err != nil {
		return err
	}
	moved = true
	if _, err = adoptMatchesManifest(ctx, backup, original, progress, true); err != nil {
		return err
	}
	if err = a.checkAdopt(ctx, plan); err != nil {
		return err
	}
	if err = checkAdoptReservation(reservation, reservationIdentity); err != nil {
		return err
	}
	progress.current("install symlink", plan.Source)
	if err = progress.checkMutation(); err != nil {
		return err
	}
	if err = adoptRenameExclusive(staged, plan.Source); err != nil {
		return err
	}
	installed = true
	if err = verifyAdoptLink(plan.Source, plan.Destination, linkIdentity); err != nil {
		return err
	}
	if _, err = adoptMatchesManifest(ctx, plan.Destination, copied, progress, true); err != nil {
		return err
	}
	if _, err = adoptMatchesManifest(ctx, backup, original, progress, true); err != nil {
		return err
	}
	if err = a.checkAdopt(ctx, plan); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = checkAdoptReservation(reservation, reservationIdentity); err != nil {
		return err
	}
	deleting = true
	if err = removeAdoptOriginal(ctx, backup, original, progress); err != nil {
		return err
	}
	moved = false
	committed = true
	if err = progress.checkMutation(); err != nil {
		return err
	}
	if err = os.Remove(reservation); err != nil {
		return err
	}
	deleting = false
	if err = verifyAdoptLink(plan.Source, plan.Destination, linkIdentity); err != nil {
		return err
	}
	if _, err = adoptMatchesManifest(ctx, plan.Destination, copied, progress, true); err != nil {
		return err
	}
	if err = a.checkAdopt(ctx, plan); err != nil {
		return err
	}
	progress.complete()
	a.Report("Adopted %s -> %s", plan.Source, plan.Destination)
	return nil
}

func verifyAdoptLink(path string, target string, identity adoptMetadata) error {
	var actual adoptMetadata
	var err error
	actual, err = adoptStat(path)
	if err != nil {
		return err
	}
	if !adoptIdentityEqual(actual, identity) || actual.Mode&0170000 != 0120000 {
		return errors.New("replacement symlink identity changed")
	}
	var actualTarget string
	actualTarget, err = os.Readlink(path)
	if err != nil {
		return err
	}
	if actualTarget != target {
		return errors.New("replacement symlink target changed")
	}
	return nil
}

func rollbackAdopt(plan adoptPlan, backup string, linkIdentity adoptMetadata, installed bool) error {
	var actual adoptMetadata
	var err error
	actual, err = adoptStat(plan.Parent)
	if err != nil || !adoptIdentityEqual(actual, plan.ParentIdentity) {
		return errors.New("source parent identity changed")
	}
	actual, err = adoptStat(backup)
	if err != nil || !adoptIdentityEqual(actual, plan.SourceIdentity) {
		return errors.New("backup identity changed")
	}
	if installed {
		if err = verifyAdoptLink(plan.Source, plan.Destination, linkIdentity); err != nil {
			return err
		}
		if err = os.Remove(plan.Source); err != nil {
			return err
		}
	}
	if err = adoptAbsent(plan.Source); err != nil {
		return err
	}
	return adoptRenameExclusive(backup, plan.Source)
}

func removeAdoptOriginal(ctx context.Context, root string, manifest adoptManifest, progress *adoptProgress) (result error) {
	var pass *adoptProgress = progress.pass(root)
	if pass != nil {
		progress = pass
		defer func() {
			if result == nil {
				pass.complete()
			} else {
				pass.finish()
			}
		}()
	}
	progress.current("open verified original", ".")
	var rooted *os.Root
	var err error
	rooted, err = os.OpenRoot(root)
	if err != nil {
		return err
	}
	defer rooted.Close()
	var index int
	for index = len(manifest.Entries) - 1; index > 0; index-- {
		if err = ctx.Err(); err != nil {
			return err
		}
		var item adoptEntry = manifest.Entries[index]
		var actual adoptMetadata
		progress.current("metadata", item.Path)
		actual, err = adoptStat(filepath.Join(root, item.Path))
		if err != nil {
			return err
		}
		if !adoptIdentityEqual(actual, item.Metadata) {
			return fmt.Errorf("backup entry identity changed: %s", item.Path)
		}
		if err = verifyAdoptDeletion(ctx, rooted, root, item, actual, progress); err != nil {
			return err
		}
		// Replacing or adding entries cannot make Remove recursively delete unverified data.
		if err = progress.checkMutation(); err != nil {
			return err
		}
		if err = rooted.Remove(item.Path); err != nil {
			return err
		}
		progress.tick(0, item.Path)
	}
	var actual adoptMetadata
	actual, err = adoptStat(root)
	if err != nil || !adoptIdentityEqual(actual, manifest.Entries[0].Metadata) {
		return errors.New("backup root identity changed before removal")
	}
	if err = verifyAdoptDeletion(ctx, rooted, root, manifest.Entries[0], actual, progress); err != nil {
		return err
	}
	if err = progress.checkMutation(); err != nil {
		return err
	}
	var removeErr error = os.Remove(root)
	if removeErr == nil {
		progress.tick(0, ".")
	}
	return removeErr
}

func checkAdoptReservation(path string, wanted adoptMetadata) error {
	var actual adoptMetadata
	var err error
	actual, err = adoptStat(path)
	if err != nil {
		return err
	}
	if !adoptIdentityEqual(actual, wanted) || !adoptPrivate(actual) {
		return fmt.Errorf("private backup directory identity or permissions changed: %s", path)
	}
	return nil
}
