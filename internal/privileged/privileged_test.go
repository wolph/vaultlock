package privileged

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"howett.net/plist"
)

const testUUID string = "0E4C5B8A-1D2F-4A6B-9C3D-7E8F90A1B2C3"

func TestParseAcceptsEachOperationAndRoundTrips(t *testing.T) {
	var cases [][]string = [][]string{
		{"unlock", testUUID},
		{"unlock", testUUID, "--nomount"},
		{"rotate", testUUID},
		{"lock", testUUID},
		{"exclude-volume", testUUID},
		{"delete-snapshots", testUUID},
		{"delete-data-snapshots"},
		{"exclude-path", "/Users/wolph/.vaultlock"},
	}
	for _, args := range cases {
		var request Request
		var err error
		request, err = Parse(args)
		if err != nil {
			t.Fatalf("Parse(%q): %v", args, err)
		}
		if got := request.Args(); strings.Join(got, " ") != strings.Join(args, " ") {
			t.Fatalf("Parse(%q).Args() = %q", args, got)
		}
	}
}

func TestParseRejectsMalformedRequests(t *testing.T) {
	var cases [][]string = [][]string{
		nil,
		{"unlock"},
		{"unlock", strings.ToLower(testUUID)},
		{"unlock", "disk3s7"},
		{"unlock", testUUID, "--mount"},
		{"unlock", testUUID, "--nomount", "extra"},
		{"rotate", testUUID, "--nomount"},
		{"lock"},
		{"delete-data-snapshots", testUUID},
		{"exclude-path"},
		{"exclude-path", "relative/path"},
		{"exclude-path", "/tmp/with\ncontrol"},
		{"exclude-path", "/tmp/../etc"},
		{"allow", testUUID},
		{"install"},
		{"mount", testUUID},
	}
	for _, args := range cases {
		if _, err := Parse(args); err == nil {
			t.Fatalf("Parse(%q) accepted", args)
		}
	}
}

func TestAllowlistMatchesExactUUIDAndOwnerOnly(t *testing.T) {
	var data []byte = []byte("# vaultlock volumes\n\n" + testUUID + " 501\n  11111111-2222-3333-4444-555555555555   502 \n" + strings.ToLower(testUUID) + " 501\n22222222-2222-3333-4444-555555555555\n33333333-2222-3333-4444-555555555555 abc\n")
	if !Allowed(data, testUUID, 501) {
		t.Fatal("listed entry refused")
	}
	if !Allowed(data, "11111111-2222-3333-4444-555555555555", 502) {
		t.Fatal("padded entry refused")
	}
	if Allowed(data, testUUID, 502) {
		t.Fatal("another user accepted")
	}
	if Allowed(data, strings.ToLower(testUUID), 501) {
		t.Fatal("lower-case UUID accepted")
	}
	if Allowed(data, "22222222-2222-3333-4444-555555555555", 0) || Allowed(data, "33333333-2222-3333-4444-555555555555", 0) {
		t.Fatal("malformed line accepted")
	}
	if Allowed(nil, testUUID, 501) {
		t.Fatal("empty allowlist accepted")
	}
	if len(Entries(data)) != 2 {
		t.Fatalf("entries %+v", Entries(data))
	}
}

func TestAllowlistEditsAreIdempotent(t *testing.T) {
	var data []byte
	var err error
	data, err = Allow(nil, testUUID, 501)
	if err != nil {
		t.Fatal(err)
	}
	var again []byte
	again, err = Allow(data, testUUID, 501)
	if err != nil || string(again) != string(data) {
		t.Fatalf("second Allow changed %q to %q (%v)", data, again, err)
	}
	if _, err = Allow(data, "not-a-uuid", 501); err == nil {
		t.Fatal("Allow accepted a malformed UUID")
	}
	if _, err = Allow(data, testUUID, -1); err == nil {
		t.Fatal("Allow accepted a negative owner")
	}
	var shared []byte
	shared, err = Allow(data, testUUID, 502)
	if err != nil || !Allowed(shared, testUUID, 501) || !Allowed(shared, testUUID, 502) {
		t.Fatalf("second owner: %q (%v)", shared, err)
	}
	var removed []byte = Revoke(shared, testUUID)
	if Allowed(removed, testUUID, 501) || Allowed(removed, testUUID, 502) {
		t.Fatalf("Revoke left %q", removed)
	}
	if string(Revoke(removed, testUUID)) != string(removed) {
		t.Fatal("Revoke of an absent UUID changed the file")
	}
}

