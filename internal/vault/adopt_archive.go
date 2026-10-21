package vault

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type adoptArchiveHeader struct {
	Version     int    `json:"version"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Scope       string `json:"scope"`
	Digest      string `json:"portable_digest"`
	Entries     int    `json:"entries"`
	Policy      string `json:"metadata_policy"`
}

func (a *App) archiveAdoptMetadata(ctx context.Context, plan adoptPlan, source adoptManifest, previous adoptManifest, progress *adoptProgress) (path string, result error) {
	if result = a.checkAdopt(ctx, plan); result != nil {
		return
	}
	if result = progress.checkMutation(); result != nil {
		return
	}
	path, result = os.MkdirTemp(filepath.Dir(plan.Destination), ".vaultlock-adopt-metadata-")
	if result != nil {
		return
	}
	var identity adoptMetadata
	identity, result = adoptStat(path)
	if result != nil {
		return
	}
	if identity.Device != plan.MountIdentity.Device || !adoptPrivate(identity) {
		return path, errors.New("metadata archive directory has unsafe permissions, ACLs or filesystem")
	}
	var root *os.Root
	root, result = openAdoptCopyRoot(path)
	if result != nil {
		return
	}
	defer root.Close()
	if result = checkAdoptRootEntry(root, ".", identity); result != nil {
		return
	}
	if result = writeAdoptArchive(ctx, root, "source", plan, source, progress); result != nil {
		return
	}
	if len(previous.Entries) > 0 {
		if result = writeAdoptArchive(ctx, root, "previous", plan, previous, progress); result != nil {
			return
		}
	}
	var directory *os.File
	directory, result = root.Open(".")
	if result != nil {
		return
	}
	result = errors.Join(directory.Sync(), directory.Close())
	if result == nil {
		result = syncDirectory(filepath.Dir(path))
	}
	if result == nil {
		a.Report("Original metadata archived at %s. OS-managed provenance may differ on the copy", path)
	}
	return
}

func writeAdoptArchive(ctx context.Context, root *os.Root, scope string, plan adoptPlan, manifest adoptManifest, progress *adoptProgress) (result error) {
	var task *adoptProgress = progress.activity("Archive original " + scope + " metadata and SHA-256 hashes")
	task.task.SetTotal(0, int64(len(manifest.Entries)))
	defer func() {
		if result == nil {
			task.complete()
		} else {
			task.finish()
		}
	}()
	var file *os.File
	file, result = root.OpenFile(scope+".jsonl", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if result != nil {
		return
	}
	defer func() { result = errors.Join(result, file.Close()) }()
	var buffer *bufio.Writer = bufio.NewWriterSize(file, 1024*1024)
	var encoder *json.Encoder = json.NewEncoder(buffer)
	var header adoptArchiveHeader = adoptArchiveHeader{Version: 1, Source: plan.Source, Destination: plan.Destination, Scope: scope, Digest: manifest.Digest, Entries: len(manifest.Entries), Policy: "Original complete metadata retained. Portable verification excludes OS-managed com.apple.provenance"}
	if result = encoder.Encode(header); result != nil {
		return
	}
	var item adoptEntry
	for _, item = range manifest.Entries {
		if result = ctx.Err(); result != nil {
			return
		}
		task.current("archive original metadata", item.Path)
		if result = encoder.Encode(item); result != nil {
			return fmt.Errorf("archive metadata for %q: %w", item.Path, result)
		}
		task.tick(0, item.Path)
	}
	if result = buffer.Flush(); result != nil {
		return
	}
	return file.Sync()
}
