package progress

import "time"

type Task struct {
	display      *Display
	label        string
	path         string
	started      time.Time
	bytes        int64
	entries      int64
	totalBytes   int64
	totalEntries int64
	closed       bool
	completed    bool
	rendered     bool
}

// Begin makes a new nested task active, restoring its parent when it ends.
// Zero totals mean the amount of work is unknown.
func (d *Display) Begin(label string, totalBytes, totalEntries int64) *Task {
	if d == nil {
		return nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	var task *Task = &Task{display: d, label: sanitise(label), started: time.Now(), totalBytes: nonnegative(totalBytes), totalEntries: nonnegative(totalEntries), closed: d.closed}
	if !d.closed {
		var outer bool = len(d.tasks) == 0
		d.tasks = append(d.tasks, task)
		if outer {
			d.renderLocked(task, "", false)
		}
	}
	return task
}

func (t *Task) SetTotal(bytes, entries int64) {
	if t == nil {
		return
	}
	t.display.mu.Lock()
	defer t.display.mu.Unlock()
	if t.closed || t.display.closed {
		return
	}
	t.totalBytes = nonnegative(bytes)
	t.totalEntries = nonnegative(entries)
}

func (t *Task) Add(bytes, entries int64, path string) {
	if t == nil {
		return
	}
	t.display.mu.Lock()
	defer t.display.mu.Unlock()
	if t.closed || t.display.closed {
		return
	}
	t.bytes = add(t.bytes, nonnegative(bytes))
	t.entries = add(t.entries, nonnegative(entries))
	t.path = sanitise(path)
}

func (t *Task) Set(bytes, entries int64, path string) {
	if t == nil {
		return
	}
	t.display.mu.Lock()
	defer t.display.mu.Unlock()
	if t.closed || t.display.closed {
		return
	}
	t.bytes = nonnegative(bytes)
	t.entries = nonnegative(entries)
	t.path = sanitise(path)
}

// Close ends a task without claiming success or forcing its percentage to 100.
func (t *Task) Close() { t.finish(false) }

// Complete records explicit success. Both finishing methods are idempotent.
func (t *Task) Complete() { t.finish(true) }

func (t *Task) finish(success bool) {
	if t == nil {
		return
	}
	var d *Display = t.display
	d.mu.Lock()
	defer d.mu.Unlock()
	if t.closed || d.closed {
		return
	}
	t.closed = true
	t.completed = success
	var status string
	if success {
		status = "done"
	}
	for index, task := range d.tasks {
		if task != t {
			continue
		}
		var active bool = index == len(d.tasks)-1
		var visible bool = t.rendered || len(d.tasks) == 1
		if active {
			d.flushStreamsLocked()
		}
		if active && visible {
			d.renderLocked(t, status, true)
		}
		d.tasks = append(d.tasks[:index], d.tasks[index+1:]...)
		if active && visible && len(d.tasks) > 0 {
			d.renderLocked(d.tasks[len(d.tasks)-1], "", false)
		}
		return
	}
}

func nonnegative(value int64) int64 {
	if value < 0 {
		return 0
	}
	return value
}

func add(left, right int64) int64 {
	if left > int64(^uint64(0)>>1)-right {
		return int64(^uint64(0) >> 1)
	}
	return left + right
}
