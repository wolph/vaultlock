package vault

import (
	"fmt"
	"os"
	"strings"

	"github.com/wolph/vaultlock/internal/progress"
)

type action struct{ description string }

func (a *App) showPlan(command string, state State, info VolumeInfo) error {
	var phases []string
	var actions []action
	switch command {
	case "init":
		actions = []action{{"Prepare protected state directory and recovery material"}, {"Store recovery material in Keychain"}, {"Create encrypted APFS volume"}, {"Verify created volume UUID, device and mount"}, {"Persist and verify initial state"}}
	case "lock":
		phases = []string{"pre-lock", "post-lock"}
		actions = []action{{"Acquire cooperative operation lock and revalidate the reviewed observations"}, {"Repair the vault to mounted and usable if needed"}, {"Run planned pre-lock hooks"}, {"Exclude protected state and vault from Time Machine and delete vault snapshots"}, {"Unmount and verify the expected APFS volume"}, {"Generate and durably stage the new random passphrase"}, {"Rotate the APFS passphrase and install the new plaintext recovery"}, {"Update Keychain with the new passphrase"}, {"Encrypt recovery material for the future drand round and verify it"}, {"Persist and verify ciphertext, recovery hash and locked state"}, {"Remove Keychain and plaintext recovery material"}, {"Delete data-volume snapshots"}, {"Lock APFS and verify encryption and mount resistance"}, {"Run planned post-lock hooks"}, {"Release the cooperative operation lock"}}
	case "unlock":
		if state.Locked {
			phases = []string{"pre-unlock", "post-unlock"}
			actions = []action{{"Revalidate recorded state, APFS identity and recovery artefacts"}, {"Run planned pre-unlock hooks"}, {"Recover the passphrase through the drand beacon and verify its SHA-256 hash"}, {"Durably retain verified plaintext recovery"}, {"Unlock and mount the expected APFS volume"}, {"Update Keychain and persist unlocked state"}, {"Run planned post-unlock hooks"}}
		} else {
			phases = []string{"post-unlock"}
			actions = []action{{"Verify local plaintext recovery and APFS identity"}, {"Unlock APFS if needed and mount the expected volume"}, {"Verify the usable target"}, {"Run planned post-unlock hooks"}}
		}
	}
	if err := a.freezeHooks(phases, info); err != nil {
		return err
	}
	if len(phases) > 0 {
		if !a.Options.Hooks {
			a.Report("Hooks: disabled")
		} else {
			var count int = 0
			for _, phase := range phases {
				var plan hookPlan = a.hookPlans[phase]
				for _, h := range plan.known {
					a.Report("Hook %s (%s): %q", phase, h.scope, h.path)
					count++
				}
				if plan.deferred {
					a.Report("Hook %s (vault): after mount", phase)
					count++
				}
			}
			if count == 0 {
				a.Report("Hooks: none")
			}
		}
	}
	if a.Options.Verbosity >= 2 {
		a.Report("Actions:")
		for index, item := range actions {
			a.Report("%d. %s", index+1, item.description)
		}
		for _, phase := range phases {
			for _, h := range a.hookPlans[phase].known {
				a.Report("Hook argv %q: %q", h.path, a.hookArgs(phase, h.scope, state, info))
			}
		}
	}
	return nil
}
func (a *App) colourEnabled() bool {
	return progress.ColourEnabled(a.Options.Color, a.outputTerminal || writerTerminal(a.Out))
}
func (a *App) diagnosticPalette() progress.Palette {
	return progress.Palette{Enabled: progress.ColourEnabled(a.Options.Color, a.errorTerminal || writerTerminal(a.Err))}
}
func (a *App) reportText(format string, args ...any) {
	var text string = progress.SanitiseText(fmt.Sprintf(format, args...))
	var palette progress.Palette = progress.Palette{Enabled: a.colourEnabled()}
	var lines []string = strings.Split(text, "\n")
	var index int
	for index = range lines {
		lines[index] = styleReportLine(lines[index], palette)
	}
	fmt.Fprintln(a.Out, strings.Join(lines, "\n"))
}

func styleReportLine(text string, palette progress.Palette) string {
	var word string
	var rest string
	word, rest, _ = strings.Cut(text, " ")
	var status string = strings.TrimSuffix(word, ":")
	var styled string
	switch status {
	case "LOCKED", "UNLOCKED", "Adopted":
		styled = palette.Success(status)
	case "INCONSISTENT":
		styled = palette.Error(status)
	case "REPAIRABLE":
		styled = palette.Warning(status)
	case "Adopt", "Lock", "Create", "Copy", "Would", "Run", "Hook":
		styled = palette.Heading(status)
	}
	if styled != "" {
		return styled + strings.TrimPrefix(word, status) + strings.TrimPrefix(text, word)
	}
	if strings.HasSuffix(text, ":") {
		return palette.Heading(text)
	}
	var label string
	var value string
	var found bool
	label, value, found = strings.Cut(text, ": ")
	if found {
		switch label {
		case "Hooks":
			if value == "disabled" {
				return palette.Label(label+": ") + palette.Warning(value)
			}
			return palette.Label(label+": ") + value
		case "Result":
			return palette.Label(label+": ") + palette.Success(value)
		case "Recorded locked", "APFS locked", "Target round", "Current round":
			return palette.Label(label+": ") + palette.Number(value)
		case "Device", "Mount", "Expected mount", "Plaintext", "Ciphertext", "Hash":
			return palette.Label(label+": ") + value
		}
	}
	if strings.HasSuffix(word, ".") && strings.Trim(word, "0123456789.") == "" {
		return palette.Number(word) + " " + rest
	}
	return text
}

func (a *App) progress(description string) {
	if a.display != nil {
		return
	}
	if a.Options.Progress == "never" {
		return
	}
	if a.Options.Progress != "always" {
		var file *os.File
		var ok bool
		file, ok = a.Err.(*os.File)
		if !ok || os.Getenv("TERM") == "dumb" || !adoptTerminal(file.Fd()) {
			return
		}
	}
	fmt.Fprintln(a.Err, description)
}
