package vault

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestAdoptRejectsNonUTF8SymlinkWithoutChangingEitherTree(t *testing.T) {
	requireAdoptPlatform(t)
	var app *App
	var source string
	var destination string
	app, _, source, destination = adoptFixture(t)
	var original string = "name-\xff"
	var different string = "name-\xfe"
	if err := os.Symlink(original, filepath.Join(source, "link")); err != nil {
		t.Fatal(err)
	}
	copyExistingAdoptFixture(t, source, destination)
	if err := os.Remove(filepath.Join(destination, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(different, filepath.Join(destination, "link")); err != nil {
		t.Fatal(err)
	}
	var err error = app.adopt(context.Background(), source)
	if err == nil || !strings.Contains(err.Error(), "UTF-8") {
		t.Fatalf("unrepresentable symlink target was not refused: %v", err)
	}
	var info os.FileInfo
	info, err = os.Lstat(source)
	if err != nil || !info.IsDir() {
		t.Fatalf("original source directory changed: %v", err)
	}
	var path string
	var wanted string
	for path, wanted = range map[string]string{source: original, destination: different} {
		var actual string
		actual, err = os.Readlink(filepath.Join(path, "link"))
		if err != nil || actual != wanted {
			t.Fatalf("symlink bytes changed in %q: %v", path, err)
		}
	}
}

func TestAdoptMetadataArchiveRetainsOriginalProtectedBytes(t *testing.T) {
	var path string = t.TempDir()
	var root *os.Root
	var err error
	root, err = os.OpenRoot(path)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	var progress *adoptProgress = newAdoptProgress(io.Discard, "never")
	defer progress.finish()
	var original adoptEntry = adoptEntry{Path: "data", Payload: "verified SHA-256", Metadata: adoptMetadata{Xattrs: []adoptXattr{
		{Name: "com.apple.provenance", Value: []byte{0, 255, 42, 3}},
		{Name: "com.apple.ResourceFork", Value: []byte("original fork")},
	}}}
	var manifest adoptManifest = adoptManifest{Digest: "portable digest", Entries: []adoptEntry{original}}
	if err = writeAdoptArchive(context.Background(), root, "source", adoptPlan{Source: "/example/source", Destination: "/example/vault/source"}, manifest, progress); err != nil {
		t.Fatal(err)
	}
	var file *os.File
	file, err = root.Open("source.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var info os.FileInfo
	info, err = file.Stat()
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("archive permissions are not private: %v", err)
	}
	var decoder *json.Decoder = json.NewDecoder(file)
	var header adoptArchiveHeader
	var actual adoptEntry
	if err = decoder.Decode(&header); err == nil {
		err = decoder.Decode(&actual)
	}
	if err != nil || header.Version != 1 || !reflect.DeepEqual(actual, original) {
		t.Fatalf("original metadata bytes were not retained: %v", err)
	}
}

func TestAdoptPortableMetadataArchivesRatherThanComparesProvenance(t *testing.T) {
	var original adoptEntry = adoptEntry{Path: "data", Metadata: adoptMetadata{Xattrs: []adoptXattr{
		{Name: "com.apple.provenance", Value: []byte("original OS tracking record")},
		{Name: "com.apple.quarantine", Value: []byte("quarantine stays exact")},
		{Name: "com.apple.macl", Value: []byte("access record stays exact")},
		{Name: "com.apple.ResourceFork", Value: []byte("fork stays exact")},
		{Name: "com.example.data", Value: []byte("custom data stays exact")},
	}}}
	var portable adoptEntry = comparableAdoptEntry(original)
	if !reflect.DeepEqual(portable.Metadata.Xattrs, original.Metadata.Xattrs[1:]) {
		t.Fatalf("portable comparison policy altered ordinary metadata: %v", portable.Metadata.Xattrs)
	}
	if len(original.Metadata.Xattrs) != 5 || !bytes.Equal(original.Metadata.Xattrs[0].Value, []byte("original OS tracking record")) {
		t.Fatal("original provenance was discarded before archival")
	}
}

func TestAdoptCachedVerificationRejectsSameSizeChangeWithRestoredMtime(t *testing.T) {
	requireAdoptPlatform(t)
	var root string = t.TempDir()
	var path string = filepath.Join(root, "data")
	if err := os.WriteFile(path, []byte("spam"), 0600); err != nil {
		t.Fatal(err)
	}
	var progress *adoptProgress = newAdoptProgress(io.Discard, "never")
	defer progress.finish()
	progress.phasePasses("Verify cached hashes", 4)
	var first adoptManifest
	var err error
	first, err = stableAdoptManifest(context.Background(), root, progress)
	if err != nil {
		t.Fatal(err)
	}
	var metadata adoptMetadata = first.Entries[1].Metadata
	if err = os.WriteFile(path, []byte("eggs"), 0600); err != nil {
		t.Fatal(err)
	}
	var mtime time.Time = time.Unix(metadata.MtimeSec, metadata.MtimeNS)
	if err = os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	var second adoptManifest
	second, err = stableAdoptManifest(context.Background(), root, progress)
	if err != nil {
		t.Fatal(err)
	}
	if first.Digest == second.Digest || first.Entries[1].Payload == second.Entries[1].Payload {
		t.Fatal("cached hash concealed modified content after mtime restoration")
	}
}
