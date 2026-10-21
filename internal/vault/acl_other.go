//go:build !darwin

package vault

func checkACL(path string) error { return nil }
