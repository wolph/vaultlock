package vault

import (
	"context"
	"errors"
	"fmt"
	"github.com/wolph/vaultlock/internal/progress"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type hook struct {
	path, scope  string
	identity     os.FileInfo
	linkIdentity os.FileInfo
	linkText     string
}

func (a *App) hooks(phase string, includeLocal bool) ([]hook, error) {
	defer a.wait("Discover " + phase + " lifecycle hooks")()
	var result []hook
	var appendHook func(path string,
		scope string) error = func(path, scope string) error {
		var info os.FileInfo
		var err error

		info, err = os.Stat(path)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
			return nil
		}
		var link os.FileInfo

		link, err = os.Lstat(path)
		if err != nil {
			return err
		}
		var text string = ""
		if link.Mode()&os.ModeSymlink != 0 {
			text, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}
		result = append(result, hook{path: path, scope: scope, identity: info, linkIdentity: link, linkText: text})
		return nil
	}
	var appendDir func(path string,
		scope string) error = func(path, scope string) error {
		var entries []os.DirEntry
		var err error

		entries, err = os.ReadDir(path)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		for _, entry := range entries {
			if !strings.HasPrefix(entry.Name(), ".") {
				if err := appendHook(filepath.Join(path, entry.Name()), scope); err != nil {
					return err
				}
			}
		}
		return nil
	}
	var global string = filepath.Join(a.Config.StateDir, "hooks", phase+".d")
	var local string = filepath.Join(a.Config.MountPoint, ".vaultlock", "hooks", phase+".d")
	if phase == "pre-lock" {
		if err := appendHook(filepath.Join(a.Config.StateDir, "pre-lock.sh"), "global"); err != nil {
			return nil, err
		}
	}
	if includeLocal && phase == "post-unlock" {
		if err := appendDir(local, "vault"); err != nil {
			return nil, err
		}
	}
	if err := appendDir(global, "global"); err != nil {
		return nil, err
	}
	if includeLocal && phase == "pre-lock" {
		if err := appendDir(local, "vault"); err != nil {
			return nil, err
		}
	}
	return result, nil
}
func (a *App) RunHooks(ctx context.Context, phase string, state State, info VolumeInfo) error {
	if !a.Options.Hooks {
		return nil
	}
	switch phase {
	case "pre-lock", "post-lock", "pre-unlock", "post-unlock":
	default:
		return errors.New("unknown hook phase")
	}
	var hooks []hook
	var err error

	if phase == "pre-lock" || phase == "post-unlock" {
		var observed VolumeInfo
		var mountErr error

		observed, mountErr = a.CheckMount(ctx, state)
		if mountErr != nil || observed.MountPoint != a.Config.MountPoint || observed.Device != info.Device {
			return errors.New("vault hook mount is unavailable or changed")
		}
	}
	hooks, err = a.resolveHooks(phase, true)
	if err != nil {
		return err
	}
	var failures []error
	for _, h := range hooks {
		var current os.FileInfo
		var err error

		current, err = os.Stat(h.path)
		var link os.FileInfo
		var linkErr error

		link, linkErr = os.Lstat(h.path)
		var text string = ""
		if linkErr == nil && link.Mode()&os.ModeSymlink != 0 {
			text, linkErr = os.Readlink(h.path)
		}
		if err != nil || linkErr != nil || !os.SameFile(link, h.linkIdentity) || text != h.linkText || link.Mode() != h.linkIdentity.Mode() || !os.SameFile(current, h.identity) || current.Mode() != h.identity.Mode() || !current.Mode().IsRegular() || current.Mode().Perm()&0111 == 0 {
			return errors.New("hook identity or executable state changed")
		}
		if h.scope == "vault" {
			var observed VolumeInfo
			var err error

			observed, err = a.CheckMount(ctx, state)
			if err != nil || observed.UUID != info.UUID || observed.Device != info.Device || observed.MountPoint != a.Config.MountPoint {
				return errors.New("vault hook mount identity changed")
			}
		}
		var args []string = a.hookArgs(phase, h.scope, state, info)
		a.Report("Run hook %s (%s): %q", phase, h.scope, h.path)
		if a.Options.Verbosity >= 2 {
			a.Report("Hook argv: %q", args)
		}
		var output []byte
		var task *progress.Task = a.beginProgress("Wait for "+phase+" hook "+filepath.Base(h.path)+" ("+h.scope+")", 0, 0)
		if progressErr := a.beforeMutation(); progressErr != nil {
			task.Close()
			return progressErr
		}
		if runner, ok := a.Runner.(HookRunner); ok {
			err = runner.RunHook(ctx, h.path, args, os.Stdin, a.Out, a.Err)
		} else {
			output, err = a.Runner.Run(ctx, h.path, args, nil)
		}
		if err == nil {
			task.Complete()
		} else {
			task.Close()
			err = errors.New("lifecycle hook failed")
		}

		if len(output) > 0 {
			fmt.Fprint(a.Out, string(output))
		}
		if err != nil {
			if strings.HasPrefix(phase, "pre-") {
				return err
			}
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

type hookPlan struct {
	known    []hook
	deferred bool
}

func (a *App) freezeHooks(phases []string, info VolumeInfo) error {
	defer a.wait("Inspect and freeze the lifecycle hook plan")()
	a.hookPlans = make(map[string]hookPlan)
	if !a.Options.Hooks {
		return nil
	}
	for _, phase := range phases {
		var hooks []hook
		var err error

		var deferred bool = info.MountPoint == "" && (phase == "pre-lock" || phase == "post-unlock")
		hooks, err = a.hooks(phase, !deferred)
		if err != nil {
			return err
		}
		if deferred {
			var global []hook
			for _, h := range hooks {
				if h.scope == "global" {
					global = append(global, h)
				}
			}
			hooks = global
		}
		a.hookPlans[phase] = hookPlan{hooks, deferred}
	}
	return nil
}
func (a *App) resolveHooks(phase string, includeDeferred bool) ([]hook, error) {
	var current []hook
	var err error

	var plan hookPlan
	var present bool
	plan, present = a.hookPlans[phase]
	current, err = a.hooks(phase, !plan.deferred || includeDeferred)
	if err != nil {
		return nil, err
	}
	if !present {
		return current, nil
	}
	var compared []hook
	for _, h := range current {
		if !plan.deferred || h.scope != "vault" {
			compared = append(compared, h)
		}
	}
	if len(compared) != len(plan.known) {
		return nil, errors.New("hook discovery changed after planning")
	}
	for index, before := range plan.known {
		var after hook = compared[index]
		if before.path != after.path || before.scope != after.scope || !os.SameFile(before.identity, after.identity) || before.identity.Mode() != after.identity.Mode() || !os.SameFile(before.linkIdentity, after.linkIdentity) || before.linkIdentity.Mode() != after.linkIdentity.Mode() || before.linkText != after.linkText {
			return nil, errors.New("planned hook identity changed")
		}
	}
	return current, nil
}
func (a *App) validateHookPlans() error {
	if !a.Options.Hooks {
		return nil
	}
	for phase := range a.hookPlans {
		if _, err := a.resolveHooks(phase, false); err != nil {
			return err
		}
	}
	return nil
}
func (a *App) hookArgs(phase, scope string, state State, info VolumeInfo) []string {
	var deadline string
	var epoch string
	var round string

	deadline, epoch, round = "null", "null", "null"
	if state.Deadline != nil {
		deadline = *state.Deadline
	}
	if state.DeadlineEpoch != nil {
		epoch = strconv.FormatInt(*state.DeadlineEpoch, 10)
	}
	if state.Round != nil {
		round = strconv.FormatUint(*state.Round, 10)
	}
	var locked string = strconv.FormatBool(phase == "pre-unlock" || phase == "post-lock")
	return []string{"--phase", phase, "--scope", scope, "--volume", a.Config.Volume, "--mount-point", a.Config.MountPoint, "--volume-uuid", state.VolumeUUID, "--device", info.Device, "--state-dir", a.Config.StateDir, "--state-file", a.path("state.json"), "--deadline", deadline, "--deadline-epoch", epoch, "--round", round, "--locked", locked}
}
