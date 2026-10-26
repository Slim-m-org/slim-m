// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

// The launcher stays dumb on purpose (docs/decisions/0041): read the `current`
// pointer, start that version's folder, and count starts so a version that
// never comes up cleanly is replaced by `previous`. The file names are shared
// with client/packages/app/lib/src/desktop/self_update/windows_layout.dart.
package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	appExecutable   = "slimm_app.exe"
	versionPrefix   = "app-"
	maxFailedStarts = 2
	pendingTries    = "pending.tries"
	currentFile     = "current"
	pendingFile     = "pending"
	previousFile    = "previous"
)

func read(root, name string) string {
	data, err := os.ReadFile(filepath.Join(root, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// write goes through a temp file and a replacing rename, so a reader sees the
// old content or the new, never a partial file.
func write(root, name, content string) error {
	temp := filepath.Join(root, "."+name+".launcher")
	if err := os.WriteFile(temp, []byte(content), 0o644); err != nil {
		return err
	}
	return os.Rename(temp, filepath.Join(root, name))
}

func remove(root string, names ...string) {
	for _, name := range names {
		_ = os.Remove(filepath.Join(root, name))
	}
}

func versionDir(root, version string) string {
	return filepath.Join(root, versionPrefix+version)
}

func isComplete(root, version string) bool {
	if version == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(versionDir(root, version), appExecutable))
	return err == nil
}

// relaunchArgument is what the app passes when it restarts itself; the same
// text lives in single_instance.h and relaunch.dart.
const relaunchArgument = "--relaunch"

func isRelaunch(args []string) bool {
	for _, arg := range args {
		if arg == relaunchArgument {
			return true
		}
	}
	return false
}

// shouldRecordPid keeps a second launch from hiding the first instance, but a
// relaunch replaces it: its predecessor is only still alive because it is exiting.
func shouldRecordPid(running, relaunch bool) bool {
	return !running || relaunch
}

// choose returns the version folder to start, after applying the start count
// and any rollback it calls for.
func choose(root string, relaunch bool) (string, error) {
	current := read(root, currentFile)
	if current == "" {
		return "", errors.New("slim-m has no current version")
	}
	if !isComplete(root, current) {
		return rollBack(root, current)
	}
	if read(root, pendingFile) != current {
		return versionDir(root, current), nil
	}
	// A start beside an instance that is still up proves nothing about this version,
	// unless that instance is the one handing over to it.
	if !relaunch && instanceRunning(root) {
		return versionDir(root, current), nil
	}
	tries, _ := strconv.Atoi(read(root, pendingTries))
	if tries >= maxFailedStarts && isComplete(root, read(root, previousFile)) {
		return rollBack(root, current)
	}
	if err := write(root, pendingTries, strconv.Itoa(tries+1)); err != nil {
		return "", err
	}
	return versionDir(root, current), nil
}

// rollBack makes `previous` current again and leaves a `rolled-back` marker
// for the app to report once it is up.
func rollBack(root, failed string) (string, error) {
	previous := read(root, previousFile)
	if !isComplete(root, previous) {
		return "", errors.New("slim-m version " + failed + " cannot start and there is no earlier version to go back to")
	}
	if err := write(root, currentFile, previous); err != nil {
		return "", err
	}
	_ = write(root, "rolled-back", failed)
	remove(root, pendingFile, pendingTries, previousFile)
	return versionDir(root, previous), nil
}

// processAlive is replaced in tests; the real one asks the OS.
var processAlive = osProcessAlive

// instanceRunning reports whether the app this launcher started last is
// still alive, going by the pid it left in running.pid.
func instanceRunning(root string) bool {
	pid, err := strconv.Atoi(read(root, "running.pid"))
	return err == nil && pid > 0 && processAlive(pid)
}
