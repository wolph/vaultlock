package vault

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	progressengine "github.com/wolph/vaultlock/internal/progress"
)

type adoptProgress struct {
	display     *progressengine.Display
	task        *progressengine.Task
	parent      *adoptProgress
	ownDisplay  bool
	enabled     bool
	terminal    bool
	label       string
	count       int64
	bytes       int64
	sourceCount int64
	sourceBytes int64
	copyCount   int64
	copyBytes   int64
	passCount   int64
	passNumber  int64
	lastPublish time.Time
	lastPath    string
	check       func() error
	hashCache   adoptHashCache
}

const adoptMetadataPhase string = "Restore native metadata and timestamps"
const adoptIdentityPhase string = "Verify copied entry identities and hardlinks"

func newAdoptProgress(output io.Writer, mode string) *adoptProgress {
	return newAdoptProgressWithColour(output, mode, "auto")
}

func newAdoptProgressWithColour(output io.Writer, mode string, colour string) *adoptProgress {
	var terminal bool
	var file *os.File
	var ok bool
	file, ok = output.(*os.File)
	if ok {
		terminal = adoptTerminal(file.Fd()) && os.Getenv("TERM") != "dumb"
	}
	return &adoptProgress{
		display:    progressengine.New(output, progressengine.Options{Mode: mode, Color: colour, Terminal: terminal, Interval: 200 * time.Millisecond}),
		ownDisplay: true, enabled: mode != "never", terminal: terminal,
		hashCache: make(adoptHashCache),
	}
}

func (a *App) adoptionProgress() *adoptProgress {
	if a.display != nil {
		return &adoptProgress{display: a.display, enabled: a.Options.Progress != "never", check: a.beforeMutation, hashCache: make(adoptHashCache)}
	}
	var fallback *adoptProgress = newAdoptProgressWithColour(a.Err, a.Options.Progress, a.Options.Color)
	fallback.check = a.beforeMutation
	return fallback
}

func (p *adoptProgress) phase(label string) { p.phasePasses(label, 1) }

func (p *adoptProgress) phasePasses(label string, passes int64) {
	if p == nil {
		return
	}
	p.complete()
	p.label = label
	p.count = 0
	p.bytes = 0
	p.passCount = passes
	p.passNumber = 0
	var totalBytes int64 = p.sourceBytes * passes
	var totalEntries int64 = p.sourceCount * passes
	if label == "Copy source into vault" {
		totalBytes = p.copyBytes
		totalEntries = p.copyCount
	}
	if label == adoptMetadataPhase || label == adoptIdentityPhase {
		totalBytes = 0
	}
	p.task = p.display.Begin(label, totalBytes, totalEntries)
}

func (p *adoptProgress) pass(path string) *adoptProgress {
	if p == nil || p.task == nil {
		return nil
	}
	p.passNumber++
	var label string = fmt.Sprintf("%s, pass %d/%d (%s)", p.label, p.passNumber, p.passCount, filepath.Base(path))
	return &adoptProgress{
		display: p.display, task: p.display.Begin(label, p.sourceBytes, p.sourceCount), parent: p,
		label: label, sourceCount: p.sourceCount, sourceBytes: p.sourceBytes, enabled: p.enabled, check: p.check,
		hashCache: p.hashCache,
	}
}

func (p *adoptProgress) current(stage string, path string) {
	if p == nil || p.task == nil {
		return
	}
	p.publish(stage+": "+path, false)
}

func (p *adoptProgress) add(size int64, entries int64, path string) {
	if p == nil || p.task == nil {
		return
	}
	var firstBytes bool = p.bytes == 0 && size > 0
	p.bytes += size
	p.count += entries
	p.publish(path, firstBytes)
	if p.parent != nil {
		p.parent.add(size, entries, path)
	}
}

func (p *adoptProgress) publish(path string, force bool) {
	if p == nil || p.task == nil {
		return
	}
	if !force && path == p.lastPath && time.Since(p.lastPublish) < 100*time.Millisecond {
		return
	}
	p.lastPath = path
	p.lastPublish = time.Now()
	p.task.Set(p.bytes, p.count, path)
}

func (p *adoptProgress) tick(size int64, path string) { p.add(size, 1, path) }

func (p *adoptProgress) finish() {
	if p == nil {
		return
	}
	if p.task != nil {
		p.publish(p.lastPath, true)
		p.task.Close()
		p.task = nil
	}
	p.label = ""
	if p.ownDisplay {
		p.display.Close()
	}
}

func (p *adoptProgress) complete() {
	if p == nil {
		return
	}
	if p.task != nil {
		p.publish(p.lastPath, true)
		p.task.Complete()
		p.task = nil
	}
	p.label = ""
}

