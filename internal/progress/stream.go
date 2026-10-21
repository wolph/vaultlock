package progress

import (
	"io"
	"os"
	"strings"
	"unicode/utf8"
)

// A subprocess can update one transient line with carriage returns. Keep that
// line in the live footer instead of turning each heartbeat into a log entry.
type wrappedWriter struct {
	display   *Display
	writer    io.Writer
	partial   bool
	terminal  bool
	transient bool
	managed   bool
	line      []byte
	filter    streamFilter
	pendingCR bool
}

func (d *Display) Wrap(writer io.Writer) io.Writer {
	if writer == nil {
		writer = io.Discard
	}
	if d == nil {
		return writer
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	var stream *wrappedWriter = &wrappedWriter{display: d, writer: writer, terminal: d.options.Terminal && streamTerminal(writer)}
	var colourTerminal bool = d.options.Terminal
	if _, ok := writer.(*os.File); ok {
		colourTerminal = streamTerminal(writer)
	}
	stream.filter.colour = ColourEnabled(d.options.Color, colourTerminal)
	d.writers = append(d.writers, stream)
	return stream
}

func (w *wrappedWriter) Write(data []byte) (int, error) {
	w.display.mu.Lock()
	defer w.display.mu.Unlock()
	var filtered []byte = w.filter.feed(data)
	if len(filtered) == 0 {
		return len(data), nil
	}
	w.display.clearLocked()
	var start int
	for index, value := range filtered {
		if value != '\r' && value != '\n' {
			continue
		}
		if err := w.pendingFragmentLocked(filtered[start:index]); err != nil {
			return 0, err
		}
		if value == '\r' {
			if w.pendingCR {
				if err := w.carriageLocked(); err != nil {
					return 0, err
				}
			}
			w.pendingCR = true
		} else {
			w.pendingCR = false
			if err := w.newlineLocked(); err != nil {
				return 0, err
			}
		}
		start = index + 1
	}
	if err := w.pendingFragmentLocked(filtered[start:]); err != nil {
		return 0, err
	}
	if (w.transient || w.managed) && len(w.display.tasks) > 0 {
		w.display.renderLocked(w.display.tasks[len(w.display.tasks)-1], "", false)
	}
	return len(data), nil
}

func (w *wrappedWriter) rawLocked(data []byte) error {
	var count int
	var err error
	count, err = w.writer.Write(data)
	if err == nil && count != len(data) {
		err = io.ErrShortWrite
	}
	w.display.recordErrorLocked(err)
	return err
}

func (w *wrappedWriter) partialLocked(partial bool) {
	if partial != w.partial {
		if partial {
			w.display.partialWriters++
		} else {
			w.display.partialWriters--
		}
		w.partial = partial
	}
	w.display.partialNeedsNewline = partial
}

func (w *wrappedWriter) pendingFragmentLocked(data []byte) error {
	if len(data) > 0 && w.pendingCR {
		w.pendingCR = false
		if err := w.carriageLocked(); err != nil {
			return err
		}
	}
	return w.fragmentLocked(data)
}

func (w *wrappedWriter) fragmentLocked(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	if w.transient || w.managed || (w.terminal && w.display.paused == 0 && len(w.display.tasks) > 0 && w.display.options.Mode != "never") {
		w.managed = w.terminal
		if len(data) > 64*1024 {
			if err := w.fragmentLocked(data[:64*1024]); err != nil {
				return err
			}
			return w.fragmentLocked(data[64*1024:])
		}
		// Bound unterminated progress from arbitrary child programs.
		if len(w.line)+len(data) > 64*1024 {
			if err := w.flushLocked(); err != nil {
				return err
			}
			return w.fragmentLocked(data)
		}
		w.line = append(w.line, data...)
		return nil
	}
	if err := w.rawLocked(data); err != nil {
		return err
	}
	if !w.display.options.Terminal || w.terminal {
		w.partialLocked(true)
	}
	return nil
}

func (w *wrappedWriter) carriageLocked() error {
	if w.display.paused > 0 || (w.terminal && w.display.options.Mode == "never") {
		if w.terminal {
			return w.rawLocked([]byte("\r\x1b[2K"))
		}
		return nil
	}
	if w.partial && !w.terminal {
		if err := w.rawLocked([]byte("\n")); err != nil {
			return err
		}
	}
	if w.partial && w.terminal {
		if err := w.rawLocked([]byte("\r\x1b[2K")); err != nil {
			return err
		}
	}
	w.partialLocked(false)
	w.transient = true
	w.line = nil
	return nil
}

func (w *wrappedWriter) newlineLocked() error {
	if w.transient || w.managed {
		if err := w.rawLocked(w.line); err != nil {
			return err
		}
		w.transient = false
		w.managed = false
		w.line = nil
	}
	if err := w.rawLocked([]byte("\n")); err != nil {
		return err
	}
	w.partialLocked(false)
	return nil
}

func (w *wrappedWriter) flushLocked() error {
	if !w.transient && !w.managed {
		return nil
	}
	w.display.clearLocked()
	return w.newlineLocked()
}

func (d *Display) flushStreamsLocked() {
	for _, writer := range d.writers {
		writer.filter.state = 0
		writer.filter.sequence = nil
		if err := writer.flushLocked(); err != nil {
			return
		}
	}
}

// The filter accepts text, line updates and SGR colours. Terminal queries and
// cursor commands from children never reach the user's terminal or log files.
type streamFilter struct {
	state    byte
	sequence []byte
	colour   bool
}

func (f *streamFilter) feed(data []byte) []byte {
	var output []byte
	for _, value := range data {
		switch f.state {
		case 0:
			if value == 0x1b {
				f.state = 'e'
			} else if value >= 0x20 || value == '\n' || value == '\r' || value == '\t' {
				output = append(output, value)
			}
		case 'e':
			switch value {
			case '[':
				f.state = 'c'
				f.sequence = nil
			case ']', 'P', '^', '_':
				f.state = 's'
			default:
				f.state = 0
			}
		case 'c':
			if value >= 0x40 && value <= 0x7e {
				if value == 'm' && f.colour && validSGR(f.sequence) {
					output = append(output, 0x1b, '[')
					output = append(output, f.sequence...)
					output = append(output, 'm')
				}
				f.state = 0
				f.sequence = nil
			} else if len(f.sequence) < 128 {
				f.sequence = append(f.sequence, value)
			} else {
				f.state = 'd'
				f.sequence = nil
			}
		case 'd':
			if value >= 0x40 && value <= 0x7e {
				f.state = 0
			}
		case 's':
			if value == '\n' || value == '\r' {
				f.state = 0
				output = append(output, value)
			} else if value == 0x07 {
				f.state = 0
			} else if value == 0x1b {
				f.state = 't'
			}
		case 't':
			if value == '\n' || value == '\r' {
				f.state = 0
				output = append(output, value)
			} else if value == '\\' || value == 0x07 {
				f.state = 0
			} else if value != 0x1b {
				f.state = 's'
			}
		}
	}
	return output
}

func validSGR(sequence []byte) bool {
	for _, value := range sequence {
		if (value < '0' || value > '9') && value != ';' && value != ':' {
			return false
		}
	}
	return true
}

func clipStreamLine(text string, width int) string {
	var output strings.Builder
	var counter cellCounter
	for len(text) > 0 {
		if strings.HasPrefix(text, "\x1b[") {
			var end int = strings.IndexByte(text, 'm')
			if end < 0 {
				break
			}
			output.WriteString(text[:end+1])
			text = text[end+1:]
			continue
		}
		var value rune
		var size int
		value, size = utf8.DecodeRuneInString(text)
		var next cellCounter = counter
		next.add(value)
		if next.cells > width {
			break
		}
		counter = next
		if value == '\t' {
			output.WriteByte(' ')
		} else {
			output.WriteRune(value)
		}
		text = text[size:]
	}
	if strings.Contains(output.String(), "\x1b[") {
		output.WriteString("\x1b[0m")
	}
	return output.String()
}
