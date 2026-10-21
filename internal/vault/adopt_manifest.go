package vault

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"unicode/utf8"
)

type adoptXattr struct {
	Name  string
	Value []byte
}
type adoptMetadata struct {
	Device   uint64
	Inode    uint64
	Mode     uint16
	UID      uint32
	GID      uint32
	Size     int64
	Nlink    uint64
	Flags    uint32
	MtimeSec int64
	MtimeNS  int64
	BirthSec int64
	BirthNS  int64
	CtimeSec int64
	CtimeNS  int64
	ACL      []byte
	Xattrs   []adoptXattr
}
type adoptEntry struct {
	Path     string
	Metadata adoptMetadata
	Payload  string
	Hardlink string
}
type adoptManifest struct {
	Digest  string
	Entries []adoptEntry
}

func comparableAdoptEntry(item adoptEntry) adoptEntry {
	// Device and inode differ after copying. Change time is local bookkeeping.
	item.Metadata.Device = 0
	item.Metadata.Inode = 0
	item.Metadata.CtimeSec = 0
	item.Metadata.CtimeNS = 0
	item.Metadata.Xattrs = portableAdoptXattrs(item.Metadata.Xattrs)
	if item.Metadata.Mode&0170000 == 0040000 {
		item.Metadata.Size = 0
		item.Metadata.Nlink = 0
	}
	return item
}

func adoptStat(path string) (adoptMetadata, error) {
	var info os.FileInfo
	var err error
	info, err = os.Lstat(path)
	if err != nil {
		return adoptMetadata{}, err
	}
	return adoptNativeMetadata(path, info)
}

func adoptIdentityEqual(left adoptMetadata, right adoptMetadata) bool {
	return left.Device == right.Device && left.Inode == right.Inode
}

