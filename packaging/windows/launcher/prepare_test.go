// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
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
	dir, fallback, err := pick(root, false, false, false)
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
			if _, _, err := pick(root, false, false, true); err != nil {
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

func TestAHandedOverStartWaitsForTheCopyThatHandedItOver(t *testing.T) {
	root := pendingUpdate(t)
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 3)
	args, handoff := takeHandoff([]string{handoffArgument, "slimm://invite?code=x"})
	if !handoff || len(args) != 1 || args[0] != "slimm://invite?code=x" {
		t.Fatalf("got %v, %v", args, handoff)
	}
	dir, _, err := pick(root, false, handoff, true)
	if err != nil || dir != runPath(root) || *paused != 3 {
		t.Fatalf("started from %q after %d waits, %v", dir, *paused, err)
	}
	if engineIn(t, runPath(root)) != "engine 0.89.0" {
		t.Fatal("the run folder was not relinked to current")
	}
}
