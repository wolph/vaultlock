package progress

import (
	"strings"
	"time"
)

type semanticRole uint8

const (
	plainRole semanticRole = iota
	headingRole
	accentRole
	numberRole
	labelRole
	pathRole
	rateRole
	etaRole
	successRole
	warningRole
)

type span struct {
	text string
	role semanticRole
}
type row []span

func (p Palette) apply(text string, role semanticRole) string {
	switch role {
	case headingRole:
		return p.Heading(text)
	case accentRole:
		return p.Accent(text)
	case numberRole:
		return p.Number(text)
	case labelRole:
		return p.Label(text)
	case pathRole:
		return p.Path(text)
	case rateRole:
		return p.Rate(text)
	case etaRole:
		return p.ETA(text)
	case successRole:
		return p.Success(text)
	case warningRole:
		return p.Warning(text)
	}
	return text
}

func renderRow(parts row, palette Palette) string {
	var output strings.Builder
	var part span
	for _, part = range parts {
		output.WriteString(palette.apply(part.text, part.role))
	}
	return output.String()
}

func joinRows(parts []row) row {
	var joined row
	var index int
	var part row
	for index, part = range parts {
		if index > 0 {
			joined = append(joined, span{text: " | ", role: labelRole})
		}
		joined = append(joined, part...)
	}
	return joined
}

// clipRow computes terminal cells before any ANSI sequences are introduced.
func clipRow(parts row, width int) row {
	if textWidth(renderRow(parts, Palette{})) <= width {
		return parts
	}
	var output row
	var counter cellCounter
	var part span
	for _, part = range parts {
		var index int
		var value rune
		for index, value = range part.text {
			var next cellCounter = counter
			next.add(value)
			if next.cells > width-3 {
				if index > 0 {
					output = append(output, span{text: part.text[:index], role: part.role})
				}
				return append(output, span{text: "...", role: part.role})
			}
			counter = next
		}
		output = append(output, part)
	}
	return output
}

func packRows(parts []row, width int) []row {
	var lines []row
	var line row
	var part row
	for _, part = range parts {
		var next row = joinRows([]row{line, part})
		if len(line) > 0 && textWidth(renderRow(next, Palette{})) > width {
			lines = append(lines, line)
			line = nil
		}
		if len(line) > 0 {
			line = append(line, span{text: " | ", role: labelRole})
		}
		line = append(line, clipRow(part, width)...)
	}
	if len(line) > 0 {
		lines = append(lines, line)
	}
	return lines
}

func statusRow(status string) row {
	var role semanticRole = warningRole
	if status == "done" {
		role = successRole
	}
	return row{{text: status, role: role}}
}

func (t *Task) counterRows() []row {
	var rows []row
	var counter string
	for _, counter = range t.counters() {
		rows = append(rows, row{{text: counter, role: numberRole}})
	}
	return rows
}

func (t *Task) metricRows(now time.Time) []row {
	var rows []row
	var metric string
	for _, metric = range t.metrics(now) {
		var role semanticRole = rateRole
		if strings.HasPrefix(metric, "elapsed ") {
			role = labelRole
		} else if strings.HasPrefix(metric, "ETA ") {
			role = etaRole
		}
		rows = append(rows, row{{text: metric, role: role}})
	}
	return rows
}

func (t *Task) barRow(done, total int64, width int) row {
	var shape string = bar(done, total, t.completed, width)
	var filled int = strings.Count(shape, "=")
	return row{{text: "[", role: labelRole}, {text: strings.Repeat("=", filled), role: rateRole}, {text: strings.Repeat(".", width-filled) + "]", role: labelRole}, {text: " ", role: plainRole}, {text: percentage(done, total, t.completed), role: numberRole}}
}

func (t *Task) descriptionRow(now time.Time, frame uint64, status string) row {
	var parts []row = []row{{{text: string("|/-\\"[frame%4]), role: accentRole}}, {{text: t.label, role: headingRole}}}
	if status != "" {
		parts = append(parts, statusRow(status))
	}
	var done int64
	var total int64
	done, total = t.primary()
	if total > 0 {
		parts = append(parts, t.barRow(done, total, 10))
	}
	parts = append(parts, t.counterRows()...)
	parts = append(parts, t.metricRows(now)...)
	if t.path != "" {
		parts = append(parts, row{{text: t.path, role: pathRole}})
	}
	return joinRows(parts)
}

func (t *Task) terminalRows(now time.Time, frame uint64, status string, width int) []row {
	var heading row = row{{text: string("|/-\\"[frame%4]), role: accentRole}, {text: " ", role: plainRole}, {text: t.label, role: headingRole}}
	if status != "" {
		heading = joinRows([]row{heading, statusRow(status)})
	}
	if t.path != "" {
		heading = joinRows([]row{clipRow(heading, width/2), {{text: t.path, role: pathRole}}})
	}
	var lines []row = []row{clipRow(heading, width)}
	var counters []row = t.counterRows()
	var done int64
	var total int64
	done, total = t.primary()
	if total > 0 {
		var barWidth int = 10
		if width < 80 {
			barWidth = 5
		} else if width >= 120 {
			barWidth = 20
		}
		counters = append([]row{t.barRow(done, total, barWidth)}, counters...)
	}
	lines = append(lines, packRows(counters, width)...)
	lines = append(lines, packRows(t.metricRows(now), width)...)
	return lines
}

func (t *Task) styledDescription(now time.Time, frame uint64, status string, palette Palette) string {
	return renderRow(t.descriptionRow(now, frame, status), palette)
}

func (t *Task) styledTerminalLines(now time.Time, frame uint64, status string, width int, palette Palette) []string {
	var lines []string
	var parts row
	for _, parts = range t.terminalRows(now, frame, status, width) {
		lines = append(lines, renderRow(parts, palette))
	}
	return lines
}
