// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func layout(t *testing.T, versions ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, v := range versions {
		dir := versionDir(root, v)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, appExecutable), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func put(t *testing.T, root, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestStartsTheCurrentVersion(t *testing.T) {
	root := layout(t, "0.88.0")
	put(t, root, "current", "0.88.0\r\n")
	dir, err := choose(root, false)
	if err != nil || dir != versionDir(root, "0.88.0") {
		t.Fatalf("got %q, %v", dir, err)
	}
	if read(root, "pending.tries") != "" {
		t.Fatal("a confirmed version must not be counted")
	}
}

func TestCountsStartsOfAPendingVersionThenRollsBackOnTheThird(t *testing.T) {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	for i, want := range []string{"1", "2"} {
		dir, err := choose(root, false)
		if err != nil || dir != versionDir(root, "0.89.0") {
			t.Fatalf("start %d: %q, %v", i+1, dir, err)
		}
		if got := read(root, "pending.tries"); got != want {
			t.Fatalf("start %d counted %q", i+1, got)
		}
	}
	dir, err := choose(root, false)
	if err != nil || dir != versionDir(root, "0.88.0") {
		t.Fatalf("third start: %q, %v", dir, err)
	}
	if read(root, "current") != "0.88.0" || read(root, "rolled-back") != "0.89.0" {
		t.Fatal("rollback did not move the pointer and leave its marker")
	}
	for _, name := range []string{"pending", "pending.tries", "previous"} {
		if _, err := os.Stat(filepath.Join(root, name)); err == nil {
			t.Fatalf("%s survived the rollback", name)
		}
	}
}

func TestStaleMarkerForAnotherVersionIsIgnored(t *testing.T) {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.88.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "pending.tries", "5")
	if dir, err := choose(root, false); err != nil || dir != versionDir(root, "0.88.0") {
		t.Fatalf("got %q, %v", dir, err)
	}
}

func TestNeverRollsBackWithoutAPreviousVersion(t *testing.T) {
	root := layout(t, "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "pending.tries", "9")
	if dir, err := choose(root, false); err != nil || dir != versionDir(root, "0.89.0") {
		t.Fatalf("got %q, %v", dir, err)
	}
}

func TestAMissingCurrentFolderFallsBackToPrevious(t *testing.T) {
	root := layout(t, "0.88.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	dir, err := choose(root, false)
	if err != nil || dir != versionDir(root, "0.88.0") || read(root, "current") != "0.88.0" {
		t.Fatalf("got %q, %v", dir, err)
	}
}

func TestReportsWhenThereIsNothingToStart(t *testing.T) {
	root := layout(t)
	if _, err := choose(root, false); err == nil {
		t.Fatal("no pointer must be an error")
	}
	put(t, root, "current", "0.89.0")
	if _, err := choose(root, false); err == nil {
		t.Fatal("a pointer to a missing folder with no previous must be an error")
	}
}

func TestPointerWriteReplacesAtomically(t *testing.T) {
	root := layout(t)
	put(t, root, "current", "0.88.0")
	if err := write(root, "current", "0.89.0"); err != nil {
		t.Fatal(err)
	}
	if read(root, "current") != "0.89.0" {
		t.Fatal("pointer not replaced")
	}
	if _, err := os.Stat(filepath.Join(root, ".current.launcher")); err == nil {
		t.Fatal("temp file left behind")
	}
}

func TestStartsBesideARunningInstanceAreNotCounted(t *testing.T) {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "running.pid", "4242")
	processAlive = func(pid int) bool { return pid == 4242 }
	processIsApp = func(int) bool { return true }
	t.Cleanup(func() { processAlive, processIsApp = osProcessAlive, osProcessIsApp })

	for i := 0; i < 5; i++ {
		dir, err := choose(root, false)
		if err != nil || dir != versionDir(root, "0.89.0") {
			t.Fatalf("start %d: %q, %v", i+1, dir, err)
		}
	}
	if got := read(root, "pending.tries"); got != "" {
		t.Fatalf("counted %q starts while the app was up", got)
	}
	if read(root, "current") != "0.89.0" {
		t.Fatal("a healthy running version was rolled back")
	}
}

func TestAStartAfterTheInstanceIsGoneIsCountedAgain(t *testing.T) {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "running.pid", "4242")
	processAlive = func(int) bool { return false }
	processIsApp = func(int) bool { return true }
	t.Cleanup(func() { processAlive, processIsApp = osProcessAlive, osProcessIsApp })

	if _, err := choose(root, false); err != nil {
		t.Fatal(err)
	}
	if got := read(root, "pending.tries"); got != "1" {
		t.Fatalf("counted %q", got)
	}
}

