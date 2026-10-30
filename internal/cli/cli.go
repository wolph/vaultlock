package cli

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/wolph/vaultlock/internal/progress"
	"github.com/wolph/vaultlock/internal/timelock"
	"github.com/wolph/vaultlock/internal/vault"
)

// Version is set when building a release binary.
var Version string = "dev"

const help string = `Usage: vaultlock <command> [options] [operands]

Commands:
  init                 Create an encrypted APFS vault.
  adopt <directory>    Move a directory onto the vault and leave a symlink.
  lock <deadline>      Seal the vault until a future drand round.
  unlock               Recover and mount the vault after its deadline.
  status               Inspect recorded state and actual APFS state.
  privileged allow     Allow this vault's volume for the setuid helper.

Options (before operands):
  --dry-run            Preview lifecycle operations without changing anything.
  --yes                Confirm init, adopt, or lock without a terminal prompt.
  --no-hooks           Skip lock and unlock hooks.
  -v, --verbose        Show detailed state and progress.
  -vv, --very-verbose   Show the full plan and hook arguments.
  --color=MODE         auto, always, or never (default: auto).
  --progress=MODE      auto, always, or never (default: auto).
                       Show activity throughout long operations.
  -h, --help           Show help.
  --version            Show the version.

Deadlines:
  vaultlock lock 20h
  vaultlock lock 1d4h30m
  vaultlock lock "09:00 +2d"
  vaultlock lock "2027-01-02 09:00"

Requires macOS and APFS. Time-lock encryption is built into this binary.
`

type invocation struct {
	command  string
	options  vault.Options
	operands []string
}

func parse(arguments []string) (invocation, error) {
	var result invocation = invocation{options: vault.Options{Hooks: true, Color: "auto", Progress: "auto"}}
	if len(arguments) == 0 {
		return result, fmt.Errorf("a command is required")
	}
	result.command = arguments[0]
	switch result.command {
	case "init", "adopt", "lock", "unlock", "status", "privileged":
	default:
		return result, fmt.Errorf("unknown command: %s", result.command)
	}
	var operandsStarted bool
	var literalOperands bool
	var argument string
	for _, argument = range arguments[1:] {
		if !operandsStarted && argument == "--" {
			operandsStarted = true
			literalOperands = true
			continue
		}
		if literalOperands {
			result.operands = append(result.operands, argument)
			continue
		}
		if strings.HasPrefix(argument, "-") {
			if operandsStarted {
				return result, fmt.Errorf("options must precede %s operands: %s", result.command, argument)
			}
			var optionError error = parseOption(&result.options, argument)
			if optionError != nil {
				return result, optionError
			}
			continue
		}
		operandsStarted = true
		result.operands = append(result.operands, argument)
	}
	return result, validate(result)
}

func parseOption(options *vault.Options, argument string) error {
	switch argument {
	case "-v", "--verbose":
		if options.Verbosity < 1 {
			options.Verbosity = 1
		}
	case "-vv", "--very-verbose":
		options.Verbosity = 2
	case "--dry-run":
		options.DryRun = true
	case "--yes":
		options.Yes = true
	case "--no-hooks":
		options.Hooks = false
	default:
		var key string
		var value string
		var found bool
		key, value, found = strings.Cut(argument, "=")
		if !found || (key != "--color" && key != "--progress") {
			return fmt.Errorf("unknown option: %s", argument)
		}
		if value != "auto" && value != "always" && value != "never" {
			return fmt.Errorf("invalid %s mode: %s", strings.TrimPrefix(key, "--"), value)
		}
		if key == "--color" {
			options.Color = value
		} else {
			options.Progress = value
		}
	}
	return nil
}

func validate(value invocation) error {
	if value.command == "status" && (value.options.DryRun || value.options.Yes || !value.options.Hooks) {
		return fmt.Errorf("status accepts only presentation options")
	}
	if value.command == "privileged" {
		if len(value.operands) != 1 || value.operands[0] != "allow" {
			return fmt.Errorf("privileged requires the allow operand")
		}
		if value.options.Yes || !value.options.Hooks {
			return fmt.Errorf("privileged allow accepts only --dry-run and presentation options")
		}
		return nil
	}
	if value.command == "unlock" && value.options.Yes {
		return fmt.Errorf("--yes is not valid for unlock")
	}
	if (value.command == "init" || value.command == "adopt") && !value.options.Hooks {
		return fmt.Errorf("--no-hooks is not valid for %s", value.command)
	}
	if value.command == "lock" && len(value.operands) > 0 {
		return nil
	}
	if value.command == "adopt" && len(value.operands) == 1 {
		return nil
	}
	if value.command != "adopt" && value.command != "lock" && len(value.operands) == 0 {
		return nil
	}
	return fmt.Errorf("invalid operands for %s", value.command)
}

// Run executes the command and returns a conventional process exit status.
func Run(ctx context.Context, arguments []string, output io.Writer, errors io.Writer) int {
	if len(arguments) == 1 && (arguments[0] == "--version" || arguments[0] == "version") {
		fmt.Fprintf(output, "vaultlock %s\n", Version)
		return 0
	}
	if wantsHelp(arguments) {
		writeHelp(output, "auto")
		return 0
	}
	var parsed invocation
	var err error
	parsed, err = parse(arguments)
	if err != nil {
		writeError(errors, parsed.options.Color, err)
		fmt.Fprintln(errors)
		writeHelp(errors, parsed.options.Color)
		return 64
	}
	var config vault.Config
	config, err = vault.ConfigFromEnv()
	if err == nil {
		var app *vault.App = vault.New(config)
		app.Out, app.Err, app.Options = output, errors, parsed.options
		if (parsed.command == "lock" || parsed.command == "unlock") && !parsed.options.DryRun {
			app.Crypto, err = timelock.New()
		}
		if err == nil {
			err = app.Run(ctx, parsed.command, parsed.operands)
		}
	}
	if err != nil {
		writeError(errors, parsed.options.Color, err)
		return 1
	}
	return 0
}

func writeError(output io.Writer, colour string, err error) {
	var palette progress.Palette = progress.Palette{Enabled: vault.ColourEnabled(colour, output)}
	fmt.Fprintf(output, "%s %s\n", palette.Error("vaultlock:"), progress.SanitiseText(err.Error()))
}

func writeHelp(output io.Writer, colour string) {
	var palette progress.Palette = progress.Palette{Enabled: vault.ColourEnabled(colour, output)}
	var line string
	for _, line = range strings.SplitAfter(help, "\n") {
		var text string = strings.TrimSuffix(line, "\n")
		var suffix string = strings.TrimPrefix(line, text)
		if strings.HasPrefix(text, "Usage:") {
			text = palette.Heading("Usage:") + strings.TrimPrefix(text, "Usage:")
		} else if strings.HasSuffix(text, ":") {
			text = palette.Heading(text)
		} else if strings.HasPrefix(text, "  ") && !strings.HasPrefix(text, "                       ") {
			var split int = strings.Index(text[2:], "  ")
			if split >= 0 {
				text = "  " + palette.Accent(text[2:2+split]) + text[2+split:]
			}
		}
		fmt.Fprint(output, text+suffix)
	}
}

func wantsHelp(arguments []string) bool {
	if len(arguments) == 1 && (arguments[0] == "help" || arguments[0] == "--help" || arguments[0] == "-h") {
		return true
	}
	return len(arguments) == 2 && (arguments[1] == "--help" || arguments[1] == "-h") && strings.Contains(" init adopt lock unlock status privileged ", " "+arguments[0]+" ")
}
