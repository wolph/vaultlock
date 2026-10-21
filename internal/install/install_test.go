package install

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallRefusesUnrelatedTargetsBeforeCreatingDirectory(t *testing.T) {
	var root string = t.TempDir()
	var source string = filepath.Join(root, "source")
	var destination string = filepath.Join(root, "new", "vaultlock")
	var err error = os.WriteFile(source, []byte("#!/bin/sh\nexit 0\n"), 0755)
	if err != nil {
		t.Fatal(err)
	}
	err = Binary(source, destination)
	if err == nil {
		t.Fatal("accepted a source that is not a Vaultlock Go binary")
	}
	_, err = os.Stat(filepath.Dir(destination))
	if !os.IsNotExist(err) {
		t.Fatalf("invalid source created destination directory: %v", err)
	}
}

func TestTargetValidationRefusesFilesAndSymlinks(t *testing.T) {
	var root string = t.TempDir()
	var target string = filepath.Join(root, "vaultlock")
	var err error = os.WriteFile(target, []byte("valuable user file"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = inspectTarget(target)
	if err == nil {
		t.Fatal("accepted an unrelated file")
	}
	err = os.Remove(target)
	if err != nil {
		t.Fatal(err)
	}
	err = os.Symlink("missing", target)
	if err != nil {
		t.Fatal(err)
	}
	_, err = inspectTarget(target)
	if err == nil {
		t.Fatal("accepted a dangling symlink")
	}
}

func TestMissingTargetCommitDoesNotOverwriteNewFile(t *testing.T) {
	var root string = t.TempDir()
	var stage string = filepath.Join(root, "stage")
	var target string = filepath.Join(root, "vaultlock")
	var err error = os.WriteFile(stage, []byte("new binary"), 0755)
	if err != nil {
		t.Fatal(err)
	}
	err = os.WriteFile(target, []byte("valuable user file"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	err = commitStage(stage, target, targetSnapshot{})
	if err == nil {
		t.Fatal("overwrote a target created after the final absence check")
	}
	var actual []byte
	actual, err = os.ReadFile(target)
	if err != nil || string(actual) != "valuable user file" {
		t.Fatalf("actual=%q err=%v", actual, err)
	}
}

func TestKnownLegacySymlinkMigrationPreservesSource(t *testing.T) {
	var root string = t.TempDir()
	var legacy string = filepath.Join(root, "legacy-vaultlock")
	var target string = filepath.Join(root, "vaultlock")
	var stage string = filepath.Join(root, "stage")
	var contents []byte = []byte("legacy source with local edits\n")
	var err error = os.WriteFile(legacy, contents, 0755)
	if err != nil {
		t.Fatal(err)
	}
	err = os.Symlink(legacy, target)
	if err != nil {
		t.Fatal(err)
	}
	var snapshot targetSnapshot
	snapshot, err = inspectTargetWithLegacy(target, legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err = unchangedTarget(target, snapshot); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(stage, []byte("compiled binary"), 0755); err != nil {
		t.Fatal(err)
	}
	if err = commitStage(stage, target, snapshot); err != nil {
		t.Fatal(err)
	}
	var actual []byte
	actual, err = os.ReadFile(legacy)
	if err != nil || string(actual) != string(contents) {
		t.Fatalf("legacy source changed: %q, %v", actual, err)
	}
	var info os.FileInfo
	info, err = os.Lstat(target)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatalf("installed target is not a standalone binary: %v", err)
	}
}

func TestLegacyMigrationRefusesChangedSymlink(t *testing.T) {
	var root string = t.TempDir()
	var legacy string = filepath.Join(root, "legacy-vaultlock")
	var target string = filepath.Join(root, "vaultlock")
	var replacement string = filepath.Join(root, "replacement")
	var err error = os.WriteFile(legacy, []byte("legacy\n"), 0755)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink(legacy, target); err != nil {
		t.Fatal(err)
	}
	var snapshot targetSnapshot
	snapshot, err = inspectTargetWithLegacy(target, legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink(legacy, replacement); err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(replacement, target); err != nil {
		t.Fatal(err)
	}
	if err = unchangedTarget(target, snapshot); err == nil {
		t.Fatal("accepted a different symlink created after inspection")
	}
}

func TestLegacyMigrationRefusesUnrelatedAndRelativeSymlinks(t *testing.T) {
	var root string = t.TempDir()
	var legacy string = filepath.Join(root, "legacy-vaultlock")
	var target string = filepath.Join(root, "vaultlock")
	var err error = os.WriteFile(legacy, []byte("legacy\n"), 0755)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink("legacy-vaultlock", target); err != nil {
		t.Fatal(err)
	}
	if _, err = inspectTargetWithLegacy(target, legacy); err == nil {
		t.Fatal("accepted a relative legacy symlink")
	}
	if err = os.Remove(target); err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink(legacy, target); err != nil {
		t.Fatal(err)
	}
	if _, err = inspectTargetWithLegacy(target, filepath.Join(root, "other")); err == nil {
		t.Fatal("accepted an unexpected absolute symlink")
	}
}
