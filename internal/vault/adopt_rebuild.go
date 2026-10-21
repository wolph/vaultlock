package vault

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type adoptRebuildStage struct {
	path                string
	root                *os.Root
	replacement         *os.Root
	identity            adoptMetadata
	replacementIdentity adoptMetadata
}

func prepareAdoptRebuild(plan adoptPlan) (*adoptRebuildStage, error) {
	var stage *adoptRebuildStage = &adoptRebuildStage{}
	var err error
	stage.path, err = os.MkdirTemp(filepath.Dir(plan.Destination), ".vaultlock-adopt-backup-")
	if err != nil {
		return stage, err
	}
	stage.identity, err = adoptStat(stage.path)
	if err != nil {
		return stage, err
	}
	if stage.identity.Device != plan.MountIdentity.Device || !adoptPrivate(stage.identity) {
		return stage, errors.New("adoption backup directory has unsafe permissions, ACLs or filesystem")
	}
	stage.root, err = openAdoptCopyRoot(stage.path)
	if err != nil {
		return stage, err
	}
	if err = checkAdoptRootEntry(stage.root, ".", stage.identity); err != nil {
		return stage, err
	}
	if err = stage.root.Mkdir("replacement", 0700); err == nil {
		stage.replacement, err = stage.root.OpenRoot("replacement")
	}
	if err == nil {
		stage.replacementIdentity, err = adoptStat(filepath.Join(stage.path, "replacement"))
	}
	if err == nil {
		err = checkAdoptRootEntry(stage.replacement, ".", stage.replacementIdentity)
	}
	return stage, err
}

func (stage *adoptRebuildStage) close() {
	if stage.replacement != nil {
		stage.replacement.Close()
	}
	if stage.root != nil {
		stage.root.Close()
	}
}

func (a *App) rebuildExistingAdopt(ctx context.Context, plan adoptPlan, original adoptManifest, existing adoptManifest, progress *adoptProgress) (adoptPlan, error) {
	if err := a.checkAdopt(ctx, plan); err != nil {
		return plan, err
	}
	if err := progress.checkMutation(); err != nil {
		return plan, err
	}
	var stage *adoptRebuildStage
	var err error
	stage, err = prepareAdoptRebuild(plan)
	defer stage.close()
	plan.AdoptBackup = stage.path
	if err != nil {
		return plan, err
	}
	a.Report("Adoption staging and backup directory: %s", stage.path)
	if err = buildAdoptReplacement(ctx, plan, original, existing, stage, progress); err != nil {
		return plan, err
	}
	var verified adoptManifest
	verified, err = verifyAdoptReplacement(ctx, plan, original, existing, stage, progress)
	if err != nil {
		return plan, err
	}
	return a.publishAdoptReplacement(ctx, plan, stage, verified, progress)
}

func buildAdoptReplacement(ctx context.Context, plan adoptPlan, original adoptManifest, existing adoptManifest, stage *adoptRebuildStage, progress *adoptProgress) error {
	var source *os.Root
	var previous *os.Root
	var err error
	source, err = openAdoptCopyRoot(plan.Source)
	if err != nil {
		return err
	}
	defer source.Close()
	previous, err = openAdoptCopyRoot(plan.Destination)
	if err != nil {
		return err
	}
	defer previous.Close()
	var builder adoptRebuilder = adoptRebuilder{source: source, previous: previous, target: stage.replacement, existing: existing, progress: progress}
	if err = builder.build(ctx, original); err != nil {
		return err
	}
	var replacementPlan adoptPlan = plan
	replacementPlan.Destination = filepath.Join(stage.path, "replacement")
	return restoreAdoptCopyRoot(ctx, stage.replacement, replacementPlan, original, progress)
}

