// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
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
	dir, err := choose(root)
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
		dir, err := choose(root)
		if err != nil || dir != versionDir(root, "0.89.0") {
			t.Fatalf("start %d: %q, %v", i+1, dir, err)
		}
		if got := read(root, "pending.tries"); got != want {
			t.Fatalf("start %d counted %q", i+1, got)
		}
	}
	dir, err := choose(root)
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
	if dir, err := choose(root); err != nil || dir != versionDir(root, "0.88.0") {
		t.Fatalf("got %q, %v", dir, err)
	}
}

func TestNeverRollsBackWithoutAPreviousVersion(t *testing.T) {
	root := layout(t, "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "pending", "0.89.0")
	put(t, root, "pending.tries", "9")
	if dir, err := choose(root); err != nil || dir != versionDir(root, "0.89.0") {
		t.Fatalf("got %q, %v", dir, err)
	}
}

func TestAMissingCurrentFolderFallsBackToPrevious(t *testing.T) {
	root := layout(t, "0.88.0")
	put(t, root, "current", "0.89.0")
	put(t, root, "previous", "0.88.0")
	dir, err := choose(root)
	if err != nil || dir != versionDir(root, "0.88.0") || read(root, "current") != "0.88.0" {
		t.Fatalf("got %q, %v", dir, err)
	}
}

func TestReportsWhenThereIsNothingToStart(t *testing.T) {
	root := layout(t)
	if _, err := choose(root); err == nil {
		t.Fatal("no pointer must be an error")
	}
	put(t, root, "current", "0.89.0")
	if _, err := choose(root); err == nil {
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
	t.Cleanup(func() { processAlive = osProcessAlive })

	for i := 0; i < 5; i++ {
		dir, err := choose(root)
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
	t.Cleanup(func() { processAlive = osProcessAlive })

	if _, err := choose(root); err != nil {
		t.Fatal(err)
	}
	if got := read(root, "pending.tries"); got != "1" {
		t.Fatalf("counted %q", got)
	}
}
