//go:build !darwin

package vault

import (
	"context"
	"errors"
	"os"
)

func adoptNativeMetadata(_ string, _ os.FileInfo) (adoptMetadata, error) {
	return adoptMetadata{}, errors.New("adopt requires macOS native metadata support")
}
func adoptRestoreTimes(_ string, _ string) error { return errors.New("adopt requires macOS") }
func adoptOpenMetadataFile(_ *os.Root, _ string) (*os.File, error) {
	return nil, errors.New("adopt requires macOS")
}
func adoptCheckCopyFile(_ *os.File, _ adoptMetadata, _ uint64) (adoptCopyIdentity, error) {
	return adoptCopyIdentity{}, errors.New("adopt requires macOS")
}
func adoptRestoreCopyMetadataFile(_ *os.File, _ adoptMetadata) error {
	return errors.New("adopt requires macOS")
}
func adoptRestoreCopyTimesFile(_ *os.File, _ adoptMetadata) error {
	return errors.New("adopt requires macOS")
}

func adoptRenameExclusive(_ string, _ string) error { return errors.New("adopt requires macOS") }

func adoptTerminal(_ uintptr) bool { return false }

func adoptCloneFile(_ *os.File, _ *os.Root, _ string) (bool, error) {
	return false, errors.New("adopt requires macOS")
}
func adoptRestoreCopyPOSIXFile(_ context.Context, _ *os.File, _ adoptMetadata) error {
	return errors.New("adopt requires macOS")
}
func adoptRestoreCopyFlagsFile(_ *os.File, _ adoptMetadata) error {
	return errors.New("adopt requires macOS")
}
func adoptRenamePinned(_ *os.Root, _ string, _ *os.Root, _ string) error {
	return errors.New("adopt requires macOS")
}
