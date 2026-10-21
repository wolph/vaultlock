package vault

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
)

func existingAdoptDestination(path string) (*adoptMetadata, error) {
	var metadata adoptMetadata
	var err error
	metadata, err = adoptStat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if metadata.Mode&0170000 != 0040000 {
		return nil, fmt.Errorf("destination already exists and is not a real directory: %s", path)
	}
	return &metadata, nil
}

func (a *App) verifyExistingAdopt(ctx context.Context, plan adoptPlan, original adoptManifest, progress *adoptProgress) (adoptManifest, error) {
	var actual adoptMetadata
	var err error
	actual, err = adoptStat(plan.Destination)
	if err != nil || !adoptIdentityEqual(actual, *plan.DestinationIdentity) {
		return adoptManifest{}, errors.New("existing destination identity changed before verification")
	}
	// Its totals can differ from the source. Count entries while verifying it.
	var verification *adoptProgress = progress.activity("Verify existing vault directory before reuse")
	verification.passCount = 2
	defer verification.finish()
	var existing adoptManifest
	existing, err = stableAdoptManifest(ctx, plan.Destination, verification)
	if err != nil {
		return existing, fmt.Errorf("cannot verify existing destination, both directories retained: %w", err)
	}
	if !adoptIdentityEqual(existing.Entries[0].Metadata, *plan.DestinationIdentity) {
		return existing, errors.New("existing destination identity changed during verification")
	}
	if original.Digest != existing.Digest {
		a.Report("Existing destination differs. Source is authoritative: %s", adoptDifferenceSummary(original, existing))
		a.Report("The previous destination will be retained in a private backup before installing the verified replacement")
	} else {
		a.Report("Existing destination verified. Reuse the identical copy without copying again")
	}
	verification.complete()
	return existing, nil
}

func adoptDifferenceSummary(source adoptManifest, destination adoptManifest) string {
	var indexed map[string]int = make(map[string]int, len(destination.Entries))
	var item adoptEntry
	var index int
	for index, item = range destination.Entries {
		indexed[item.Path] = index
	}
	var count int
	var examples []string
	var categories map[string]int = make(map[string]int)
	var record func(string, string) = func(kind string, path string) {
		count++
		categories[kind]++
		if categories[kind] == 1 {
			examples = append(examples, fmt.Sprintf("%s: %q", kind, path))
		}
	}
	for _, item = range source.Entries {
		var target adoptEntry
		var found bool
		index, found = indexed[item.Path]
		if found {
			target = destination.Entries[index]
		}
		delete(indexed, item.Path)
		if !found {
			record("missing", item.Path)
		} else if item.Metadata.Mode&0170000 != target.Metadata.Mode&0170000 {
			record("file type", item.Path)
		} else if item.Payload != target.Payload {
			record("content", item.Path)
		} else if item.Hardlink != target.Hardlink {
			record("hardlinks", item.Path)
		} else if !reflect.DeepEqual(comparableAdoptEntry(item), comparableAdoptEntry(target)) {
			record("metadata", item.Path)
		}
	}
	for _, item = range destination.Entries {
		if _, found := indexed[item.Path]; found {
			record("extra", item.Path)
		}
	}
	var totals []string
	var kind string
	for _, kind = range []string{"missing", "extra", "file type", "content", "hardlinks", "metadata"} {
		if categories[kind] > 0 {
			totals = append(totals, fmt.Sprintf("%s=%d", kind, categories[kind]))
		}
	}
	return fmt.Sprintf("%d differences (%s). Examples: %s", count, strings.Join(totals, ", "), strings.Join(examples, ", "))
}

func (a *App) copyNewAdopt(ctx context.Context, plan adoptPlan, original adoptManifest, progress *adoptProgress) error {
	if err := adoptAbsent(plan.Destination); err != nil {
		return err
	}
	progress.phase("Copy source into vault")
	if err := a.copyAdopt(ctx, plan.Source, plan.Destination, progress); err != nil {
		return fmt.Errorf("copy failed, source remains at %s and partial copy may remain at %s: %w", plan.Source, plan.Destination, err)
	}
	return restoreAdoptCopy(ctx, plan, original, progress)
}
