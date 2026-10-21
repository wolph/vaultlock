package vault

import (
	"context"
	"errors"
	"fmt"
	"os"
)

type adoptCopyIdentity struct {
	Device uint64
	Inode  uint64
}

func openAdoptCopyRoot(path string) (*os.Root, error) {
	var before os.FileInfo
	var err error
	before, err = os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !before.IsDir() {
		return nil, errors.New("copied destination is no longer a real directory")
	}
	var rooted *os.Root
	rooted, err = os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	var opened os.FileInfo
	opened, err = rooted.Stat(".")
	if err != nil || !os.SameFile(before, opened) {
		rooted.Close()
		return nil, errors.New("copied destination identity changed before metadata restoration")
	}
	return rooted, nil
}

func restoreAdoptCopy(ctx context.Context, plan adoptPlan, original adoptManifest, progress *adoptProgress) error {
	var rooted *os.Root
	var err error
	rooted, err = openAdoptCopyRoot(plan.Destination)
	if err != nil {
		return err
	}
	defer rooted.Close()
	return restoreAdoptCopyRoot(ctx, rooted, plan, original, progress)
}

func restoreAdoptCopyRoot(ctx context.Context, rooted *os.Root, plan adoptPlan, original adoptManifest, progress *adoptProgress) error {
	var identities []adoptCopyIdentity
	var err error
	identities, err = inspectAdoptCopy(ctx, rooted, original, plan.MountIdentity.Device, progress)
	if err != nil {
		return err
	}
	progress.phase(adoptMetadataPhase)
	var index int
	for index = len(original.Entries) - 1; index >= 0; index-- {
		if err = ctx.Err(); err != nil {
			return err
		}
		var item adoptEntry = original.Entries[index]
		progress.current("metadata and timestamps", item.Path)
		if err = restoreAdoptEntry(ctx, rooted, item, identities[index], plan.MountIdentity.Device); err != nil {
			return fmt.Errorf("cannot preserve native metadata for %q, source remains at %s: %w", item.Path, plan.Source, err)
		}
		progress.tick(0, item.Path)
	}
	return nil
}

func inspectAdoptCopy(ctx context.Context, rooted *os.Root, original adoptManifest, device uint64, progress *adoptProgress) ([]adoptCopyIdentity, error) {
	progress.phase(adoptIdentityPhase)
	var identities []adoptCopyIdentity = make([]adoptCopyIdentity, len(original.Entries))
	var groups map[string]adoptCopyIdentity = make(map[string]adoptCopyIdentity)
	var index int
	var item adoptEntry
	for index, item = range original.Entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var file *os.File
		var err error
		progress.current("pin copied entry", item.Path)
		file, err = adoptOpenMetadataFile(rooted, item.Path)
		if err != nil {
			return nil, err
		}
		identities[index], err = adoptCheckCopyFile(file, item.Metadata, device)
		file.Close()
		if err != nil {
			return nil, err
		}
		if item.Metadata.Mode&0170000 == 0100000 && item.Metadata.Nlink > 1 {
			var previous adoptCopyIdentity
			var found bool
			previous, found = groups[item.Hardlink]
			if found && previous != identities[index] {
				return nil, fmt.Errorf("copied hardlink group changed: %q", item.Path)
			}
			groups[item.Hardlink] = identities[index]
		}
		progress.tick(0, item.Path)
	}
	return identities, nil
}

func restoreAdoptEntry(ctx context.Context, rooted *os.Root, item adoptEntry, expected adoptCopyIdentity, device uint64) error {
	var file *os.File
	var err error
	file, err = adoptOpenMetadataFile(rooted, item.Path)
	if err != nil {
		return err
	}
	defer file.Close()
	var actual adoptCopyIdentity
	actual, err = adoptCheckCopyFile(file, item.Metadata, device)
	if err != nil {
		return err
	}
	if actual != expected {
		return errors.New("copied entry identity changed before metadata restoration")
	}
	if err = adoptRestoreCopyPOSIXFile(ctx, file, item.Metadata); err != nil {
		return fmt.Errorf("restore ownership and permissions: %w", err)
	}
	if err = adoptRestoreCopyMetadataFile(file, item.Metadata); err != nil {
		return fmt.Errorf("restore extended attributes and ACL: %w", err)
	}
	if err = adoptRestoreCopyTimesFile(file, item.Metadata); err != nil {
		return fmt.Errorf("restore timestamps: %w", err)
	}
	if err = adoptRestoreCopyFlagsFile(file, item.Metadata); err != nil {
		return fmt.Errorf("restore filesystem flags: %w", err)
	}
	return nil
}
