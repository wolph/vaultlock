//go:build !darwin && !linux

package progress

import "io"

func nativeWidth(io.Writer) int { return 0 }

func streamTerminal(_ io.Writer) bool { return false }