func TestAdminMembershipComesFromSupplementaryGroups(t *testing.T) {
	if AdminMember([]int{20, 12, 61}) {
		t.Fatal("staff-only groups counted as admin")
	}
	if !AdminMember([]int{20, 80, 12}) {
		t.Fatal("admin group not recognised")
	}
	if AdminMember(nil) {
		t.Fatal("no groups counted as admin")
	}
}

type fakeRunner struct {
	fields map[string]any
	err    error
	calls  [][]string
}

func (r *fakeRunner) Run(_ context.Context, path string, args []string) ([]byte, error) {
	r.calls = append(r.calls, append([]string{path}, args...))
	if r.err != nil {
		return nil, r.err
	}
	return plist.Marshal(r.fields, plist.XMLFormat)
}

func volumeFields(uuid, device, mount string) map[string]any {
	return map[string]any{"VolumeUUID": uuid, "DeviceIdentifier": device, "MountPoint": mount, "FilesystemType": "apfs"}
}

func TestResolveBuildsStorageCommandsFromVerifiedVolumeInfo(t *testing.T) {
	var cases []struct {
		args []string
		want string
	}
	cases = []struct {
		args []string
		want string
	}{
		{[]string{"unlock", testUUID}, "/usr/sbin/diskutil apfs unlockVolume disk3s7 -stdinpassphrase"},
		{[]string{"unlock", testUUID, "--nomount"}, "/usr/sbin/diskutil apfs unlockVolume disk3s7 -nomount -stdinpassphrase"},
		{[]string{"rotate", testUUID}, "/usr/sbin/diskutil apfs changePassphrase disk3s7 -user disk -oldStdinpassphrase -newStdinpassphrase"},
		{[]string{"lock", testUUID}, "/usr/sbin/diskutil apfs lockVolume disk3s7"},
		{[]string{"exclude-volume", testUUID}, "/usr/bin/tmutil addexclusion -v /Volumes/vault"},
		{[]string{"delete-snapshots", testUUID}, "/usr/bin/tmutil deletelocalsnapshots /Volumes/vault"},
		{[]string{"delete-data-snapshots"}, "/usr/bin/tmutil deletelocalsnapshots /System/Volumes/Data"},
	}
	for _, c := range cases {
		var runner *fakeRunner = &fakeRunner{fields: volumeFields(testUUID, "disk3s7", "/Volumes/vault")}
		var request Request
		var err error
		request, err = Parse(c.args)
		if err != nil {
			t.Fatal(err)
		}
		var command Command
		command, err = Resolve(context.Background(), request, runner, 501, []int{20, 80})
		if err != nil {
			t.Fatalf("Resolve(%q): %v", c.args, err)
		}
		if got := command.Path + " " + strings.Join(command.Args, " "); got != c.want {
			t.Fatalf("Resolve(%q) = %q, want %q", c.args, got, c.want)
		}
		if request.Kind != KindDeleteDataSnapshots {
			if len(runner.calls) != 1 || strings.Join(runner.calls[0], " ") != "/usr/sbin/diskutil info -plist "+testUUID {
				t.Fatalf("Resolve(%q) inspected %q", c.args, runner.calls)
			}
		} else if len(runner.calls) != 0 {
			t.Fatalf("data snapshot deletion inspected %q", runner.calls)
		}
	}
}

func TestResolveRefusesInconsistentVolumeInfo(t *testing.T) {
	var cases []struct {
		name   string
		runner *fakeRunner
		args   []string
	}
	cases = []struct {
		name   string
		runner *fakeRunner
		args   []string
	}{
		{"uuid mismatch", &fakeRunner{fields: volumeFields("11111111-2222-3333-4444-555555555555", "disk3s7", "/Volumes/vault")}, []string{"lock", testUUID}},
		{"device malformed", &fakeRunner{fields: volumeFields(testUUID, "disk3s7; rm -rf /", "/Volumes/vault")}, []string{"lock", testUUID}},
		{"not apfs", &fakeRunner{fields: map[string]any{"VolumeUUID": testUUID, "DeviceIdentifier": "disk3s7", "FilesystemType": "hfs"}}, []string{"lock", testUUID}},
		{"unmounted exclusion", &fakeRunner{fields: volumeFields(testUUID, "disk3s7", "")}, []string{"exclude-volume", testUUID}},
		{"relative mount", &fakeRunner{fields: volumeFields(testUUID, "disk3s7", "Volumes/vault")}, []string{"delete-snapshots", testUUID}},
		{"diskutil failure", &fakeRunner{err: errors.New("no such volume")}, []string{"unlock", testUUID}},
	}
	for _, c := range cases {
		var request Request
		var err error
		request, err = Parse(c.args)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = Resolve(context.Background(), request, c.runner, 501, []int{20, 80}); err == nil {
			t.Fatalf("%s: Resolve accepted", c.name)
		}
	}
}

