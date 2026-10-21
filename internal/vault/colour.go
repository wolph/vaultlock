package vault

import (
	"io"
	"os"

	"github.com/wolph/vaultlock/internal/progress"
)

func writerTerminal(writer io.Writer) bool {
	var file *os.File
	var ok bool
	file, ok = writer.(*os.File)
	return ok && adoptTerminal(file.Fd())
}

// ColourEnabled resolves the requested colour mode for this output stream.
func ColourEnabled(mode string, writer io.Writer) bool {
	return progress.ColourEnabled(mode, writerTerminal(writer))
}
