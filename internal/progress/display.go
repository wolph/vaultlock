// Package progress renders independent activity heartbeats for nested work.
package progress

import (
	"io"
	"strings"
	"sync"
	"time"
)

type Options struct {
	Mode     string
	Interval time.Duration
	Terminal bool
	Color    string
}

type Display struct {
	mu                  sync.Mutex
	output              io.Writer
	options             Options
	tasks               []*Task
	stop                chan struct{}
	done                chan struct{}
	closed              bool
	paused              int
	liveLines           int
	partialWriters      int
	partialNeedsNewline bool
	writers             []*wrappedWriter
	failure             error
	frame               uint64
	palette             Palette
}

// New starts an independent ticker. Non-terminal output never uses cursor controls.
func New(output io.Writer, options Options) *Display {
	if output == nil {
		output = io.Discard
	}
	if options.Interval <= 0 {
		options.Interval = 500 * time.Millisecond
		if options.Terminal {
			options.Interval = 200 * time.Millisecond
		}
	}
	if options.Interval > 500*time.Millisecond {
		options.Interval = 500 * time.Millisecond
	}
	var display *Display = &Display{output: output, options: options, stop: make(chan struct{}), done: make(chan struct{}), palette: Palette{Enabled: ColourEnabled(options.Color, options.Terminal)}}
	go display.run()
	return display
}

func (d *Display) run() {
	defer close(d.done)
	var ticker *time.Ticker = time.NewTicker(d.options.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-d.stop:
			return
		case <-ticker.C:
			d.mu.Lock()
			if len(d.tasks) > 0 {
				d.renderLocked(d.tasks[len(d.tasks)-1], "", false)
			}
			d.mu.Unlock()
		}
	}
}

// Close stops and joins the ticker. It does not claim unfinished tasks succeeded.
func (d *Display) Close() {
	if d == nil {
		return
	}
	d.mu.Lock()
	if !d.closed {
		d.flushStreamsLocked()
		if len(d.tasks) > 0 {
			d.renderLocked(d.tasks[len(d.tasks)-1], "stopped", true)
		}
		d.closed = true
		d.clearLocked()
		close(d.stop)
	}
	d.mu.Unlock()
	<-d.done
}

// Err returns the first rendering or wrapped-output error.
func (d *Display) Err() error {
	if d == nil {
		return nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.failure
}

// Pause clears live output until its idempotent restoration function is called.
func (d *Display) Pause() func() {
	if d == nil {
		return func() {}
	}
	d.mu.Lock()
	d.flushStreamsLocked()
	d.paused++
	d.clearLocked()
	d.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			d.mu.Lock()
			defer d.mu.Unlock()
			d.paused--
			if len(d.tasks) > 0 {
				d.renderLocked(d.tasks[len(d.tasks)-1], "", false)
			}
		})
	}
}

func (d *Display) recordErrorLocked(err error) {
	if err != nil && d.failure == nil {
		d.failure = err
		d.liveLines = 0
	}
}

func (d *Display) writeLocked(text string) {
	var count int
	var err error
	count, err = io.WriteString(d.output, text)
	if err == nil && count != len(text) {
		err = io.ErrShortWrite
	}
	d.recordErrorLocked(err)
}

func (d *Display) clearLocked() {
	if d.liveLines > 0 && d.failure == nil {
		d.writeLocked("\r\x1b[2K")
		for line := 1; line < d.liveLines; line++ {
			d.writeLocked("\x1b[1A\r\x1b[2K")
		}
	}
	d.liveLines = 0
}

func (d *Display) renderLocked(task *Task, status string, final bool) {
	if d.closed || d.paused > 0 || d.failure != nil || d.options.Mode == "never" {
		return
	}
	if !d.options.Terminal && d.options.Mode == "auto" && task.rendered && !final {
		return
	}
	d.frame++
	task.rendered = true
	var now time.Time = time.Now()
	if !d.options.Terminal || d.partialWriters > 0 {
		var prefix string
		if d.partialNeedsNewline {
			prefix = "\n"
			d.partialNeedsNewline = false
		}
		d.writeLocked(prefix + task.styledDescription(now, d.frame, status, d.palette) + "\n")
		return
	}
	d.clearLocked()
	var lines []string = task.styledTerminalLines(now, d.frame, status, terminalWidth(d.output), d.palette)
	for _, writer := range d.writers {
		if (writer.transient || writer.managed) && writer.terminal && len(writer.line) > 0 {
			lines = append(lines, clipStreamLine(string(writer.line), terminalWidth(d.output)-1))
		}
	}
	var text string = strings.Join(lines, "\n")
	if final {
		text += "\n"
	} else {
		d.liveLines = len(lines)
	}
	d.writeLocked(text)
}