func TestARelaunchIsCountedEvenWhileItsPredecessorExits(t *testing.T) {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "running.pid", "4242")
	processAlive = func(pid int) bool { return pid == 4242 }
	processIsApp = func(int) bool { return true }
	t.Cleanup(func() { processAlive, processIsApp = osProcessAlive, osProcessIsApp })

	if _, err := choose(root, true); err != nil {
		t.Fatal(err)
	}
	if got := read(root, "pending.tries"); got != "1" {
		t.Fatalf("counted %q", got)
	}
}

func TestOnlyARelaunchReplacesTheRecordedPidOfALiveInstance(t *testing.T) {
	cases := []struct{ running, relaunch, want bool }{
		{false, false, true},
		{true, false, false},
		{true, true, true},
		{false, true, true},
	}
	for _, c := range cases {
		if got := shouldRecordPid(c.running, c.relaunch); got != c.want {
			t.Errorf("running=%v relaunch=%v: got %v", c.running, c.relaunch, got)
		}
	}
}

func TestRecognisesTheRelaunchArgument(t *testing.T) {
	if !isRelaunch([]string{"--relaunch"}) || isRelaunch([]string{"--other"}) || isRelaunch(nil) {
		t.Fatal("relaunch detection is wrong")
	}
}

func TestAPidNowOwnedByAnotherProgramIsNotTheApp(t *testing.T) {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "running.pid", strconv.Itoa(os.Getpid()))
	if instanceRunning(root) {
		t.Fatal("this test binary is not slimm_app.exe")
	}
	if _, err := choose(root, false); err != nil {
		t.Fatal(err)
	}
	if got := read(root, "pending.tries"); got != "1" {
		t.Fatalf("counted %q", got)
	}
}

func TestRecognisesTheAppImageByName(t *testing.T) {
	for path, want := range map[string]bool{
		`C:\Users\a\AppData\Local\slim-m\app-1.0.0\slimm_app.exe`: true,
		"/x/SLIMM_APP.EXE":       true,
		`C:\Windows\notepad.exe`: false,
		"":                       false,
	} {
		if isAppImage(path) != want {
			t.Errorf("%q: want %v", path, want)
		}
	}
}

// quit is one launch of the pending version; ready says whether that run reached the app's started marker.
func quit(t *testing.T, root string, ready bool) string {
	t.Helper()
	dir, err := choose(root, false)
	if err != nil {
		t.Fatal(err)
	}
	if ready {
		put(t, root, pendingStarted, "")
	}
	return dir
}

func pendingLayout(t *testing.T) string {
	root := layout(t, "0.88.0", "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	put(t, root, "pending", "0.89.0")
	return root
}

func TestQuickQuitsOfAWorkingVersionNeverRollBack(t *testing.T) {
	root := pendingLayout(t)
	for i := 0; i < 6; i++ {
		if dir := quit(t, root, true); dir != versionDir(root, "0.89.0") {
			t.Fatalf("start %d went to %q", i+1, dir)
		}
	}
	if read(root, "current") != "0.89.0" || read(root, "rolled-back") != "" {
		t.Fatal("a version that reached ready was rolled back")
	}
}

func TestCrashesBeforeReadyRollBackOnTheThirdStart(t *testing.T) {
	root := pendingLayout(t)
	quit(t, root, false)
	quit(t, root, false)
	if dir := quit(t, root, false); dir != versionDir(root, "0.88.0") {
		t.Fatalf("third start went to %q", dir)
	}
	if read(root, "rolled-back") != "0.89.0" {
		t.Fatal("no rollback marker")
	}
}

func TestACrashBetweenReadyRunsDoesNotAccumulate(t *testing.T) {
	root := pendingLayout(t)
	quit(t, root, true)
	quit(t, root, false)
	quit(t, root, true)
	quit(t, root, true)
	if read(root, "current") != "0.89.0" {
		t.Fatal("one early failure among ready runs rolled back")
	}
}