func (p *adoptProgress) scan(ctx context.Context, path string) {
	if p == nil {
		return
	}
	var task *progressengine.Task = p.display.Begin("Scan source metadata", 0, 0)
	defer task.Close()
	var root *os.Root
	var err error
	root, err = os.OpenRoot(path)
	if err != nil {
		return
	}
	defer root.Close()
	var count int64
	var bytes int64
	err = fs.WalkDir(root.FS(), ".", func(relative string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		task.Set(0, count, "stat: "+relative)
		count++
		if entry.Type().IsRegular() {
			var info fs.FileInfo
			info, walkErr = entry.Info()
			if walkErr != nil {
				return walkErr
			}
			bytes += info.Size()
		}
		task.Set(0, count, relative)
		return nil
	})
	if err == nil {
		p.sourceCount = count
		p.sourceBytes = bytes
		task.SetTotal(0, count)
		task.Complete()
	}
}

type adoptCopyRunner interface {
	RunAdoptCopy(context.Context, []string, func(int64, string)) error
}

func (a *App) copyAdopt(ctx context.Context, source string, destination string, progress *adoptProgress) error {
	progress.current("copy", source)
	var presentationErr error = progress.checkMutation()
	if presentationErr != nil {
		return presentationErr
	}
	// Resource handling merges literal ._* files into their neighbours. Copy
	// those names verbatim and restore native metadata from the verified manifest.
	var args []string = []string{"-V", "-X", "--norsrc", "--extattr", "--acl", "--qtn", "--preserveHFSCompression", source, destination}
	var runner adoptCopyRunner
	var ok bool
	runner, ok = a.Runner.(adoptCopyRunner)
	if ok {
		var copyErr error = runner.RunAdoptCopy(ctx, args, progress.tick)
		if copyErr == nil {
			progress.finishCopyCounters()
		}
		return copyErr
	}
	// A generic runner does not provide copy events. Keep its progress indeterminate.
	if progress != nil && progress.task != nil {
		progress.task.SetTotal(0, 0)
	}
	var err error
	_, err = a.Runner.Run(ctx, "/usr/bin/ditto", args, nil)
	return err
}

func (systemRunner) RunAdoptCopy(ctx context.Context, args []string, tick func(int64, string)) error {
	var command *exec.Cmd = exec.CommandContext(ctx, "/usr/bin/ditto", args...)
	var entry string
	for _, entry = range cleanEnvironment(os.Environ()) {
		if !strings.HasPrefix(entry, "DITTONORSRC=") {
			command.Env = append(command.Env, entry)
		}
	}
	var stderr io.ReadCloser
	var err error
	stderr, err = command.StderrPipe()
	if err != nil {
		return err
	}
	if err = command.Start(); err != nil {
		return err
	}
	var scanner *bufio.Scanner = bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	var diagnostic string
	for scanner.Scan() {
		var line string = scanner.Text()
		if strings.HasPrefix(line, "ditto:") {
			diagnostic = line
			if len(diagnostic) > 4096 {
				diagnostic = diagnostic[:4096]
			}
		}
		var amount string
		var path string
		var found bool
		amount, path, found = strings.Cut(line, " bytes for ./")
		if found {
			var size int64
			size, err = strconv.ParseInt(strings.TrimSpace(amount), 10, 64)
			if err == nil && size >= 0 {
				tick(size, path)
			}
		} else if strings.HasPrefix(line, "hardlinked ./") || strings.HasPrefix(line, "linked ./") {
			_, path, _ = strings.Cut(line, "./")
			tick(0, path)
		}
	}
	var scanErr error = scanner.Err()
	if scanErr != nil {
		_, _ = io.Copy(io.Discard, stderr)
	}
	var waitErr error = command.Wait()
	if waitErr != nil {
		if diagnostic != "" {
			return fmt.Errorf("%s: %w", diagnostic, waitErr)
		}
		return waitErr
	}
	return scanErr
}

func (p *adoptProgress) activity(label string) *adoptProgress {
	if p == nil || p.display == nil {
		return nil
	}
	return &adoptProgress{display: p.display, task: p.display.Begin(label, 0, 0), label: label, enabled: p.enabled, hashCache: p.hashCache}
}

func (p *adoptProgress) checkMutation() error {
	if p == nil || p.check == nil {
		return nil
	}
	return p.check()
}

func (p *adoptProgress) manifestTotals(manifest adoptManifest) {
	if p == nil {
		return
	}
	p.sourceCount = int64(len(manifest.Entries))
	p.sourceBytes = 0
	p.copyCount = 0
	p.copyBytes = 0
	var entry adoptEntry
	for _, entry = range manifest.Entries {
		switch entry.Metadata.Mode & 0170000 {
		case 0100000:
			p.sourceBytes += entry.Metadata.Size
			p.copyCount++
			if entry.Hardlink == entry.Path {
				p.copyBytes += entry.Metadata.Size
			}
		case 0120000:
			p.copyCount++
		}
	}
	if p.task != nil {
		p.task.SetTotal(p.sourceBytes*p.passCount, p.sourceCount*p.passCount)
	}
}

func (p *adoptProgress) finishCopyCounters() {
	if p == nil || p.task == nil {
		return
	}
	if p.count != p.copyCount || p.bytes != p.copyBytes {
		p.task.SetTotal(0, 0)
	}
}
