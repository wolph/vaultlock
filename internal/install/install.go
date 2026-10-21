// Package install installs a standalone binary without replacing unrelated files.
package install

import (
	"bytes"
	"crypto/sha256"
	"debug/buildinfo"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const commandPath string = "github.com/wolph/vaultlock/cmd/vaultlock"

type targetSnapshot struct {
	info         os.FileInfo
	digest       [32]byte
	legacySource string
}

func validBinary(data []byte) error {
	var info *buildinfo.BuildInfo
	var err error
	info, err = buildinfo.Read(bytes.NewReader(data))
	if err != nil || info.Path != commandPath {
		return errors.New("expected a compiled Vaultlock Go binary")
	}
	return nil
}

func inspectTarget(path string) (targetSnapshot, error) {
	return inspectTargetWithLegacy(path, "")
}

func inspectTargetWithLegacy(path string, legacySource string) (targetSnapshot, error) {
	var snapshot targetSnapshot
	var err error
	snapshot.info, err = os.Lstat(path)
	if os.IsNotExist(err) {
		return targetSnapshot{}, nil
	}
	if err != nil {
		return snapshot, err
	}
	if snapshot.info.Mode()&os.ModeSymlink != 0 && legacySource != "" {
		return inspectLegacySymlink(path, legacySource, snapshot)
	}
	if !snapshot.info.Mode().IsRegular() {
		return snapshot, fmt.Errorf("refusing non-regular target: %s", path)
	}
	var data []byte
	data, err = os.ReadFile(path)
	if err != nil {
		return snapshot, err
	}
	if err = validBinary(data); err != nil {
		return snapshot, fmt.Errorf("refusing unrelated target %s: %w", path, err)
	}
	snapshot.digest = sha256.Sum256(data)
	return snapshot, nil
}

func inspectLegacySymlink(path string, expected string, snapshot targetSnapshot) (targetSnapshot, error) {
	var link string
	var err error
	link, err = os.Readlink(path)
	if err != nil {
		return snapshot, err
	}
	if !filepath.IsAbs(expected) || link != expected {
		return snapshot, fmt.Errorf("refusing unexpected legacy symlink: %s", path)
	}
	var source os.FileInfo
	source, err = os.Lstat(expected)
	if err != nil || !source.Mode().IsRegular() || source.Mode().Perm()&0111 == 0 {
		return snapshot, errors.New("legacy symlink must name the existing executable repository source")
	}
	snapshot.legacySource = expected
	return snapshot, nil
}

func unchangedTarget(path string, expected targetSnapshot) error {
	var actual targetSnapshot
	var err error
	actual, err = inspectTargetWithLegacy(path, expected.legacySource)
	if err != nil {
		return err
	}
	if expected.info == nil && actual.info == nil {
		return nil
	}
	if expected.info == nil || actual.info == nil || !os.SameFile(expected.info, actual.info) || expected.digest != actual.digest || expected.legacySource != actual.legacySource {
		return fmt.Errorf("installation target changed: %s", path)
	}
	return nil
}

// Binary atomically copies source into destination after checking both files.
func Binary(source string, destination string) error {
	return BinaryWithLegacy(source, destination, "")
}

// BinaryWithLegacy also migrates an exact absolute link to a known legacy source.
// Replacing the link preserves the source file and its local edits.
func BinaryWithLegacy(source string, destination string, legacySource string) error {
	var sourceInfo os.FileInfo
	var err error
	sourceInfo, err = os.Lstat(source)
	if err != nil {
		return err
	}
	if !sourceInfo.Mode().IsRegular() {
		return errors.New("binary source must be a regular file")
	}
	var data []byte
	data, err = os.ReadFile(source)
	if err != nil {
		return err
	}
	if err = validBinary(data); err != nil {
		return err
	}
	var target targetSnapshot
	target, err = inspectTargetWithLegacy(destination, legacySource)
	if err != nil {
		return err
	}
	if target.info != nil && os.SameFile(sourceInfo, target.info) {
		return errors.New("source and destination refer to the same file")
	}
	return stageAndInstall(destination, data, target)
}

func stageAndInstall(destination string, data []byte, target targetSnapshot) error {
	var directory string = filepath.Dir(destination)
	var info os.FileInfo
	var err error
	info, err = os.Lstat(directory)
	if err == nil && !info.IsDir() {
		return errors.New("installation directory must be a directory, without a symlink")
	}
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if err = os.MkdirAll(directory, 0755); err != nil {
		return err
	}
	info, err = os.Lstat(directory)
	if err != nil || !info.IsDir() {
		return errors.New("installation directory changed")
	}
	var staged *os.File
	staged, err = os.CreateTemp(directory, ".vaultlock-install-*")
	if err != nil {
		return err
	}
	defer os.Remove(staged.Name())
	if err = writeStage(staged, data); err != nil {
		return err
	}
	var current os.FileInfo
	current, err = os.Lstat(directory)
	if err != nil || !os.SameFile(info, current) {
		return errors.New("installation directory changed before replacement")
	}
	if err = unchangedTarget(destination, target); err != nil {
		return err
	}
	if err = commitStage(staged.Name(), destination, target); err != nil {
		return err
	}
	var installed []byte
	installed, err = os.ReadFile(destination)
	if err != nil {
		return err
	}
	if !bytes.Equal(data, installed) {
		return errors.New("installed binary failed verification")
	}
	return nil
}

func commitStage(stage string, destination string, target targetSnapshot) error {
	if target.info != nil {
		return os.Rename(stage, destination)
	}
	// Linking a new target refuses an entry created after the absence check.
	var err error = os.Link(stage, destination)
	if err != nil {
		return err
	}
	return os.Remove(stage)
}

func writeStage(file *os.File, data []byte) error {
	var err error
	if _, err = io.Copy(file, bytes.NewReader(data)); err == nil {
		err = file.Chmod(0755)
	}
	if err == nil {
		err = file.Sync()
	}
	var closeError error = file.Close()
	return errors.Join(err, closeError)
}