func verifyAdoptReplacement(ctx context.Context, plan adoptPlan, original adoptManifest, existing adoptManifest, stage *adoptRebuildStage, progress *adoptProgress) (adoptManifest, error) {
	progress.phasePasses("Verify rebuilt authoritative copy", 2)
	var verified adoptManifest
	var err error
	verified, err = adoptMatchesManifest(ctx, filepath.Join(stage.path, "replacement"), original, progress, false)
	if err != nil {
		return verified, err
	}
	if !adoptIdentityEqual(verified.Entries[0].Metadata, stage.replacementIdentity) {
		return verified, errors.New("replacement root changed during verification")
	}
	progress.phasePasses("Recheck source before installing rebuilt copy", 2)
	if _, err = adoptMatchesManifest(ctx, plan.Source, original, progress, true); err != nil {
		return verified, err
	}
	var verification *adoptProgress = progress.activity("Recheck previous destination before retaining it")
	verification.passCount = 2
	defer verification.finish()
	if _, err = adoptMatchesManifest(ctx, plan.Destination, existing, verification, true); err != nil {
		return verified, err
	}
	verification.complete()
	return verified, nil
}

func (a *App) publishAdoptReplacement(ctx context.Context, plan adoptPlan, stage *adoptRebuildStage, verified adoptManifest, progress *adoptProgress) (updated adoptPlan, result error) {
	updated = plan
	if result = a.checkAdopt(ctx, plan); result != nil {
		return
	}
	if result = checkAdoptReservation(stage.path, stage.identity); result != nil {
		return
	}
	var mounted *os.Root
	mounted, result = openAdoptCopyRoot(filepath.Dir(plan.Destination))
	if result != nil {
		return
	}
	defer mounted.Close()
	progress.phase("Retain previous destination and install verified source copy")
	if result = progress.checkMutation(); result != nil {
		return
	}
	if result = ctx.Err(); result != nil {
		return
	}
	if result = installAdoptReplacement(mounted, plan, stage, verified); result != nil {
		return
	}
	var identity adoptMetadata = verified.Entries[0].Metadata
	updated.DestinationIdentity = &identity
	a.Report("Previous destination retained at %s", filepath.Join(stage.path, "original"))
	return
}

func checkAdoptRootEntry(rooted *os.Root, path string, wanted adoptMetadata) error {
	var file *os.File
	var err error
	file, err = adoptOpenMetadataFile(rooted, path)
	if err != nil {
		return err
	}
	defer file.Close()
	var actual adoptCopyIdentity
	actual, err = adoptCheckCopyFile(file, wanted, wanted.Device)
	if err != nil || actual != (adoptCopyIdentity{Device: wanted.Device, Inode: wanted.Inode}) {
		return fmt.Errorf("adoption directory identity changed: %q", path)
	}
	return nil
}

func installAdoptReplacement(mounted *os.Root, plan adoptPlan, stage *adoptRebuildStage, verified adoptManifest) (result error) {
	var name string = filepath.Base(plan.Destination)
	if result = checkAdoptRootEntry(mounted, ".", plan.MountIdentity); result != nil {
		return
	}
	if result = checkAdoptRootEntry(mounted, name, *plan.DestinationIdentity); result != nil {
		return
	}
	if result = checkAdoptRootEntry(stage.root, ".", stage.identity); result != nil {
		return
	}
	if result = checkAdoptRootEntry(stage.root, "replacement", verified.Entries[0].Metadata); result != nil {
		return
	}
	if result = adoptRenamePinned(mounted, name, stage.root, "original"); result != nil {
		return
	}
	var installed bool
	defer func() {
		if result != nil && !installed {
			var rollbackErr error = checkAdoptRootEntry(stage.root, "original", *plan.DestinationIdentity)
			if rollbackErr == nil {
				rollbackErr = adoptRenamePinned(stage.root, "original", mounted, name)
			}
			if rollbackErr != nil {
				result = fmt.Errorf("%w. Previous destination retained in backup, restoration failed: %v", result, rollbackErr)
			}
		}
	}()
	if result = checkAdoptRootEntry(stage.root, "original", *plan.DestinationIdentity); result != nil {
		return
	}
	if result = checkAdoptRootEntry(stage.root, "replacement", verified.Entries[0].Metadata); result != nil {
		return
	}
	if result = adoptRenamePinned(stage.root, "replacement", mounted, name); result != nil {
		return
	}
	installed = true
	return checkAdoptRootEntry(mounted, name, verified.Entries[0].Metadata)
}
