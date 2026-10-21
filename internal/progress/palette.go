package progress

import (
	"os"
	"strings"
	"unicode"
)

// SanitiseText preserves authored newlines and tabs while replacing terminal
// controls, including escape sequences' initial ESC, with question marks.
// Task labels and paths use the stricter single-line sanitiser instead.
func SanitiseText(text string) string {
	return strings.Map(func(value rune) rune {
		if value != '\n' && value != '\t' && unicode.IsControl(value) {
			return '?'
		}
		return value
	}, text)
}

// ColourEnabled resolves colour for one output stream. Even an empty NO_COLOR
// value suppresses automatic colour. Explicit modes take precedence.
func ColourEnabled(mode string, terminal bool) bool {
	if mode == "always" {
		return true
	}
	if mode == "never" {
		return false
	}
	var disabled bool
	_, disabled = os.LookupEnv("NO_COLOR")
	return terminal && os.Getenv("TERM") != "dumb" && !disabled
}

// Palette applies a small semantic ANSI palette without changing its text.
// Callers sanitise untrusted terminal text before applying a style.
type Palette struct{ Enabled bool }

func (p Palette) Heading(text string) string { return p.style(text, "1;36") }
func (p Palette) Accent(text string) string  { return p.style(text, "36") }
func (p Palette) Number(text string) string  { return p.style(text, "1;36") }
func (p Palette) Label(text string) string   { return p.style(text, "2") }
func (p Palette) Path(text string) string    { return p.style(text, "2") }
func (p Palette) Rate(text string) string    { return p.style(text, "32") }
func (p Palette) ETA(text string) string     { return p.style(text, "33") }
func (p Palette) Success(text string) string { return p.style(text, "1;32") }
func (p Palette) Warning(text string) string { return p.style(text, "1;33") }
func (p Palette) Error(text string) string   { return p.style(text, "1;31") }

func (p Palette) style(text string, code string) string {
	if !p.Enabled || text == "" {
		return text
	}
	return "\x1b[" + code + "m" + text + "\x1b[0m"
}
