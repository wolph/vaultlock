package vault

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"github.com/wolph/vaultlock/internal/progress"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
)

type Config struct{ Home, StateDir, Volume, Container, MountPoint, User, ConfirmDevice string }
type Options struct {
	DryRun, Yes, Hooks bool
	Verbosity          int
	Color, Progress    string
}
type Runner interface {
	Run(context.Context, string, []string, []byte) ([]byte, error)
}
type Crypto interface {
	Encrypt(context.Context, []byte, uint64) ([]byte, error)
	Decrypt(context.Context, []byte) ([]byte, error)
	VerifyFuture(context.Context, []byte, uint64) error
}
type App struct {
	Config                Config
	Runner                Runner
	Crypto                Crypto
	Out, Err              io.Writer
	Confirm               io.Reader
	Now                   func() time.Time
	Options               Options
	HelperProbe           func(uuid string) bool
	hookPlans             map[string]hookPlan
	display               *progress.Display
	progressInterval      time.Duration
	outputTerminal        bool
	errorTerminal         bool
	sealing               bool
	storageChangesStarted bool
}

func ConfigFromEnv() (Config, error) {
	var home string
	var err error

	home, err = os.UserHomeDir()
	if err != nil {
		return Config{}, err
	}
	var username string = os.Getenv("USER")
	if username == "" {
		var u *user.User
		var e error

		u, e = user.Current()
		if e != nil {
			return Config{}, e
		}
		username = u.Username
	}
	var env func(name string,
		fallback string) string = func(name, fallback string) string {
		if value := os.Getenv(name); value != "" {
			return value
		}
		return fallback
	}
	var volume string = env("VAULTLOCK_VOLUME", "vault")
	var c Config = Config{home, env("VAULTLOCK_STATE_DIR", filepath.Join(home, ".vaultlock")), volume, env("VAULTLOCK_CONTAINER", "disk3"), env("VAULTLOCK_MOUNT_POINT", filepath.Join("/Volumes", volume)), username, env("VAULTLOCK_CONFIRM_DEVICE", "/dev/tty")}
	return c, c.validate()
}

var publicToken *regexp.Regexp = regexp.MustCompile(`^[A-Za-z0-9._@+-]+$`)

func (c Config) validate() error {
	for _, value := range []string{c.Home, c.StateDir, c.MountPoint, c.ConfirmDevice} {
		if !filepath.IsAbs(value) || strings.IndexFunc(value, unicode.IsControl) >= 0 {
			return errors.New("configuration paths must be absolute and contain no control characters")
		}
	}
	for _, value := range []string{c.Volume, c.Container, c.User} {
		if value == "" || value == "." || value == ".." || !publicToken.MatchString(value) {
			return errors.New("configuration contains an unsafe name")
		}
	}
	return nil
}
func New(c Config) *App {
	return &App{Config: c, Runner: systemRunner{}, Out: os.Stdout, Err: os.Stderr, Now: time.Now, Options: Options{Hooks: true, Color: "auto", Progress: "auto"}}
}
func (a *App) Report(format string, args ...any) { a.reportText(format, args...) }
func (a *App) Run(ctx context.Context, command string, operands []string) (runErr error) {
	if err := a.Config.validate(); err != nil {
		return err
	}
	if a.Runner == nil {
		return errors.New("system runner is unavailable")
	}
	if a.Now == nil {
		a.Now = time.Now
	}
	if a.Out == nil {
		a.Out = io.Discard
	}
	if a.Err == nil {
		a.Err = io.Discard
	}
	var finishProgress func(error) error = a.startProgress(command)
	defer func() { runErr = finishProgress(runErr) }()
	a.hookPlans = nil
	if command == "status" {
		if len(operands) != 0 {
			return errors.New("status accepts no operands")
		}
		return a.status(ctx)
	}
	if command == "privileged" {
		if len(operands) != 1 || operands[0] != "allow" {
			return errors.New("privileged accepts only the allow operand")
		}
		return a.allowHelper(ctx)
	}
	switch command {
	case "init", "unlock":
		if len(operands) != 0 {
			return fmt.Errorf("%s accepts no operands", command)
		}
	case "lock":
		if len(operands) == 0 {
			return errors.New("lock requires a deadline")
		}
	case "adopt":
		if len(operands) != 1 {
			return errors.New("adopt requires one directory")
		}
	default:
		return fmt.Errorf("unknown command: %s", command)
	}
	if !a.Options.DryRun {
		var release func()
		var err error

		release, err = a.acquire()
		if err != nil {
			return err
		}
		defer release()
	}
	switch command {
	case "init":
		return a.init(ctx)
	case "adopt":
		return a.adopt(ctx, operands[0])
	case "lock":
		return a.lock(ctx, strings.Join(operands, " "))
	case "unlock":
		return a.unlock(ctx)
	}
	return nil
}
func (a *App) confirm(message string) error {
	if a.Options.Yes {
		return nil
	}
	var resume func() = func() {}
	if a.display != nil {
		fmt.Fprintln(a.Err, a.diagnosticPalette().Warning("Waiting for your confirmation"))
		resume = a.display.Pause()
	}
	defer resume()
	defer func() { fmt.Fprintln(a.Err) }()
	fmt.Fprint(a.Err, a.diagnosticPalette().Heading(progress.SanitiseText(message))+" "+a.diagnosticPalette().Warning("[y/N]")+" ")
	var reader io.Reader = a.Confirm
	if reader == nil {
		var f *os.File
		var err error

		f, err = os.Open(a.Config.ConfirmDevice)
		if err != nil {
			return errors.New("confirmation unavailable, use --yes after reviewing --dry-run")
		}
		defer f.Close()
		reader = f
	}
	var scanner *bufio.Scanner = bufio.NewScanner(reader)
	if !scanner.Scan() {
		return errors.New("cancelled, no changes made")
	}
	var response string = strings.ToLower(scanner.Text())
	if response != "y" && response != "yes" {
		return errors.New("cancelled, no changes made")
	}
	return nil
}
