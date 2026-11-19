// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var errInUse = errors.New("the file is in use")

func shipped(t *testing.T, versions ...string) string {
	t.Helper()
	root := layout(t, versions...)
	for _, v := range versions {
		dir := versionDir(root, v)
		put(t, dir, launcherName, "launcher "+v)
		if err := os.MkdirAll(filepath.Join(dir, "data"), 0o755); err != nil {
			t.Fatal(err)
		}
		put(t, filepath.Join(dir, "data"), "app.so", "engine "+v)
	}
	return root
}

// stubRelease makes the run folder's executable refuse deletion `busy` times, as a running copy does.
func stubRelease(t *testing.T, busy int) *int {
	t.Helper()
	paused := 0
	removeFile = func(path string) error {
		if busy > 0 {
			busy--
			return errInUse
		}
		return os.Remove(path)
	}
	pause = func(time.Duration) { paused++ }
	t.Cleanup(func() { removeFile, pause = os.Remove, time.Sleep })
	return &paused
}

func sameFile(t *testing.T, a, b string) bool {
	t.Helper()
	x, errA := os.Stat(a)
	y, errB := os.Stat(b)
	return errA == nil && errB == nil && os.SameFile(x, y)
}

func runPath(root string) string { return filepath.Join(root, runFolder) }

func TestTheFirstStartLinksTheVersionIntoTheRunFolder(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != runPath(root) {
		t.Fatalf("started from %q", got)
	}
	for _, rel := range []string{appExecutable, filepath.Join("data", "app.so")} {
		if !sameFile(t, filepath.Join(versionDir(root, "0.88.0"), rel), filepath.Join(runPath(root), rel)) {
			t.Fatalf("%s is not a link to the version's file", rel)
		}
	}
	if exists(filepath.Join(runPath(root), launcherName)) {
		t.Fatal("the launcher only works from the root and must not be linked")
	}
}

func TestARunFolderThatMatchesIsUsedEvenWhileTheAppRuns(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	stubRelease(t, 1000)
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != runPath(root) {
		t.Fatalf("a second launch must reach the running copy's folder, got %q", got)
	}
}

func TestANewVersionReplacesTheRunFolderAndKeepsTheOldVersionFolder(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	if got := runFrom(root, versionDir(root, "0.89.0"), true); got != runPath(root) {
		t.Fatalf("started from %q", got)
	}
	if contents(t, filepath.Join(runPath(root), "data", "app.so")) != "engine 0.89.0" {
		t.Fatal("the run folder still holds the old version")
	}
	if contents(t, filepath.Join(versionDir(root, "0.88.0"), "data", "app.so")) != "engine 0.88.0" {
		t.Fatal("replacing the run folder touched the previous version, which rollback needs")
	}
	for _, leftover := range []string{runPath(root) + ".next", runPath(root) + ".old"} {
		if exists(leftover) {
			t.Fatalf("%s was left behind", leftover)
		}
	}
}

func TestASecondLaunchBesideARunningOldVersionStartsTheVersionFolder(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 1000)
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != versionDir(root, "0.89.0") {
		t.Fatalf("got %q", got)
	}
	if *paused != 0 {
		t.Fatal("only a relaunch waits for the running copy")
	}
	if contents(t, filepath.Join(runPath(root), "data", "app.so")) != "engine 0.88.0" {
		t.Fatal("the folder the running copy uses was changed under it")
	}
}

func TestARelaunchWaitsForTheCopyItReplacesToExit(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 3)
	if got := runFrom(root, versionDir(root, "0.89.0"), true); got != runPath(root) {
		t.Fatalf("got %q", got)
	}
	if *paused != 3 {
		t.Fatalf("waited %d times", *paused)
	}
}

func TestARelaunchWhoseOldCopyNeverExitsStartsTheVersionFolder(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 1000)
	if got := runFrom(root, versionDir(root, "0.89.0"), true); got != versionDir(root, "0.89.0") {
		t.Fatalf("got %q", got)
	}
	if *paused != releaseTries-1 {
		t.Fatalf("waited %d times", *paused)
	}
}

func TestAVersionFileReplacedInPlaceIsLinkedAgain(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	asset := filepath.Join(versionDir(root, "0.88.0"), "data", "app.so")
	if err := os.Remove(asset); err != nil {
		t.Fatal(err)
	}
	put(t, filepath.Dir(asset), "app.so", "repaired")
	runFrom(root, versionDir(root, "0.88.0"), false)
	if contents(t, filepath.Join(runPath(root), "data", "app.so")) != "repaired" {
		t.Fatal("a repaired file must replace the stale link")
	}
}

func TestLeftoversOfAnInterruptedRebuildAreCleared(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	put(t, root, runFolder+".next", "half a tree")
	if err := os.MkdirAll(runPath(root)+".old", 0o755); err != nil {
		t.Fatal(err)
	}
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != runPath(root) {
		t.Fatalf("got %q", got)
	}
	if exists(runPath(root)+".next") || exists(runPath(root)+".old") {
		t.Fatal("a leftover survived the rebuild")
	}
}
