package vault

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/wolph/vaultlock/internal/privileged"
)

func privilegedCalls(calls [][]string) (helper, sudo int) {
	for _, call := range calls {
		switch call[0] {
		case privileged.HelperPath:
			helper++
		case "/usr/bin/sudo":
			sudo++
		}
	}
	return helper, sudo
}

const helperTestUUID string = "0E4C5B8A-1D2F-4A6B-9C3D-7E8F90A1B2C3"

// helperFixture gives the fixture volume a well-formed UUID, as the helper
// refuses anything else.
func helperFixture(t *testing.T) (*App, *lifecycleRunner) {
	t.Helper()
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	r.info.UUID = helperTestUUID
	if err := a.writeState(State{VolumeUUID: helperTestUUID}); err != nil {
		t.Fatal(err)
	}
	return a, r
}

func TestLockUnlockUseHelperWhenInstalledAndAllowed(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = helperFixture(t)
	var probed []string
	a.HelperProbe = func(uuid string) bool {
		probed = append(probed, uuid)
		return true
	}
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	a.Crypto = &fixtureCrypto{decrypted: r.rotated}
	if err := a.Run(context.Background(), "unlock", nil); err != nil {
		t.Fatal(err)
	}
	var helper, sudo int
	helper, sudo = privilegedCalls(r.calls)
	if sudo != 0 || helper < 7 {
		t.Fatalf("helper %d sudo %d calls: %q", helper, sudo, r.calls)
	}
	for _, uuid := range probed {
		if uuid != "" && uuid != helperTestUUID {
			t.Fatalf("probed unexpected volume %q", uuid)
		}
	}
	for _, call := range r.calls {
		if call[0] == privileged.HelperPath {
			if _, err := privileged.Parse(call[1:]); err != nil {
				t.Fatalf("helper call %q: %v", call, err)
			}
		}
	}
}

func TestLockFallsBackToSudoWithoutUsableHelper(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = helperFixture(t)
	a.HelperProbe = func(string) bool { return false }
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	var helper, sudo int
	helper, sudo = privilegedCalls(r.calls)
	if helper != 0 || sudo == 0 {
		t.Fatalf("helper %d sudo %d calls: %q", helper, sudo, r.calls)
	}
}

func TestMalformedVolumeUUIDNeverReachesHelper(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = lifecycleFixture(t)
	a.HelperProbe = func(string) bool { return true }
	if err := a.Run(context.Background(), "lock", []string{"1h"}); err != nil {
		t.Fatal(err)
	}
	for _, call := range r.calls {
		if call[0] == privileged.HelperPath && len(call) > 2 && call[2] == "UUID" {
			t.Fatalf("helper received the malformed fixture UUID: %q", call)
		}
	}
}

func TestHelperProbeDefaultsToInstalledFiles(t *testing.T) {
	var a *App
	a, _ = lifecycleFixture(t)
	a.HelperProbe = nil
	if err := privileged.UsablePath(privileged.HelperPath); err != nil && a.helperUsable("UUID") {
		t.Fatal("helper reported usable although it is not installed")
	}
}

func TestHelperCallsAreLabelledAndGated(t *testing.T) {
	var args []string = privileged.Request{Kind: privileged.KindLock, UUID: "0E4C5B8A-1D2F-4A6B-9C3D-7E8F90A1B2C3"}.Args()
	if label := operationLabel(privileged.HelperPath, args); label != "Seal the encrypted APFS volume" || strings.Contains(label, "administrator") {
		t.Fatalf("label %q", label)
	}
	if !mutatesStorage(privileged.HelperPath, args) {
		t.Fatal("helper call not treated as a storage mutation")
	}
	if label := operationLabel(privileged.HelperPath, []string{"bogus"}); label != "Wait for the privileged helper" {
		t.Fatalf("fallback label %q", label)
	}
}

