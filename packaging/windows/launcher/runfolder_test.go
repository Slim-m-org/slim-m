// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var errRefused = errors.New("refused")

// shipped lays out versions that know the run folder, each with a launcher and a data file.
func shipped(t *testing.T, versions ...string) string {
	t.Helper()
	root := layout(t, versions...)
	for _, v := range versions {
		dir := versionDir(root, v)
		put(t, dir, launcherName, "launcher "+v)
		put(t, dir, runFolderMarker, "")
		if err := os.MkdirAll(filepath.Join(dir, "data"), 0o755); err != nil {
			t.Fatal(err)
		}
		put(t, filepath.Join(dir, "data"), "app.so", "engine "+v)
	}
	return root
}

// stubRelease reports a copy running from the run folder for the first `busy` checks.
func stubRelease(t *testing.T, busy int) *int {
	t.Helper()
	paused := 0
	runningFrom = func(string) bool {
		if busy > 0 {
			busy--
			return true
		}
		return false
	}
	pause = func(time.Duration) { paused++ }
	t.Cleanup(func() { runningFrom, pause = processRunningFrom, time.Sleep })
	return &paused
}

// failRename makes every rename that matches fail.
func failRename(t *testing.T, matches func(from, to string) bool) {
	t.Helper()
	renamePath = func(from, to string) error {
		if matches(from, to) {
			return errRefused
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { renamePath = os.Rename })
}

func sameFile(t *testing.T, a, b string) bool {
	t.Helper()
	x, errA := os.Stat(a)
	y, errB := os.Stat(b)
	return errA == nil && errB == nil && os.SameFile(x, y)
}

func runPath(root string) string { return filepath.Join(root, runFolder) }

func engineIn(t *testing.T, dir string) string {
	t.Helper()
	return contents(t, filepath.Join(dir, "data", "app.so"))
}

func leftovers(t *testing.T, root string) []string {
	t.Helper()
	var found []string
	for _, pattern := range []string{".next*", ".old*"} {
		matches, err := filepath.Glob(runPath(root) + pattern)
		if err != nil {
			t.Fatal(err)
		}
		found = append(found, matches...)
	}
	return found
}

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

func TestAVersionWithoutTheMarkerRunsFromItsOwnFolder(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.89.0"), false)
	if err := os.Remove(filepath.Join(versionDir(root, "0.88.0"), runFolderMarker)); err != nil {
		t.Fatal(err)
	}
	if got := runFrom(root, versionDir(root, "0.88.0"), true); got != versionDir(root, "0.88.0") {
		t.Fatalf("a version that predates the run folder started from %q", got)
	}
	if engineIn(t, runPath(root)) != "engine 0.89.0" {
		t.Fatal("an older version was linked into the run folder")
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
	if engineIn(t, runPath(root)) != "engine 0.89.0" {
		t.Fatal("the run folder still holds the old version")
	}
	if engineIn(t, versionDir(root, "0.88.0")) != "engine 0.88.0" {
		t.Fatal("replacing the run folder touched the previous version, which rollback needs")
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
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
	if engineIn(t, runPath(root)) != "engine 0.88.0" {
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

func TestTheRelaunchWaitOutlastsTheRunnersOwn(t *testing.T) {
	if waited := time.Duration(releaseTries) * releasePoll; waited < 30*time.Second {
		t.Fatalf("waits %v, less than the runner's 30 s kRelaunchWaitMs", waited)
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
	if engineIn(t, runPath(root)) != "repaired" {
		t.Fatal("a repaired file must replace the stale link")
	}
}

func TestLeftoversOfAnInterruptedRebuildAreCleared(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	put(t, root, runFolder+".next-12", "half a tree")
	if err := os.MkdirAll(runPath(root)+".old-34", 0o755); err != nil {
		t.Fatal(err)
	}
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != runPath(root) {
		t.Fatalf("got %q", got)
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
	}
}

func TestALeftoverThatCannotBeRemovedDoesNotBlockTheRebuild(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	stuck := runPath(root) + ".old-99"
	if err := os.MkdirAll(filepath.Join(stuck, "locked"), 0o755); err != nil {
		t.Fatal(err)
	}
	put(t, filepath.Join(stuck, "locked"), "file", "")
	if err := os.Chmod(filepath.Join(stuck, "locked"), 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(stuck, "locked"), 0o755) })
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != runPath(root) {
		t.Fatalf("a stuck leftover blocked the rebuild: %q", got)
	}
}

func TestAFailedRebuildStartsTheVersionFolder(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	failRename(t, func(from, _ string) bool {
		return from == runPath(root) || strings.HasPrefix(from, runPath(root)+string(filepath.Separator))
	})
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != versionDir(root, "0.89.0") {
		t.Fatalf("started from %q after the rebuild failed", got)
	}
	if engineIn(t, runPath(root)) != "engine 0.88.0" {
		t.Fatal("a failed rebuild must leave the old run folder whole")
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
	}
}

func TestAFailedSwapPutsTheOldRunFolderBack(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	failRename(t, func(from, _ string) bool { return strings.HasPrefix(filepath.Base(from), runFolder+".next-") })
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != versionDir(root, "0.89.0") {
		t.Fatalf("got %q", got)
	}
	if engineIn(t, runPath(root)) != "engine 0.88.0" {
		t.Fatal("the old run folder was not put back after the swap failed")
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
	}
}

func TestAFailedLinkLeavesNoHalfTree(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	linkFile = func(string, string) error { return errRefused }
	t.Cleanup(func() { linkFile = os.Link })
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != versionDir(root, "0.88.0") {
		t.Fatalf("got %q", got)
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
	}
}

func TestAnIrregularEntryStartsTheVersionFolder(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	if err := os.Symlink(t.TempDir(), filepath.Join(versionDir(root, "0.88.0"), "data", "elsewhere")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != versionDir(root, "0.88.0") {
		t.Fatalf("a reparse point was skipped and the run folder used: %q", got)
	}
}

func TestARunningCopyIsFoundThroughAJunctionedPath(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	alias := filepath.Join(t.TempDir(), "profile")
	if err := os.Symlink(root, alias); err != nil {
		t.Skip("no symlinks here:", err)
	}
	image := filepath.Join(alias, runFolder, appExecutable)
	if !runsFrom(runPath(root), []string{image}) {
		t.Fatal("a copy started through another path to the same folder was missed")
	}
	if runsFrom(runPath(root), []string{filepath.Join(versionDir(root, "0.88.0"), appExecutable)}) {
		t.Fatal("a copy in a version folder does not run from the run folder")
	}
}

func TestOnlyFoldersNamedLikeTheRunFolderAreLookedAt(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	var looked []string
	statFolder = func(path string) (os.FileInfo, error) {
		looked = append(looked, path)
		return os.Stat(path)
	}
	t.Cleanup(func() { statFolder = os.Stat })
	images := []string{`\\\\stalled\\share\\tool.exe`, filepath.Join(versionDir(root, "0.88.0"), appExecutable),
		filepath.Join(strings.ToUpper(runPath(root)), appExecutable)}
	runsFrom(runPath(root), images)
	if len(looked) != 1 || filepath.Base(looked[0]) != strings.ToUpper(runFolder) {
		t.Fatalf("looked at %v", looked)
	}
}

func TestAFolderHeldOpenBrieflyAfterItsCopyExitedIsStillReplaced(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	paused := stubRelease(t, 0)
	held := 4
	failRename(t, func(from, _ string) bool {
		if from == runPath(root) && held > 0 {
			held--
			return true
		}
		return false
	})
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != runPath(root) || *paused != 4 {
		t.Fatalf("started from %q after %d waits", got, *paused)
	}
	if engineIn(t, runPath(root)) != "engine 0.89.0" {
		t.Fatal("the run folder still holds the old version")
	}
}
