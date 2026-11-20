// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

const (
	oldLauncher = "old launcher"
	newLauncher = "new launcher " + selftestMarker
)

func installed(t *testing.T, shipped string) (root, self string) {
	t.Helper()
	root = layout(t, "0.89.0")
	put(t, root, "current", "0.89.0")
	put(t, root, launcherName, oldLauncher)
	put(t, filepath.Join(root, versionPrefix+"0.89.0"), launcherName, shipped)
	return root, filepath.Join(root, launcherName)
}

func passing() swapper { return swapper{rename: os.Rename, probe: func(string) error { return nil }} }

func contents(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestAStagedLauncherReplacesTheOldOneOnNextStart(t *testing.T) {
	root, self := installed(t, newLauncher)
	if err := passing().swapLauncher(root, self); err != nil {
		t.Fatal(err)
	}
	if contents(t, self) != newLauncher || contents(t, self+".old") != oldLauncher {
		t.Fatal("the new launcher should be in place with the old one kept beside it")
	}
	if exists(filepath.Join(root, "slim-m.new.exe")) {
		t.Fatal("the staged copy must not be left behind")
	}
	if err := passing().swapLauncher(root, self); err != nil || exists(self+".old") {
		t.Fatalf("the next start should be a no-op that drops the old file, got %v", err)
	}
}

func TestALauncherIsOnlySwappedOnceTheVersionHasRunCleanly(t *testing.T) {
	root, _ := installed(t, newLauncher)
	put(t, root, "pending", "0.89.0")
	if settled(root) {
		t.Fatal("a pending version is not settled")
	}
	os.Remove(filepath.Join(root, "pending"))
	if !settled(root) {
		t.Fatal("a version with no pending marker is settled")
	}
}

func TestAnInterruptedSwapLeavesTheOldLauncherWorking(t *testing.T) {
	root, self := installed(t, newLauncher)
	calls := 0
	failSecond := swapper{
		probe: func(string) error { return nil },
		rename: func(from, to string) error {
			calls++
			if calls == 2 {
				return errors.New("killed between the renames")
			}
			return os.Rename(from, to)
		},
	}
	if err := failSecond.swapLauncher(root, self); err == nil {
		t.Fatal("the failure should be reported")
	}
	if contents(t, self) != oldLauncher {
		t.Fatal("the old launcher must be back under its own name")
	}
}

func TestAReplacementThatFailsToStartIsNotSwappedIn(t *testing.T) {
	root, self := installed(t, newLauncher)
	broken := swapper{rename: os.Rename, probe: func(string) error { return errors.New("not a valid launcher") }}
	if err := broken.swapLauncher(root, self); err == nil {
		t.Fatal("the failed self-test should be reported")
	}
	if contents(t, self) != oldLauncher || exists(self+".old") || exists(filepath.Join(root, "slim-m.new.exe")) {
		t.Fatal("nothing should change and nothing should be left over")
	}
}

func TestALauncherWithoutTheSelftestIsNeverRun(t *testing.T) {
	root, self := installed(t, "a launcher that would start the app on any flag")
	probed := false
	spy := swapper{rename: os.Rename, probe: func(string) error { probed = true; return nil }}
	if err := spy.swapLauncher(root, self); err != nil || probed {
		t.Fatalf("it must be skipped untouched, probed=%v err=%v", probed, err)
	}
	if contents(t, self) != oldLauncher {
		t.Fatal("the old launcher must stay")
	}
}

func TestTheCopyInAVersionFolderRestoresAMissingLauncher(t *testing.T) {
	root, _ := installed(t, newLauncher)
	copyInVersion := filepath.Join(root, versionPrefix+"0.89.0", launcherName)
	if got := locate(copyInVersion); got != root {
		t.Fatalf("root = %q, want %q", got, root)
	}
	os.Remove(filepath.Join(root, launcherName))
	restoreLauncher(root, copyInVersion)
	if contents(t, filepath.Join(root, launcherName)) != newLauncher {
		t.Fatal("the root launcher should be back")
	}
}
