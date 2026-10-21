//go:build darwin

package vault

import (
	"errors"
	"golang.org/x/sys/unix"
)

func checkACL(path string) error {
	var metadata unix.Stat_t
	if err := unix.Lstat(path, &metadata); err != nil {
		return err
	}
	if metadata.Flags&(unix.UF_IMMUTABLE|unix.SF_IMMUTABLE|unix.UF_APPEND|unix.SF_APPEND) != 0 {
		return errors.New("protected path has unsafe filesystem flags")
	}
	var acl []byte
	var err error

	acl, err = adoptACL(path)
	if err != nil {
		return errors.New("cannot verify protected path ACL")
	}
	if len(acl) > 0 {
		return errors.New("protected path has an ACL")
	}
	return nil
}
