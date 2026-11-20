// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// holdRunFolder refuses to rename the run folder itself, as Windows does while Explorer holds a file in it.
func holdRunFolder(t *testing.T, root string, into *[]string) {
	t.Helper()
	renamePath = func(from, to string) error {
		if from == runPath(root) {
			return errRefused
		}
		if into != nil && filepath.Dir(to) == runPath(root) {
			*into = append(*into, filepath.Base(to))
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { renamePath = os.Rename })
}

func TestAHeldRunFolderIsRelinkedFileByFile(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	put(t, versionDir(root, "0.88.0"), "dropped.dll", "")
	runFrom(root, versionDir(root, "0.88.0"), false)
	holdRunFolder(t, root, nil)
	if got := runFrom(root, versionDir(root, "0.89.0"), false); got != runPath(root) {
		t.Fatalf("started from %q", got)
	}
	if !mirrors(versionDir(root, "0.89.0"), runPath(root)) {
		t.Fatal("the run folder is not a whole copy of the new version")
	}
	if exists(filepath.Join(runPath(root), "dropped.dll")) {
		t.Fatal("a file the new version no longer ships was left in the run folder")
	}
	if left := leftovers(t, root); len(left) > 0 {
		t.Fatalf("left behind %v", left)
	}
}

func TestAFileByFileSwapPutsTheExeInLast(t *testing.T) {
	root := shipped(t, "0.88.0", "0.89.0")
	stubRelease(t, 0)
	put(t, versionDir(root, "0.89.0"), "zz_plugin.dll", "")
	runFrom(root, versionDir(root, "0.88.0"), false)
	var order []string
	holdRunFolder(t, root, &order)
	runFrom(root, versionDir(root, "0.89.0"), false)
	if len(order) == 0 || order[len(order)-1] != appExecutable {
		t.Fatalf("files went in as %v", order)
	}
}
