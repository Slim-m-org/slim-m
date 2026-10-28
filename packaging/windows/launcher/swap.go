// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	launcherName = "slim-m.exe"
	// selftestFlag exits 0 at once, proving a replacement runs on this machine.
	selftestFlag = "--launcher-selftest"
	// selftestMarker marks launchers that know the flag; one without it would start the app.
	selftestMarker = "slimm-launcher-selftest/1"
	selftestWait   = 10 * time.Second
)

// swapper holds the two steps a test replaces to interrupt or fail a swap.
type swapper struct {
	rename func(from, to string) error
	probe  func(path string) error
}

func realSwapper() swapper {
	return swapper{rename: os.Rename, probe: runSelftest}
}

func runSelftest(path string) error {
	cmd := exec.Command(path, selftestFlag)
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(selftestWait):
		_ = cmd.Process.Kill()
		return errors.New("the replacement launcher did not exit")
	}
}

func digest(path string) ([32]byte, error) {
	var sum [32]byte
	file, err := os.Open(path)
	if err != nil {
		return sum, err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return sum, err
	}
	copy(sum[:], hash.Sum(nil))
	return sum, nil
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}

// settled is true once the app has cleared `pending`; a launcher is only swapped after that.
func settled(root string) bool {
	return read(root, currentFile) != "" && read(root, pendingFile) == ""
}

// swapLauncher replaces the launcher at self with the one in the current version
// folder. A running exe can be renamed but not overwritten, so it steps aside to .old first.
func (s swapper) swapLauncher(root, self string) error {
	if !strings.EqualFold(filepath.Base(self), launcherName) {
		return nil
	}
	old := self + ".old"
	_ = os.Remove(old)
	candidate := filepath.Join(versionDir(root, read(root, currentFile)), launcherName)
	want, err := digest(candidate)
	if err != nil {
		return nil
	}
	if have, err := digest(self); err != nil || have == want {
		return err
	}
	data, err := os.ReadFile(candidate)
	if err != nil || !bytes.Contains(data, []byte(selftestMarker)) {
		return err
	}
	stage := filepath.Join(root, "slim-m.new.exe")
	defer os.Remove(stage)
	if err := copyFile(candidate, stage); err != nil {
		return err
	}
	if got, err := digest(stage); err != nil || got != want {
		return errors.New("the staged launcher does not match its source")
	}
	if err := s.probe(stage); err != nil {
		return err
	}
	if err := s.rename(self, old); err != nil {
		return err
	}
	if err := s.rename(stage, self); err != nil {
		_ = s.rename(old, self)
		return err
	}
	return nil
}
