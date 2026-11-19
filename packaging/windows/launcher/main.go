// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"fmt"
	"os"
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
	args, handingPid := takeHandoff(os.Args[1:])
	awaitHandoff(handingPid)
	unlock, locked := acquireLaunchLock(root, lockWait)
	if locked {
		defer unlock()
	}
	running := instanceRunning(root)
	relaunch := isRelaunch(args)
	dir, fallback, err := pick(root, relaunch, locked)
	if err != nil {
		fail(err.Error())
	}
	swapIfHolding(realSwapper(), root, locked)
	pid, err := startFrom(dir, fallback, args)
	if err != nil {
		fail(err.Error())
	}
	// Only the first instance is recorded: a second one exits at once and must not hide it.
	if locked && shouldRecordPid(running, relaunch) {
		_ = write(root, "running.pid", strconv.Itoa(pid))
	}
}