func TestResolveExcludePathRequiresOwnedCanonicalDirectory(t *testing.T) {
	var root string = t.TempDir()
	var real string
	var err error
	real, err = filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	var owned string = filepath.Join(real, "state")
	if err = os.Mkdir(owned, 0700); err != nil {
		t.Fatal(err)
	}
	var link string = filepath.Join(real, "link")
	if err = os.Symlink(owned, link); err != nil {
		t.Fatal(err)
	}
	var file string = filepath.Join(real, "file")
	if err = os.WriteFile(file, nil, 0600); err != nil {
		t.Fatal(err)
	}
	var uid int = os.Getuid()
	var command Command
	command, err = Resolve(context.Background(), Request{Kind: KindExcludePath, Path: owned}, &fakeRunner{}, uid, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := command.Path + " " + strings.Join(command.Args, " "); got != "/usr/bin/tmutil addexclusion -p ." || command.Directory == nil {
		t.Fatalf("exclude-path built %q with directory %v", got, command.Directory)
	}
	var pinned, expected os.FileInfo
	pinned, err = command.Directory.Stat()
	if err != nil {
		t.Fatal(err)
	}
	expected, err = os.Stat(owned)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(pinned, expected) {
		t.Fatal("pinned directory is not the requested one")
	}
	if err = os.Rename(owned, filepath.Join(real, "moved")); err != nil {
		t.Fatal(err)
	}
	var moved os.FileInfo
	moved, err = os.Stat(filepath.Join(real, "moved"))
	if err != nil || !os.SameFile(pinned, moved) {
		t.Fatalf("pinned directory did not follow the rename: %v", err)
	}
	command.Directory.Close()
	if err = os.Rename(filepath.Join(real, "moved"), owned); err != nil {
		t.Fatal(err)
	}
	var rejected []struct {
		path string
		uid  int
	} = []struct {
		path string
		uid  int
	}{{link, uid}, {file, uid}, {owned, uid + 1}, {filepath.Join(real, "missing"), uid}, {"/", uid}}
	if root != real {
		rejected = append(rejected, struct {
			path string
			uid  int
		}{root, uid})
	}
	for _, bad := range rejected {
		var rejectedCommand Command
		rejectedCommand, err = Resolve(context.Background(), Request{Kind: KindExcludePath, Path: bad.path}, &fakeRunner{}, bad.uid, nil)
		if err == nil {
			rejectedCommand.Directory.Close()
			t.Fatalf("exclude-path accepted %q for uid %d", bad.path, bad.uid)
		}
	}
}

func TestHelperUsableRequiresRootOwnedSetuidExecutable(t *testing.T) {
	var good *syscall.Stat_t = &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFREG | syscall.S_ISUID | 0755}
	if err := Usable(good); err != nil {
		t.Fatalf("root-owned 4755 refused: %v", err)
	}
	var cases []struct {
		name string
		stat *syscall.Stat_t
	}
	cases = []struct {
		name string
		stat *syscall.Stat_t
	}{
		{"user owned", &syscall.Stat_t{Uid: 501, Gid: 0, Mode: syscall.S_IFREG | syscall.S_ISUID | 0755}},
		{"no setuid", &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFREG | 0755}},
		{"group writable", &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFREG | syscall.S_ISUID | 0775}},
		{"world writable", &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFREG | syscall.S_ISUID | 0757}},
		{"not executable", &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFREG | syscall.S_ISUID | 0644}},
		{"directory", &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFDIR | syscall.S_ISUID | 0755}},
		{"symlink", &syscall.Stat_t{Uid: 0, Gid: 0, Mode: syscall.S_IFLNK | syscall.S_ISUID | 0755}},
	}
	for _, c := range cases {
		if err := Usable(c.stat); err == nil {
			t.Fatalf("%s accepted", c.name)
		}
	}
}

func TestDataVolumeSnapshotsRequireAdminGroup(t *testing.T) {
	var request Request = Request{Kind: KindDeleteDataSnapshots}
	if _, err := Resolve(context.Background(), request, &fakeRunner{}, 501, []int{20, 12}); err == nil {
		t.Fatal("non-administrator deleted data-volume snapshots")
	}
	var command Command
	var err error
	command, err = Resolve(context.Background(), request, &fakeRunner{}, 501, []int{20, 80})
	if err != nil || strings.Join(command.Args, " ") != "deletelocalsnapshots /System/Volumes/Data" {
		t.Fatalf("administrator: %v %q", err, command.Args)
	}
}
