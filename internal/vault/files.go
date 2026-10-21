package vault

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/wolph/vaultlock/internal/progress"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"unicode"
)

type State struct {
	Locked        bool                       `json:"locked"`
	VolumeUUID    string                     `json:"volume_uuid"`
	Deadline      *string                    `json:"deadline"`
	DeadlineEpoch *int64                     `json:"deadline_epoch"`
	Round         *uint64                    `json:"round"`
	Extra         map[string]json.RawMessage `json:"-"`
}

func (s *State) UnmarshalJSON(data []byte) error {
	type plain State
	var base plain
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return errors.New("state JSON is malformed")
	}
	if fields == nil {
		return errors.New("state must be an object")
	}
	if string(fields["locked"]) != "true" && string(fields["locked"]) != "false" {
		return errors.New("state locked field is missing or malformed")
	}
	for _, key := range []string{"deadline_epoch", "round"} {
		var value json.RawMessage
		var err error

		value, err = normaliseStateInteger(fields[key])
		if err != nil {
			return err
		}
		if len(value) > 0 {
			fields[key] = value
		}
	}
	var normalised []byte
	var err error
	normalised, err = json.Marshal(fields)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(normalised, &base); err != nil {
		return errors.New("state fields are malformed")
	}
	*s = State(base)
	for _, key := range []string{"locked", "volume_uuid", "deadline", "deadline_epoch", "round"} {
		delete(fields, key)
	}
	s.Extra = fields
	return s.validate()
}
func (s State) MarshalJSON() ([]byte, error) {
	var fields map[string]any = make(map[string]any, len(s.Extra)+5)
	for k, v := range s.Extra {
		fields[k] = v
	}
	fields["locked"] = s.Locked
	fields["volume_uuid"] = s.VolumeUUID
	fields["deadline"] = s.Deadline
	fields["deadline_epoch"] = s.DeadlineEpoch
	fields["round"] = s.Round
	return json.Marshal(fields)
}
func (s State) validate() error {
	if s.VolumeUUID == "" || strings.IndexFunc(s.VolumeUUID, unicode.IsControl) >= 0 {
		return errors.New("state volume UUID is missing or malformed")
	}
	if s.Deadline != nil && (*s.Deadline == "" || strings.IndexFunc(*s.Deadline, unicode.IsControl) >= 0) {
		return errors.New("state deadline is malformed")
	}
	if s.DeadlineEpoch != nil && (*s.DeadlineEpoch < 0 || *s.DeadlineEpoch > 999999999999999999) {
		return errors.New("state deadline epoch is malformed")
	}
	if s.Round != nil && (*s.Round == 0 || *s.Round > 999999999999999999) {
		return errors.New("state round is malformed")
	}
	if s.Locked && (s.Deadline == nil || s.DeadlineEpoch == nil || s.Round == nil) {
		return errors.New("locked state has no recovery deadline")
	}
	return nil
}
func (a *App) path(name string) string { return filepath.Join(a.Config.StateDir, name) }
func privateInfo(path string, directory bool) (os.FileInfo, error) {
	var info os.FileInfo
	var err error

	info, err = os.Lstat(path)
	if err != nil {
		return nil, err
	}
	var stat *syscall.Stat_t
	var ok bool

	stat, ok = info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("unsafe owner or type at %s", path)
	}
	var want os.FileMode = os.FileMode(0600)
	if directory {
		want = 0700
		if !info.IsDir() {
			return nil, fmt.Errorf("not a directory: %s", path)
		}
	} else if !info.Mode().IsRegular() || stat.Nlink != 1 {
		return nil, fmt.Errorf("unsafe protected file: %s", path)
	}
	if info.Mode().Perm() != want || info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
		return nil, fmt.Errorf("unsafe permissions at %s, expected %04o", path, want)
	}
	if err := checkACL(path); err != nil {
		return nil, err
	}
	return info, nil
}
func (a *App) checkDir() error {
	var err error

	_, err = privateInfo(a.Config.StateDir, true)
	return err
}
func (a *App) read(name string) ([]byte, error) {
	var task *progress.Task = a.beginProgress("Read and validate protected recovery files", 0, 1)
	defer task.Close()
	if err := a.checkDir(); err != nil {
		return nil, err
	}
	var path string = a.path(name)
	var before os.FileInfo
	var err error

	before, err = privateInfo(path, false)
	if err != nil {
		return nil, err
	}
	var fd int

	fd, err = syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	var file *os.File = os.NewFile(uintptr(fd), path)
	defer file.Close()
	var opened os.FileInfo

	opened, err = file.Stat()
	if err != nil || !os.SameFile(before, opened) {
		return nil, errors.New("protected file identity changed")
	}
	task.SetTotal(opened.Size(), 1)
	var data []byte

	data, err = io.ReadAll(io.LimitReader(file, 16*1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 16*1024*1024 {
		return nil, errors.New("protected file is too large")
	}
	var after os.FileInfo

	after, err = privateInfo(path, false)
	if err != nil || !os.SameFile(before, after) {
		return nil, errors.New("protected file identity changed")
	}
	task.Add(int64(len(data)), 1, "")
	task.Complete()
	return data, nil
}
func (a *App) ReadState() (State, error) {
	defer a.wait("Read and parse protected vault state")()
	var state State
	var data []byte
	var err error

	data, err = a.read("state.json")
	if err != nil {
		return state, err
	}
	err = json.Unmarshal(data, &state)
	return state, err
}
func (a *App) write(name string, data []byte) error {
	var task *progress.Task = a.beginProgress("Durably write and verify protected recovery files", int64(len(data)), 1)
	defer task.Close()
	if err := a.beforeMutation(); err != nil {
		return err
	}
	if err := a.checkDir(); err != nil {
		return err
	}
	var destination string = a.path(name)
	var before os.FileInfo
	var err error

	before, err = privateInfo(destination, false)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var stage *os.File

	stage, err = os.CreateTemp(a.Config.StateDir, ".stage-")
	if err != nil {
		return err
	}
	var stageName string = stage.Name()
	defer os.Remove(stageName)
	if _, err = stage.Write(data); err == nil {
		err = stage.Sync()
	}
	if closeErr := stage.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = a.checkDir(); err != nil {
		return err
	}
	var current os.FileInfo
	var e error

	current, e = privateInfo(destination, false)
	if before == nil {
		if !os.IsNotExist(e) {
			return errors.New("protected destination appeared during write")
		}
	} else if e != nil || !os.SameFile(before, current) {
		return errors.New("protected destination identity changed")
	}
	if err = os.Rename(stageName, destination); err != nil {
		return err
	}
	if err = syncDirectory(a.Config.StateDir); err != nil {
		return err
	}
	var installed []byte

	installed, err = a.read(name)
	if err != nil {
		return err
	}
	if string(installed) != string(data) {
		return errors.New("protected write verification failed")
	}
	task.Add(int64(len(data)), 1, "")
	task.Complete()
	return nil
}
func syncDirectory(path string) error {
	var file *os.File
	var err error

	file, err = os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}
func (a *App) writeState(s State) error {
	if err := s.validate(); err != nil {
		return err
	}
	var data []byte
	var err error

	data, err = json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return a.write("state.json", append(data, '\n'))
}
func digest(data []byte) string {
	var sum [32]byte = sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
func normaliseSecret(data []byte) ([]byte, error) {
	data = []byte(strings.TrimRight(string(data), "\n"))
	if len(data) == 0 || !regexp.MustCompile(`^[A-Za-z0-9+/]+={0,2}$`).Match(data) {
		return nil, errors.New("recovery material is empty or malformed")
	}
	return data, nil
}
func (a *App) verifyPass(pass []byte) error {
	var hash []byte
	var err error

	hash, err = a.read("passphrase.sha256")
	if err != nil {
		return errors.New("recovery hash is missing or unsafe")
	}
	var wanted string = strings.TrimSuffix(string(hash), "\n")
	if len(wanted) != 64 || wanted != digest(pass) {
		return errors.New("recovery material fails sha256 verification")
	}
	return nil
}
func (a *App) remove(name string) error {
	defer a.wait("Remove verified plaintext recovery files")()
	if err := a.beforeMutation(); err != nil {
		return err
	}
	if _, err := privateInfo(a.path(name), false); err != nil {
		return err
	}
	if err := os.Remove(a.path(name)); err != nil {
		return err
	}
	return syncDirectory(a.Config.StateDir)
}
func (a *App) acquire() (func(), error) {
	defer a.wait("Acquire the cooperative vault operation lock")()
	if err := a.checkProgress(); err != nil {
		return nil, err
	}
	var path string = filepath.Join(a.Config.Home, ".vaultlock-operation.lock")
	var fd int
	var err error

	fd, err = syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, errors.New("operation lock is unavailable, a legacy or concurrent operation may own it")
	}
	var file *os.File = os.NewFile(uintptr(fd), path)
	var fail func(err error) (func(), error) = func(err error) (func(), error) { file.Close(); return nil, err }
	var info os.FileInfo

	info, err = privateInfo(path, false)
	if err != nil {
		return fail(err)
	}
	var opened os.FileInfo

	opened, err = file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return fail(errors.New("operation lock identity changed"))
	}
	if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fail(errors.New("another vaultlock operation is running"))
	}
	info, err = privateInfo(path, false)
	if err != nil || !os.SameFile(info, opened) {
		return fail(errors.New("operation lock pathname changed during acquisition"))
	}
	return func() { syscall.Flock(fd, syscall.LOCK_UN); file.Close() }, nil
}

