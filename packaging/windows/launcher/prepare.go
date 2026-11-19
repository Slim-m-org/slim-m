// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"path/filepath"
	"time"
)

const (
	// lockFile serialises launchers: two at once would both count a start and rebuild the run folder.
	lockFile = ".launcher.lock"
	// lockWait outlasts one launcher's whole wait for a relaunched copy to exit.
	lockWait = releaseTries*releasePoll + 15*time.Second
	lockPoll = 100 * time.Millisecond
	// launcherEnv tells the runner it was started by the launcher (link_handoff.h has the same name).
	launcherEnv = "SLIMM_FROM_LAUNCHER"
)

// acquireLaunchLock and startApp are replaced in tests.
var (
	acquireLaunchLock = lockLaunchers
	startApp          = start
)

// pick returns the folder to start and the version folder to fall back to.
// Without the launcher lock it changes nothing: no start is counted and the run
// folder is left to the launcher that holds the lock.
func pick(root string, relaunch, locked bool) (dir, fallback string, err error) {
	if !locked {
		current := read(root, currentFile)
		if !isComplete(root, current) {
			return "", "", errors.New("slim-m is being updated; start it again in a moment")
		}
		dir = versionDir(root, current)
		return dir, dir, nil
	}
	fallback, err = choose(root, relaunch)
	if err != nil {
		return "", "", err
	}
	return runFrom(root, fallback, relaunch), fallback, nil
}

// startFrom starts the app in dir, and once more from fallback if that fails.
func startFrom(dir, fallback string, args []string) (int, error) {
	pid, err := startApp(filepath.Join(dir, appExecutable), dir, args)
	if err != nil && dir != fallback {
		return startApp(filepath.Join(fallback, appExecutable), fallback, args)
	}
	return pid, err
}
