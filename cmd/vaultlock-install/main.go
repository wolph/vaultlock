package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/wolph/vaultlock/internal/install"
)

func main() {
	var directory string = os.Getenv("VAULTLOCK_INSTALL_BIN_DIR")
	if os.Getenv("VAULTLOCK_INSTALL_BIN_DIR_MODE") == "default-home" {
		var home string = os.Getenv("HOME")
		if home != "" {
			directory = filepath.Join(home, "bin")
		}
	}
	if directory == "" || len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "vaultlock install: provide a binary source and a nonempty BIN_DIR")
		os.Exit(1)
	}
	var destination string = filepath.Join(directory, "vaultlock")
	var source string
	var err error
	source, err = filepath.Abs(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "vaultlock install:", err)
		os.Exit(1)
	}
	var legacySource string
	if filepath.Base(source) == "vaultlock" && filepath.Base(filepath.Dir(source)) == "build" {
		legacySource = filepath.Join(filepath.Dir(filepath.Dir(source)), "bin", "vaultlock")
	}
	err = install.BinaryWithLegacy(source, destination, legacySource)
	if err != nil {
		fmt.Fprintln(os.Stderr, "vaultlock install:", err)
		os.Exit(1)
	}
	fmt.Println("Installed", destination)
}
