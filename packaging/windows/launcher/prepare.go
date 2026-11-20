// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"path/filepath"
	"strconv"
	"strings"
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
	// handoffArgument=<pid> comes from a copy in the run folder that handed its start over and is exiting.
	handoffArgument = "--from-run-folder"
)

// takeHandoff removes the hand-over argument from args, which the app never
// sees, and returns the pid of the copy that handed over, or 0.
func takeHandoff(args []string) ([]string, int) {
	kept := make([]string, 0, len(args))
	pid := 0
	for _, arg := range args {
		if value, ok := strings.CutPrefix(arg, handoffArgument+"="); ok {
			pid, _ = strconv.Atoi(value)
			continue
		}
		kept = append(kept, arg)
	}
	return kept, pid
}

// awaitHandoff waits, as long as a restart would, for the copy that handed this
// start over to exit, and for nothing else: another copy may run for hours.
func awaitHandoff(pid int) {
	for i := 0; pid > 0 && i < releaseTries && processAlive(pid); i++ {
		pause(releasePoll)
	}
}

// swapIfHolding replaces the root launcher only for the launcher holding the lock.
func swapIfHolding(s swapper, root string, locked bool) {
	if locked && settled(root) {
		_ = s.swapLauncher(root, filepath.Join(root, launcherName))
	}
}

// acquireLaunchLock and startApp are replaced in tests.
var (
	acquireLaunchLock = lockLaunchers
	startApp          = start
)

// pick returns the folder to start and the version folder to fall back to.
// Without the launcher lock it writes nothing: no start is counted, the run
// folder is left alone, and a current version that is not whole yet gives way
// to the previous one.
func pick(root string, relaunch, locked bool) (dir, fallback string, err error) {
	if !locked {
		for _, pointer := range []string{currentFile, previousFile} {
			if version := read(root, pointer); isComplete(root, version) {
				dir = versionDir(root, version)
				return dir, dir, nil
			}
		}
		return "", "", errors.New("slim-m is being updated; start it again in a moment")
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
