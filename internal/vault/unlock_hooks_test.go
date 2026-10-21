package vault

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type unlockHookRunner struct{ *lifecycleRunner }

func (r unlockHookRunner) RunHook(ctx context.Context, path string, args []string, input io.Reader, output, diagnostics io.Writer) error {
	return (systemRunner{}).RunHook(ctx, path, args, input, output, diagnostics)
}

func unlockHookFixture(t *testing.T) (*App, *lifecycleRunner, string) {
	t.Helper()
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	a.Options.Hooks = true
	a.Runner = unlockHookRunner{r}
	var marker string = filepath.Join(a.Config.Home, "hook-results")
	for _, scope := range []string{"global", "vault"} {
		var root string = a.Config.StateDir
		if scope == "vault" {
			root = filepath.Join(a.Config.MountPoint, ".vaultlock")
		}
		var directory string = filepath.Join(root, "hooks", "post-unlock.d")
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
		var script string = "#!/bin/sh\nprintf '%s\\n' '" + scope + "' >> '" + strings.ReplaceAll(marker, "'", "'\\''") + "'\n"
		if err := os.WriteFile(filepath.Join(directory, "10-record"), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	return a, r, marker
}

func TestUnlockAlreadyMountedRunsPostHooksInOrder(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	var marker string
	a, r, marker = unlockHookFixture(t)
	var output bytes.Buffer
	a.Out = &output
	if err := a.Run(context.Background(), "unlock", nil); err != nil {
		t.Fatal(err)
	}
	var actual []byte
	var err error
	actual, err = os.ReadFile(marker)
	if err != nil || string(actual) != "vault\nglobal\n" {
		t.Fatalf("post-unlock hooks skipped or out of order: %q %v", actual, err)
	}
	if !strings.Contains(output.String(), "Hook post-unlock (vault)") {
		t.Fatal("hook missing from reviewed plan")
	}
	if len(r.rotated) != 0 || r.info.Locked {
		t.Fatal("unlock rotated or sealed vault")
	}
}

func TestUnlockCanRetryFailedPostHook(t *testing.T) {
	var a *App
	var marker string
	a, _, marker = unlockHookFixture(t)
	var hook string = filepath.Join(a.Config.MountPoint, ".vaultlock", "hooks", "post-unlock.d", "10-record")
	var failure string = "#!/bin/sh\nexit 1\n"
	if err := os.WriteFile(hook, []byte(failure), 0700); err != nil {
		t.Fatal(err)
	}
	if err := a.Run(context.Background(), "unlock", nil); err == nil {
		t.Fatal("failed post-hook was silently skipped")
	}
	var actual []byte
	var err error
	actual, err = os.ReadFile(marker)
	if err != nil || string(actual) != "global\n" {
		t.Fatal("remaining post-hook did not run")
	}
	if err = os.WriteFile(hook, []byte("#!/bin/sh\nprintf '%s\\n' vault >> '"+strings.ReplaceAll(marker, "'", "'\\''")+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = a.Run(context.Background(), "unlock", nil); err != nil {
		t.Fatal(err)
	}
	actual, err = os.ReadFile(marker)
	if err != nil || string(actual) != "global\nvault\nglobal\n" {
		t.Fatalf("hook retry failed: %q %v", actual, err)
	}
}

func TestUnlockedPostHooksRespectDryRunAndNoHooks(t *testing.T) {
	for _, mode := range []string{"dry-run", "no-hooks"} {
		t.Run(mode, func(t *testing.T) {
			var a *App
			var marker string
			a, _, marker = unlockHookFixture(t)
			a.Options.DryRun = mode == "dry-run"
			a.Options.Hooks = mode != "no-hooks"
			if err := a.Run(context.Background(), "unlock", nil); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("hook ran despite skip option")
			}
		})
	}
}
