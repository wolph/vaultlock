package progress

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode"

	"golang.org/x/text/width"
)

func sanitise(text string) string {
	return strings.Map(func(value rune) rune {
		if unicode.IsControl(value) {
			return '?'
		}
		return value
	}, text)
}

type cellCounter struct {
	cells    int
	lastBase int
}

func (c *cellCounter) add(value rune) {
	// Emoji presentation and keycap marks can widen an otherwise narrow base.
	if (value == '\ufe0f' || value == '\u20e3') && c.lastBase == 1 {
		c.cells++
		c.lastBase = 2
		return
	}
	if unicode.Is(unicode.Mn, value) || unicode.Is(unicode.Me, value) || unicode.Is(unicode.Cf, value) {
		return
	}
	var cells int = 1
	var kind width.Kind = width.LookupRune(value).Kind()
	if kind == width.EastAsianWide || kind == width.EastAsianFullwidth || kind == width.EastAsianAmbiguous {
		cells = 2
	}
	c.cells += cells
	c.lastBase = cells
}

func textWidth(text string) int {
	var counter cellCounter
	for _, value := range text {
		counter.add(value)
	}
	return counter.cells
}

func terminalWidth(writer io.Writer) int {
	var width int
	var err error
	width, err = strconv.Atoi(os.Getenv("COLUMNS"))
	if err != nil || width < 1 {
		width = nativeWidth(writer)
	}
	if width < 1 {
		width = 80
	}
	if width < 20 {
		width = 20
	}
	if width > 160 {
		width = 160
	}
	return width
}

func (t *Task) describe(now time.Time, frame uint64, status string) string {
	return t.styledDescription(now, frame, status, Palette{})
}

func (t *Task) primary() (int64, int64) {
	if t.totalBytes > 0 {
		return t.bytes, t.totalBytes
	}
	return t.entries, t.totalEntries
}

func (t *Task) counters() []string {
	var parts []string
	if t.totalBytes > 0 {
		parts = append(parts, bytesText(t.bytes)+"/"+bytesText(t.totalBytes))
	} else if t.bytes > 0 {
		parts = append(parts, bytesText(t.bytes))
	}
	if t.totalEntries > 0 {
		parts = append(parts, fmt.Sprintf("%d/%d entries", t.entries, t.totalEntries))
	} else if t.entries > 0 {
		parts = append(parts, fmt.Sprintf("%d entries", t.entries))
	}
	return parts
}

func (t *Task) metrics(now time.Time) []string {
	var elapsed time.Duration = now.Sub(t.started)
	var parts []string = []string{"elapsed " + elapsed.Round(100*time.Millisecond).String()}
	if elapsed <= 0 {
		return parts
	}
	if t.bytes > 0 {
		parts = append(parts, rateText(float64(t.bytes)/elapsed.Seconds(), "B"))
	}
	if t.entries > 0 {
		parts = append(parts, rateText(float64(t.entries)/elapsed.Seconds(), "entries"))
	}
	var done int64
	var total int64
	done, total = t.primary()
	if done > 0 && total > done {
		parts = append(parts, "ETA "+etaText(float64(total-done)*elapsed.Seconds()/float64(done)))
	}
	return parts
}

func (t *Task) terminalLines(now time.Time, frame uint64, status string, width int) []string {
	return t.styledTerminalLines(now, frame, status, width, Palette{})
}

func bar(done, total int64, completed bool, width int) string {
	var ratio float64 = float64(done) / float64(total)
	if ratio > 1 {
		ratio = 1
	}
	var filled int = int(ratio * float64(width))
	if completed {
		filled = width
	}
	if filled > width {
		filled = width
	}
	return "[" + strings.Repeat("=", filled) + strings.Repeat(".", width-filled) + "]"
}

func percentage(done, total int64, completed bool) string {
	var ratio float64 = float64(done) / float64(total)
	if ratio > 1 {
		ratio = 1
	}
	var percent int = int(ratio * 100)
	if completed {
		percent = 100
	} else if percent > 99 {
		percent = 99
	}
	return fmt.Sprintf("%d%%", percent)
}

func bytesText(amount int64) string {
	if amount < 1024 {
		return fmt.Sprintf("%d B", amount)
	}
	var value float64 = float64(amount) / 1024
	var unit string = "KiB"
	if value >= 1024 {
		value /= 1024
		unit = "MiB"
	}
	if value >= 1024 {
		value /= 1024
		unit = "GiB"
	}
	return fmt.Sprintf("%.1f %s", value, unit)
}

func rateText(rate float64, unit string) string {
	if unit == "B" && rate >= 1024 {
		var scaled float64 = rate / 1024
		var suffix string = "KiB/s"
		if scaled >= 1024 {
			scaled /= 1024
			suffix = "MiB/s"
		}
		if scaled >= 1024 {
			scaled /= 1024
			suffix = "GiB/s"
		}
		return fmt.Sprintf("%.1f %s", scaled, suffix)
	}
	return fmt.Sprintf("%.1f %s/s", rate, unit)
}

func etaText(seconds float64) string {
	if seconds < 1 {
		return "<1s"
	}
	if seconds > float64((1<<63-1)/int64(time.Second)) {
		return ">292y"
	}
	return (time.Duration(seconds) * time.Second).Round(time.Second).String()
}