func (a *App) writeNew(name string, data []byte) error {
	var task *progress.Task = a.beginProgress("Create and verify protected recovery material", int64(len(data)), 1)
	defer task.Close()
	if err := a.beforeMutation(); err != nil {
		return err
	}
	if err := a.checkDir(); err != nil {
		return err
	}
	var file *os.File
	var err error

	file, err = os.OpenFile(a.path(name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = syncDirectory(a.Config.StateDir); err != nil {
		return err
	}
	var installed []byte

	installed, err = a.read(name)
	if err != nil || string(installed) != string(data) {
		return errors.New("new recovery file verification failed")
	}
	task.Add(int64(len(data)), 1, "")
	task.Complete()
	return nil
}

type protectedEntry struct {
	info os.FileInfo
	hash string
}
type protectedSnapshot struct {
	directory os.FileInfo
	entries   map[string]protectedEntry
}

func (a *App) captureFiles(names ...string) (protectedSnapshot, error) {
	defer a.wait("Inspect protected recovery file identities")()
	var snapshot protectedSnapshot
	var err error
	snapshot.directory, err = privateInfo(a.Config.StateDir, true)
	if err != nil {
		return snapshot, err
	}
	snapshot.entries = make(map[string]protectedEntry)
	for _, name := range names {
		var before os.FileInfo
		var err error

		before, err = privateInfo(a.path(name), false)
		if os.IsNotExist(err) {
			snapshot.entries[name] = protectedEntry{}
			continue
		}
		if err != nil {
			return snapshot, err
		}
		var data []byte

		data, err = a.read(name)
		if err != nil {
			return snapshot, err
		}
		var after os.FileInfo

		after, err = privateInfo(a.path(name), false)
		if err != nil || !sameProtectedInfo(before, after) {
			return snapshot, errors.New("protected recovery identity changed during inspection")
		}
		snapshot.entries[name] = protectedEntry{info: after, hash: digest(data)}
	}
	return snapshot, nil
}
func sameProtectedInfo(before, after os.FileInfo) bool {
	return before != nil && after != nil && os.SameFile(before, after) && before.Mode() == after.Mode() && before.Size() == after.Size() && before.ModTime().Equal(after.ModTime())
}
func (a *App) verifyFiles(snapshot protectedSnapshot) error {
	defer a.wait("Verify protected recovery file identities and contents")()
	var directory os.FileInfo
	var err error

	directory, err = privateInfo(a.Config.StateDir, true)
	if err != nil || !os.SameFile(snapshot.directory, directory) || snapshot.directory.Mode() != directory.Mode() {
		return errors.New("protected state directory changed")
	}
	for name, wanted := range snapshot.entries {
		var current os.FileInfo
		var err error

		current, err = privateInfo(a.path(name), false)
		if wanted.info == nil {
			if !os.IsNotExist(err) {
				return errors.New("protected recovery destination appeared")
			}
			continue
		}
		if err != nil || !sameProtectedInfo(wanted.info, current) {
			return errors.New("protected recovery file identity changed")
		}
		var data []byte

		data, err = a.read(name)
		if err != nil || digest(data) != wanted.hash {
			return errors.New("protected recovery content changed")
		}
	}
	return nil
}

func normaliseStateInteger(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return raw, nil
	}
	if len(raw) > 128 || raw[0] == '"' {
		return nil, errors.New("state number is malformed")
	}
	var text string = string(raw)
	var exponentIndex int = strings.IndexAny(text, "eE")
	if exponentIndex >= 0 {
		var exponent int64
		var err error
		exponent, err = strconv.ParseInt(text[exponentIndex+1:], 10, 32)
		if err != nil || exponent > 128 || exponent < -128 {
			return nil, errors.New("state number exponent is unsupported")
		}
	}
	var number *big.Rat
	var valid bool
	number, valid = new(big.Rat).SetString(text)
	if !valid || !number.IsInt() || number.Sign() < 0 || !number.Num().IsInt64() || number.Num().Int64() > 999999999999999999 {
		return nil, errors.New("state number is fractional or out of range")
	}
	return json.RawMessage(number.Num().String()), nil
}
