// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// holdRunFolder refuses to rename the run folder itself while *held, as Windows does while Explorer holds a file in it.
func holdRunFolder(t *testing.T, root string, held *bool) {
	t.Helper()
	renamePath = func(from, to string) error {
		if *held && from == runPath(root) {
			return errRefused
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { renamePath = os.Rename })
}

func TestAHeldRunFolderIsLeftWholeAndRelinkedNextTime(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	held := true
	holdRunFolder(t, root, &held)
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != versionDir(root, "0.89.0") {
		t.Fatalf("started from %q while the run folder was held", got)
	}
	if !mirrors(versionDir(root, "0.88.0"), runPath(root)) {
		t.Fatal("a held run folder must stay a whole copy of the old version")
	}
	held = false
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != runPath(root) {
		t.Fatalf("the next start did not relink: %q", got)
	}
	if !mirrors(versionDir(root, "0.89.0"), runPath(root)) {
		t.Fatal("the run folder is not a whole copy of the new version")
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
	}
}

func TestAnExtraFileInTheRunFolderForcesARelink(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	put(t, runPath(root), "dropped.dll", "")
	if err := os.MkdirAll(filepath.Join(runPath(root), "empty"), 0o755); err != nil {
		t.Fatal(err)
	}
	if mirrors(versionDir(root, "0.88.0"), runPath(root)) {
		t.Fatal("a file the version does not ship passed as part of it")
	}
	if got := runFrom(root, versionDir(root, "0.88.0"), false); got != runPath(root) {
		t.Fatalf("got %q", got)
	}
	if exists(filepath.Join(runPath(root), "dropped.dll")) {
		t.Fatal("the stray file survived the relink")
	}
}

func TestAnEmptyLeftoverFolderDoesNotForceARelink(t *testing.T) {
	root := shipped(t, "0.88.0")
	stubRelease(t, 0)
	runFrom(root, versionDir(root, "0.88.0"), false)
	if err := os.MkdirAll(filepath.Join(runPath(root), "empty"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !mirrors(versionDir(root, "0.88.0"), runPath(root)) {
		t.Fatal("an empty folder made the run folder look stale")
	}
}
