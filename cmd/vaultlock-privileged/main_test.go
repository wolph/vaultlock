package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

const testUUID string = "0E4C5B8A-1D2F-4A6B-9C3D-7E8F90A1B2C3"

func TestVersionAndHelp(t *testing.T) {
	var out bytes.Buffer
	if status := run(context.Background(), []string{"--version"}, identity{realUID: 501, effectiveUID: 501}, nil, &out, &out); status != 0 || !strings.HasPrefix(out.String(), "vaultlock-privileged ") {
		t.Fatalf("version: status %d output %q", status, out.String())
	}
	out.Reset()
	if status := run(context.Background(), nil, identity{realUID: 501, effectiveUID: 501}, nil, &out, &out); status != 64 || !strings.Contains(out.String(), "Usage:") {
		t.Fatalf("no arguments: status %d output %q", status, out.String())
	}
}

func TestStorageOperationsNeedEffectiveRoot(t *testing.T) {
	var stderr bytes.Buffer
	var status int = run(context.Background(), []string{"lock", testUUID}, identity{realUID: 501, effectiveUID: 501}, nil, &stderr, &stderr)
	if status != 77 || !strings.Contains(stderr.String(), "not running as root") {
		t.Fatalf("status %d output %q", status, stderr.String())
	}
}

func TestMalformedRequestsFailBeforeAnyPrivilegeCheck(t *testing.T) {
	for _, args := range [][]string{{"lock"}, {"unlock", "disk3s7"}, {"mount", testUUID}} {
		var stderr bytes.Buffer
		if status := run(context.Background(), args, identity{realUID: 501, effectiveUID: 0}, nil, &stderr, &stderr); status != 64 {
			t.Fatalf("%q: status %d output %q", args, status, stderr.String())
		}
	}
}

func TestAdministrationRefusesSetuidInvocation(t *testing.T) {
	for _, args := range [][]string{{"install"}, {"allow", testUUID}, {"revoke", testUUID}, {"list"}, {"uninstall"}} {
		var stderr bytes.Buffer
		var status int = run(context.Background(), args, identity{realUID: 501, effectiveUID: 0}, nil, &stderr, &stderr)
		if status != 1 || !strings.Contains(stderr.String(), "sudo") {
			t.Fatalf("%q: status %d output %q", args, status, stderr.String())
		}
	}
}

func TestAllowOwnerComesFromSudoOrOperand(t *testing.T) {
	var owner int
	var err error
	owner, err = allowOwner([]string{"allow", testUUID}, identity{sudoUser: "501"})
	if err != nil || owner != 501 {
		t.Fatalf("sudo owner %d %v", owner, err)
	}
	owner, err = allowOwner([]string{"allow", testUUID, "502"}, identity{sudoUser: "501"})
	if err != nil || owner != 502 {
		t.Fatalf("explicit owner %d %v", owner, err)
	}
	for _, c := range []struct {
		args []string
		ids  identity
	}{
		{[]string{"allow", testUUID}, identity{}},
		{[]string{"allow", testUUID, "0"}, identity{}},
		{[]string{"allow", testUUID, "-1"}, identity{}},
		{[]string{"allow", testUUID, "wolph"}, identity{}},
		{[]string{"allow", testUUID}, identity{sudoUser: "0"}},
	} {
		if _, err = allowOwner(c.args, c.ids); err == nil {
			t.Fatalf("accepted %q with %+v", c.args, c.ids)
		}
	}
}
