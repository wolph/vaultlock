package vault

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
)

type adoptRebuilder struct {
	source   *os.Root
	previous *os.Root
	target   *os.Root
	existing adoptManifest
	indexed  map[string]int
	progress *adoptProgress
}

func (b *adoptRebuilder) build(ctx context.Context, original adoptManifest) error {
	b.indexed = make(map[string]int, len(b.existing.Entries))
	var index int
	var item adoptEntry
	for index, item = range b.existing.Entries {
		b.indexed[item.Path] = index
	}
	b.progress.phase("Reuse or copy authoritative source data")
	b.progress.task.SetTotal(b.progress.copyBytes, b.progress.sourceCount)
	for _, item = range original.Entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := b.buildEntry(ctx, item); err != nil {
			return fmt.Errorf("rebuild %q: %w", item.Path, err)
		}
	}
	return nil
}

func (b *adoptRebuilder) buildEntry(ctx context.Context, item adoptEntry) error {
	b.progress.current("prepare replacement", item.Path)
	var err error
	switch item.Metadata.Mode & 0170000 {
	case 0040000:
		if item.Path != "." {
			err = b.target.Mkdir(item.Path, 0700)
		}
	case 0120000:
		err = b.target.Symlink(item.Payload, item.Path)
	case 0100000:
		if item.Path != item.Hardlink {
			err = b.target.Link(item.Hardlink, item.Path)
		} else {
			var cloned bool
			cloned, err = b.cloneExisting(item)
			if err == nil && !cloned {
				err = b.copySource(ctx, item)
			}
			if err == nil && cloned {
				b.progress.add(item.Metadata.Size, 0, "clone verified vault data: "+item.Path)
			}
		}
	default:
		err = errors.New("unsupported source entry type")
	}
	if err == nil {
		b.progress.tick(0, item.Path)
	}
	return err
}

func openVerifiedAdoptFile(rooted *os.Root, item adoptEntry) (*os.File, error) {
	var file *os.File
	var err error
	file, err = adoptOpenMetadataFile(rooted, item.Path)
	if err != nil {
		return nil, err
	}
	var identity adoptCopyIdentity
	identity, err = adoptCheckCopyFile(file, item.Metadata, item.Metadata.Device)
	if err != nil || identity != (adoptCopyIdentity{Device: item.Metadata.Device, Inode: item.Metadata.Inode}) {
		file.Close()
		return nil, fmt.Errorf("verified input identity changed: %q", item.Path)
	}
	return file, nil
}

func (b *adoptRebuilder) cloneExisting(item adoptEntry) (bool, error) {
	var index int
	var found bool
	index, found = b.indexed[item.Path]
	if !found {
		return false, nil
	}
	var old adoptEntry = b.existing.Entries[index]
	if old.Metadata.Mode&0170000 != 0100000 || old.Payload != item.Payload {
		return false, nil
	}
	b.progress.current("clone verified vault data", item.Path)
	var input *os.File
	var err error
	input, err = openVerifiedAdoptFile(b.previous, old)
	if err != nil {
		return false, err
	}
	defer input.Close()
	return adoptCloneFile(input, b.target, item.Path)
}

func (b *adoptRebuilder) copySource(ctx context.Context, item adoptEntry) error {
	b.progress.current("copy source data", item.Path)
	var input *os.File
	var err error
	input, err = openVerifiedAdoptFile(b.source, item)
	if err != nil {
		return err
	}
	defer input.Close()
	var output *os.File
	output, err = b.target.OpenFile(item.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	var copied int64
	copied, err = io.Copy(output, adoptContextReader{Context: ctx, Reader: input, Progress: b.progress, Path: item.Path, Stage: "copy"})
	var closeErr error = output.Close()
	if err != nil || closeErr != nil {
		return errors.Join(err, closeErr)
	}
	if copied != item.Metadata.Size {
		return errors.New("source size changed during copy")
	}
	return nil
}