// installedProbe emulates an installed helper whose allowlist is whatever the
// fixture runner has recorded through sudo.
func installedProbe(r *lifecycleRunner) func(string) bool {
	return func(uuid string) bool {
		if uuid == "" {
			return true
		}
		for _, allowed := range r.allowed {
			if allowed == uuid {
				return true
			}
		}
		return false
	}
}

func TestInitRegistersVolumeWithInstalledHelper(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = initFixture(t)
	r.info.UUID = helperTestUUID
	a.HelperProbe = installedProbe(r)
	var output bytes.Buffer
	a.Out = &output
	if err := a.Run(context.Background(), "init", nil); err != nil {
		t.Fatal(err)
	}
	if strings.Join(r.allowed, ",") != helperTestUUID {
		t.Fatalf("allowed %q", r.allowed)
	}
	if !strings.Contains(output.String(), "Privileged helper: volume "+helperTestUUID+" allowed") {
		t.Fatalf("output %q", output.String())
	}
}

func TestInitSkipsRegistrationWithoutHelper(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = initFixture(t)
	r.info.UUID = helperTestUUID
	var output bytes.Buffer
	a.Out = &output
	if err := a.Run(context.Background(), "init", nil); err != nil {
		t.Fatal(err)
	}
	if len(r.allowed) != 0 || strings.Contains(output.String(), "Privileged helper") {
		t.Fatalf("allowed %q output %q", r.allowed, output.String())
	}
}

func TestPrivilegedAllowRegistersExistingVault(t *testing.T) {
	var a *App
	var r *lifecycleRunner
	a, r = helperFixture(t)
	var output bytes.Buffer
	a.Out = &output
	if err := a.Run(context.Background(), "privileged", []string{"allow"}); err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("without helper: %v", err)
	}
	a.HelperProbe = installedProbe(r)
	a.Options.DryRun = true
	if err := a.Run(context.Background(), "privileged", []string{"allow"}); err != nil || len(r.allowed) != 0 || !strings.Contains(output.String(), "Would allow "+helperTestUUID) {
		t.Fatalf("dry run: err %v allowed %q output %q", err, r.allowed, output.String())
	}
	a.Options.DryRun = false
	output.Reset()
	if err := a.Run(context.Background(), "privileged", []string{"allow"}); err != nil || strings.Join(r.allowed, ",") != helperTestUUID {
		t.Fatalf("allow: err %v allowed %q", err, r.allowed)
	}
	if !strings.Contains(output.String(), "volume "+helperTestUUID+" allowed") {
		t.Fatalf("output %q", output.String())
	}
	var calls int = len(r.calls)
	output.Reset()
	if err := a.Run(context.Background(), "privileged", []string{"allow"}); err != nil || len(r.calls) != calls || !strings.Contains(output.String(), "already allowed") {
		t.Fatalf("repeat: err %v calls %d output %q", err, len(r.calls)-calls, output.String())
	}
	if err := a.Run(context.Background(), "privileged", []string{"revoke"}); err == nil {
		t.Fatal("revoke accepted")
	}
}

func TestStatusReportsHelperState(t *testing.T) {
	var cases []struct {
		probe func(string) bool
		want  string
	}
	cases = []struct {
		probe func(string) bool
		want  string
	}{
		{func(string) bool { return false }, "Privileged helper: not installed, storage operations use sudo"},
		{func(uuid string) bool { return uuid == "" }, "Privileged helper: installed, volume not allowed. Run: vaultlock privileged allow"},
		{func(string) bool { return true }, "Privileged helper: installed, volume allowed"},
	}
	for _, c := range cases {
		var a *App
		a, _ = helperFixture(t)
		a.HelperProbe = c.probe
		var output bytes.Buffer
		a.Out = &output
		if err := a.Run(context.Background(), "status", nil); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(output.String(), c.want) {
			t.Fatalf("status output %q lacks %q", output.String(), c.want)
		}
	}
}
