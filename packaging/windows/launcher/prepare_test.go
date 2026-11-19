// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func pendingUpdate(t *testing.T) string {
	t.Helper()
	root := shipped(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	return root
}

func TestALauncherWithoutTheLockCountsNothingAndLeavesTheRunFolder(t *testing.T) {
	root := pendingUpdate(t)
	stubRelease(t, 0)
	dir, fallback, err := pick(root, false, false)
	if err != nil || dir != versionDir(root, "0.89.0") || fallback != dir {
		t.Fatalf("got %q, %q, %v", dir, fallback, err)
	}
	if read(root, "pending.tries") != "" || exists(runPath(root)) {
		t.Fatal("a launcher that lost the lock changed the install")
	}
}

func TestTheLockAdmitsOneLauncherAtATime(t *testing.T) {
	root := t.TempDir()
	unlock, ok := lockLaunchers(root, 0)
	if !ok {
		t.Fatal("the first launcher did not get the lock")
	}
	if _, ok := lockLaunchers(root, 300*time.Millisecond); ok {
		t.Fatal("a second launcher got the lock while the first held it")
	}
	unlock()
	again, ok := lockLaunchers(root, 0)
	if !ok {
		t.Fatal("the lock was not given back")
	}
	again()
}

func TestLaunchesAtTheSameTimeEachCountOnceAndLeaveOneWholeRunFolder(t *testing.T) {
	root := pendingUpdate(t)
	stubRelease(t, 0)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			unlock, ok := acquireLaunchLock(root, 5*time.Second)
			if !ok {
				t.Error("a launcher timed out on the lock")
				return
			}
			defer unlock()
			if _, _, err := pick(root, false, true); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if got := read(root, "pending.tries"); got != "2" {
		t.Fatalf("two launches counted %q starts", got)
	}
	if !mirrors(versionDir(root, "0.89.0"), runPath(root)) {
		t.Fatal("the run folder is not a whole copy of the current version")
	}
}

func TestAFailedStartFromTheRunFolderTriesTheVersionFolder(t *testing.T) {
	var tried []string
	startApp = func(exe, dir string, _ []string) (int, error) {
		tried = append(tried, dir)
		if filepath.Base(dir) == runFolder {
			return 0, errors.New("missing a DLL")
		}
		return 42, nil
	}
	t.Cleanup(func() { startApp = start })
	pid, err := startFrom("root/app", "root/app-0.89.0", nil)
	if err != nil || pid != 42 || len(tried) != 2 {
		t.Fatalf("pid %d, err %v, tried %v", pid, err, tried)
	}
}

// stubAlive reports pid alive for its first `alive` checks and every other pid dead.
func stubAlive(t *testing.T, pid, alive int) {
	t.Helper()
	processAlive = func(asked int) bool {
		if asked == pid && alive > 0 {
			alive--
			return true
		}
		return false
	}
	t.Cleanup(func() { processAlive = osProcessAlive })
}

func TestAHandOverWaitsForTheHandingCopyThenRelinks(t *testing.T) {
	root := pendingUpdate(t)
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 0)
	stubAlive(t, 4321, 3)
	args, pid := takeHandoff([]string{handoffArgument + "=4321", "slimm://invite?code=x"})
	if pid != 4321 || len(args) != 1 || args[0] != "slimm://invite?code=x" {
		t.Fatalf("got %v, %d", args, pid)
	}
	awaitHandoff(pid)
	dir, _, err := pick(root, false, true)
	if err != nil || dir != runPath(root) || *paused != 3 {
		t.Fatalf("started from %q after %d waits, %v", dir, *paused, err)
	}
	if engineIn(t, runPath(root)) != "engine 0.89.0" {
		t.Fatal("the run folder was not relinked to current")
	}
}

func TestAHandOverBesideARunningOlderCopyDoesNotWaitForIt(t *testing.T) {
	root := pendingUpdate(t)
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 1000)
	stubAlive(t, 4321, 0)
	_, pid := takeHandoff([]string{handoffArgument + "=4321"})
	awaitHandoff(pid)
	dir, _, err := pick(root, false, true)
	if err != nil || dir != versionDir(root, "0.89.0") || *paused != 0 {
		t.Fatalf("started from %q after %d waits, %v", dir, *paused, err)
	}
}

func TestALauncherWithoutTheLockStartsPreviousWhileCurrentIsIncomplete(t *testing.T) {
	root := pendingUpdate(t)
	if err := os.Remove(filepath.Join(versionDir(root, "0.89.0"), appExecutable)); err != nil {
		t.Fatal(err)
	}
	dir, _, err := pick(root, false, false)
	if err != nil || dir != versionDir(root, "0.88.0") {
		t.Fatalf("got %q, %v", dir, err)
	}
	if read(root, "current") != "0.89.0" {
		t.Fatal("a launcher without the lock moved the pointer")
	}
}

func TestAReadOnlyLockFileIsStillTaken(t *testing.T) {
	root := t.TempDir()
	put(t, root, lockFile, "")
	if err := os.Chmod(filepath.Join(root, lockFile), 0o444); err != nil {
		t.Fatal(err)
	}
	unlock, ok := lockLaunchers(root, 0)
	if !ok {
		t.Fatal("a read-only lock file stopped every launcher from taking the lock")
	}
	unlock()
}

func TestOnlyTheLockHolderReplacesTheLauncher(t *testing.T) {
	root, self := installed(t, newLauncher)
	swapIfHolding(passing(), root, false)
	if contents(t, self) != oldLauncher {
		t.Fatal("a launcher without the lock replaced the root launcher")
	}
	swapIfHolding(passing(), root, true)
	if contents(t, self) != newLauncher {
		t.Fatal("the lock holder did not replace the root launcher")
	}
}
