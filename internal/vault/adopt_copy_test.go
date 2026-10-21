package vault

import (
	"bytes"
	"context"
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"

	"golang.org/x/sys/unix"
)

func TestAdoptCopyMetadataRemovesUnexpectedACLAndAttributes(t *testing.T) {
	requireAdoptPlatform(t)
	var source string = filepath.Join(t.TempDir(), "source")
	var destination string = filepath.Join(t.TempDir(), "destination")
	var path string
	for _, path = range []string{source, destination} {
		if err := os.WriteFile(path, []byte("spam"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	var original adoptMetadata
	var err error
	original, err = adoptStat(source)
	if err != nil {
		t.Fatal(err)
	}
	var output []byte
	output, err = exec.Command("/bin/chmod", "+a", "everyone allow read", destination).CombinedOutput()
	if err != nil {
		t.Fatalf("fixture ACL: %v, %s", err, output)
	}
	if err = unix.Lsetxattr(destination, "com.example.extra", []byte("unexpected"), 0); err != nil {
		t.Fatal(err)
	}
	var rooted *os.Root
	rooted, err = os.OpenRoot(filepath.Dir(destination))
	if err != nil {
		t.Fatal(err)
	}
	defer rooted.Close()
	var file *os.File
	file, err = adoptOpenMetadataFile(rooted, filepath.Base(destination))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err = adoptRestoreCopyMetadataFile(file, original); err != nil {
		t.Fatal(err)
	}
	var actual adoptMetadata
	actual, err = adoptStat(destination)
	if err != nil || !bytes.Equal(actual.ACL, original.ACL) || !reflect.DeepEqual(actual.Xattrs, original.Xattrs) {
		t.Fatalf("copy metadata still differs from source: %v", err)
	}
}

func TestAdoptPreservesLiteralAppleDoubleFilesAndNativeResourceForks(t *testing.T) {
	var mode string
	for _, mode = range []string{"new", "resume"} {
		t.Run(mode, func(t *testing.T) {

			var app *App
			var source string
			var destination string
			app, _, source, destination = adoptFixture(t)
			var sidecar []byte = make([]byte, 70)
			binary.BigEndian.PutUint32(sidecar[0:4], 0x00051607)
			binary.BigEndian.PutUint32(sidecar[4:8], 0x00020000)
			binary.BigEndian.PutUint16(sidecar[24:26], 1)
			binary.BigEndian.PutUint32(sidecar[26:30], 9)
			binary.BigEndian.PutUint32(sidecar[30:34], 38)
			binary.BigEndian.PutUint32(sidecar[34:38], 32)
			copy(sidecar[38:], "TEXTtest")
			var err error = os.WriteFile(filepath.Join(source, "._data"), sidecar, 0600)
			if err == nil {
				err = os.WriteFile(filepath.Join(source, "._ordinary"), []byte("literal sidecar data"), 0600)
			}
			if err == nil {
				err = os.Link(filepath.Join(source, "._ordinary"), filepath.Join(source, "._hardlink"))
			}
			if err == nil {
				err = os.Symlink("data", filepath.Join(source, "._symlink"))
			}
			if err == nil {
				err = os.Mkdir(filepath.Join(source, "._directory"), 0700)
			}
			if err == nil {
				err = os.WriteFile(filepath.Join(source, "._directory", "nested"), []byte("nested data"), 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			var name string
			for _, name = range []string{"data", "._data", "._ordinary"} {
				var path string = filepath.Join(source, name)
				var attribute string
				var value []byte
				for attribute, value = range map[string][]byte{
					"com.apple.FinderInfo":   append([]byte("TEXTtest"), make([]byte, 24)...),
					"com.apple.ResourceFork": []byte("native fork for " + name),
					"com.example.vaultlock":  []byte("custom metadata"),
					"com.apple.quarantine":   []byte("0083;01234567;vaultlock-test;"),
				} {
					if err = unix.Lsetxattr(path, attribute, value, 0); err != nil {
						t.Fatal(err)
					}
				}
				var output []byte
				output, err = exec.Command("/bin/chmod", "+a", "everyone allow read", path).CombinedOutput()
				if err != nil {
					t.Fatalf("fixture ACL: %v, %s", err, output)
				}
			}
			var original adoptManifest
			original, err = stableAdoptManifest(context.Background(), source, nil)
			if err != nil {
				t.Fatal(err)
			}
			if mode == "resume" {
				var output []byte
				output, err = exec.Command("/usr/bin/ditto", "--norsrc", "--extattr", "--acl", source, destination).CombinedOutput()
				if err != nil {
					t.Fatalf("existing copy fixture: %v, %s", err, output)
				}
				if err = os.WriteFile(filepath.Join(destination, "data"), []byte("previous destination data"), 0600); err != nil {
					t.Fatal(err)
				}
			}

			if err = app.adopt(context.Background(), source); err != nil {
				t.Fatal(err)
			}
			if _, err = adoptMatchesManifest(context.Background(), destination, original, nil, false); err != nil {
				t.Fatal(err)
			}
			var actual []byte
			actual, err = os.ReadFile(filepath.Join(destination, "._data"))
			if err != nil || string(actual) != string(sidecar) {
				t.Fatalf("literal sidecar changed: %v", err)
			}

		})
	}
}
