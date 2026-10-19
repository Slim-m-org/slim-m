// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == selftestFlag {
		fmt.Print(selftestMarker)
		return
	}
	self, err := os.Executable()
	if err != nil {
		fail(err.Error())
	}
	root := locate(self)
	restoreLauncher(root, self)
	running := instanceRunning(root)
	relaunch := isRelaunch(os.Args[1:])
	dir, err := choose(root, relaunch)
	if err != nil {
		fail(err.Error())
	}
	if settled(root) {
		_ = realSwapper().swapLauncher(root, filepath.Join(root, launcherName))
	}
	pid, err := start(filepath.Join(dir, appExecutable), dir, os.Args[1:])
	if err != nil {
		fail(err.Error())
	}
	// Only the first instance is recorded: a second one exits at once and must not hide it.
	if shouldRecordPid(running, relaunch) {
		_ = write(root, "running.pid", strconv.Itoa(pid))
	}
}