func buildAdoptManifest(ctx context.Context, root string, progress *adoptProgress) (result adoptManifest, finalErr error) {
	var pass *adoptProgress = progress.pass(root)
	if pass != nil {
		progress = pass
		defer func() {
			if finalErr == nil {
				pass.complete()
			} else {
				pass.finish()
			}
		}()
	}
	progress.current("metadata", ".")
	var info os.FileInfo
	var err error
	info, err = os.Lstat(root)
	if err != nil {
		return result, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return result, errors.New("adopt source must be a real directory")
	}
	var rootMeta adoptMetadata
	rootMeta, err = adoptNativeMetadata(root, info)
	if err != nil {
		return result, err
	}
	var rooted *os.Root
	rooted, err = os.OpenRoot(root)
	if err != nil {
		return result, err
	}
	defer rooted.Close()
	var groups map[[2]uint64][]int = make(map[[2]uint64][]int)
	err = fs.WalkDir(rooted.FS(), ".", func(relative string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !utf8.ValidString(relative) {
			return fmt.Errorf("cannot safely archive a non-UTF-8 entry path: %q", relative)
		}
		var contextErr error = ctx.Err()
		if contextErr != nil {
			return contextErr
		}
		var path string = filepath.Join(root, relative)
		var before adoptMetadata
		var readErr error
		progress.current("metadata", relative)
		before, readErr = adoptStat(path)
		if readErr != nil {
			return readErr
		}
		if before.Device != rootMeta.Device {
			return fmt.Errorf("nested filesystem at %s", path)
		}
		var item adoptEntry = adoptEntry{Path: relative, Metadata: before}
		switch {
		case entry.Type().IsRegular():
			var file *os.File
			file, readErr = rooted.OpenFile(relative, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
			if readErr != nil {
				return readErr
			}
			var current os.FileInfo
			current, readErr = file.Stat()
			if readErr != nil {
				file.Close()
				return readErr
			}
			var actual adoptMetadata
			actual, readErr = adoptNativeMetadata(path, current)
			if readErr != nil || !reflect.DeepEqual(before, actual) {
				file.Close()
				return fmt.Errorf("file identity changed while reading %s", path)
			}
			var fingerprint [32]byte
			fingerprint, readErr = adoptMetadataFingerprint(before)
			if readErr != nil {
				file.Close()
				return readErr
			}
			var cached bool
			item.Payload, cached = progress.cachedPayload(before, fingerprint)
			if cached {
				progress.add(before.Size, 0, "cached SHA-256, metadata unchanged: "+relative)
			} else {
				var digest hash.Hash = sha256.New()
				_, readErr = io.Copy(digest, adoptContextReader{Context: ctx, Reader: file, Progress: progress, Path: relative})
				item.Payload = hex.EncodeToString(digest.Sum(nil))
			}
			var closeErr error = file.Close()
			if readErr != nil {
				return readErr
			}
			if closeErr != nil {
				return closeErr
			}
			var identity [2]uint64 = [2]uint64{before.Device, before.Inode}
			groups[identity] = append(groups[identity], len(result.Entries))
			progress.tick(0, relative)
		case entry.Type()&os.ModeSymlink != 0:
			item.Payload, readErr = rooted.Readlink(relative)
			if readErr != nil {
				return readErr
			}
			if !utf8.ValidString(item.Payload) {
				return fmt.Errorf("cannot safely archive a non-UTF-8 symlink target at %q", relative)
			}
			progress.tick(0, relative)
		case entry.IsDir():
			progress.tick(0, relative)
		default:
			return fmt.Errorf("unsupported file type at %s", path)
		}
		var after adoptMetadata
		progress.current("metadata", relative)
		after, readErr = adoptStat(path)
		if readErr != nil {
			return readErr
		}
		if !reflect.DeepEqual(before, after) {
			return fmt.Errorf("source changed while reading %s", path)
		}
		if entry.Type().IsRegular() {
			var fingerprint [32]byte
			fingerprint, readErr = adoptMetadataFingerprint(after)
			if readErr != nil {
				return readErr
			}
			progress.rememberPayload(after, fingerprint, item.Payload)
		}
		result.Entries = append(result.Entries, item)
		return nil
	})
	if err != nil {
		return result, err
	}
	var members []int
	for _, members = range groups {
		var first *adoptEntry = &result.Entries[members[0]]
		if first.Metadata.Nlink != uint64(len(members)) {
			return result, fmt.Errorf("file %s has hardlinks outside the adopted directory", first.Path)
		}
		var index int
		for _, index = range members {
			if result.Entries[index].Metadata.Nlink != uint64(len(members)) {
				return result, errors.New("hardlink relationship changed during scan")
			}
			result.Entries[index].Hardlink = first.Path
		}
	}
	var digest hash.Hash = sha256.New()
	var encoder *json.Encoder = json.NewEncoder(digest)
	var item adoptEntry
	for _, item = range result.Entries {
		item = comparableAdoptEntry(item)
		if err = encoder.Encode(item); err != nil {
			return result, err
		}
	}
	var final adoptMetadata
	final, err = adoptStat(root)
	if err != nil || !adoptIdentityEqual(rootMeta, final) {
		return result, errors.New("source root identity changed during scan")
	}
	result.Digest = hex.EncodeToString(digest.Sum(nil))
	return result, nil
}

func stableAdoptManifest(ctx context.Context, path string, progress *adoptProgress) (adoptManifest, error) {
	var first adoptManifest
	var second adoptManifest
	var err error
	first, err = buildAdoptManifest(ctx, path, progress)
	if err != nil {
		return first, err
	}
	second, err = buildAdoptManifest(ctx, path, progress)
	if err != nil {
		return first, err
	}
	if first.Digest != second.Digest {
		return first, fmt.Errorf("directory changed while verifying %s", path)
	}
	var index int
	for index = range first.Entries {
		if !adoptIdentityEqual(first.Entries[index].Metadata, second.Entries[index].Metadata) {
			return first, fmt.Errorf("entry identity changed while verifying %s", path)
		}
	}
	return second, nil
}

type adoptContextReader struct {
	Context  context.Context
	Reader   io.Reader
	Progress *adoptProgress
	Path     string
	Stage    string
}

func (reader adoptContextReader) Read(buffer []byte) (int, error) {
	var err error = reader.Context.Err()
	if err != nil {
		return 0, err
	}
	var stage string = reader.Stage
	if stage == "" {
		stage = "hash"
	}
	reader.Progress.current(stage, reader.Path)
	var count int
	count, err = reader.Reader.Read(buffer)
	if count > 0 {
		reader.Progress.add(int64(count), 0, stage+": "+reader.Path)
	}
	return count, err
}

func verifyAdoptDeletion(ctx context.Context, rooted *os.Root, root string, item adoptEntry, actual adoptMetadata, progress *adoptProgress) error {
	var wanted adoptMetadata = item.Metadata
	var comparable adoptMetadata = actual
	wanted.CtimeSec = 0
	wanted.CtimeNS = 0
	wanted.Nlink = 0
	wanted.Xattrs = portableAdoptXattrs(wanted.Xattrs)
	comparable.CtimeSec = 0
	comparable.CtimeNS = 0
	comparable.Nlink = 0
	comparable.Xattrs = portableAdoptXattrs(comparable.Xattrs)
	if wanted.Mode&0170000 == 0040000 {
		wanted.MtimeSec = 0
		wanted.MtimeNS = 0
		wanted.Size = 0
		comparable.MtimeSec = 0
		comparable.MtimeNS = 0
		comparable.Size = 0
	}
	if !reflect.DeepEqual(wanted, comparable) {
		return fmt.Errorf("backup metadata changed before removal: %s", item.Path)
	}
	var payload string
	var err error
	switch wanted.Mode & 0170000 {
	case 0100000:
		var file *os.File
		file, err = rooted.OpenFile(item.Path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return err
		}
		var opened os.FileInfo
		opened, err = file.Stat()
		if err != nil {
			file.Close()
			return err
		}
		var current adoptMetadata
		current, err = adoptNativeMetadata(filepath.Join(root, item.Path), opened)
		if err != nil || !adoptIdentityEqual(current, actual) {
			file.Close()
			return errors.New("backup file changed before removal")
		}
		var digest hash.Hash = sha256.New()
		_, err = io.Copy(digest, adoptContextReader{Context: ctx, Reader: file, Progress: progress, Path: item.Path})
		var closeErr error = file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		payload = hex.EncodeToString(digest.Sum(nil))
	case 0120000:
		payload, err = rooted.Readlink(item.Path)
		if err != nil {
			return err
		}
	case 0040000:
	default:
		return errors.New("unsupported backup entry during removal")
	}
	if payload != item.Payload {
		return fmt.Errorf("backup content changed before removal: %s", item.Path)
	}
	var after adoptMetadata
	after, err = adoptStat(filepath.Join(root, item.Path))
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(actual, after) {
		return fmt.Errorf("backup changed while verifying removal: %s", item.Path)
	}
	return nil
}
