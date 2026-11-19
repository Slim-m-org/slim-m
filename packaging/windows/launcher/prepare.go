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
	// handoffArgument comes from a copy in the run folder that handed its start over and is still exiting.
	handoffArgument = "--from-run-folder"
)

// takeHandoff removes handoffArgument from args, which the app never sees, and says whether it was there.
func takeHandoff(args []string) ([]string, bool) {
	kept := make([]string, 0, len(args))
	found := false
	for _, arg := range args {
		if arg == handoffArgument {
			found = true
			continue
		}
		kept = append(kept, arg)
	}
	return kept, found
}

// acquireLaunchLock and startApp are replaced in tests.
var (
	acquireLaunchLock = lockLaunchers
	startApp          = start
)

// pick returns the folder to start and the version folder to fall back to;
// wait lets a copy that is exiting from the run folder finish first. Without
// the launcher lock it changes nothing: no start is counted and the run folder
// is left to the launcher that holds the lock.
func pick(root string, relaunch, wait, locked bool) (dir, fallback string, err error) {
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
	return runFrom(root, fallback, wait), fallback, nil
}

// startFrom starts the app in dir, and once more from fallback if that fails.
func startFrom(dir, fallback string, args []string) (int, error) {
	pid, err := startApp(filepath.Join(dir, appExecutable), dir, args)
	if err != nil && dir != fallback {
		return startApp(filepath.Join(fallback, appExecutable), fallback, args)
	}
	return pid, err
}
