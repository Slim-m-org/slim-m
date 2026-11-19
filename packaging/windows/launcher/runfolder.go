// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	// runFolder is where every version runs from. Windows Firewall keys its rules
	// on the listening exe's full path, so a run from each `app-<version>` folder
	// asked again after every update. The folder holds hard links, which need no
	// elevation; a junction would not do, as the firewall records its target.
	runFolder = "app"
	// releaseTries spaced by releasePoll is how long a relaunch waits for the copy it replaces to exit.
	releaseTries = 75
	releasePoll  = 200 * time.Millisecond
)

// runningFrom and pause are replaced in tests, which cannot run an exe from a folder.
var (
	runningFrom = processRunningFrom
	pause       = time.Sleep
)

// runFrom returns the folder to start the version in dir from: the run folder
// when it holds that version or can be rebuilt to, and dir itself otherwise.
func runFrom(root, dir string, relaunch bool) string {
	run := filepath.Join(root, runFolder)
	if mirrors(dir, run) {
		return run
	}
	tries := 1
	if relaunch {
		tries = releaseTries
	}
	if !release(run, tries) || rebuild(dir, run) != nil {
		return dir
	}
	return run
}

// mirrored lists what the run folder links: everything but the launcher, which
// only works from the root.
func mirrored(rel string, entry fs.DirEntry) bool {
	return entry.Type().IsRegular() && !strings.EqualFold(rel, launcherName)
}

// mirrors reports whether every file of src is the very same file under run.
func mirrors(src, run string) bool {
	found := false
	err := filepath.WalkDir(src, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil || !mirrored(rel, entry) {
			return err
		}
		want, err := os.Stat(path)
		if err != nil {
			return err
		}
		have, err := os.Lstat(filepath.Join(run, rel))
		if err != nil {
			return err
		}
		if !os.SameFile(want, have) {
			return errors.New(rel + " differs")
		}
		found = true
		return nil
	})
	return err == nil && found
}

// release reports whether nothing runs from the run folder, asking up to tries
// times. Neither deleting the exe nor renaming the folder proves it: Windows
// allows both for a hard link or a folder whose running exe holds no handles.
func release(run string, tries int) bool {
	for i := 0; i < tries; i++ {
		if !runningFrom(run) {
			return true
		}
		if i+1 < tries {
			pause(releasePoll)
		}
	}
	return false
}

// rebuild links src into a fresh folder and renames it over run, so a failure
// part way leaves the old run folder or none, never a mix of two versions.
func rebuild(src, run string) error {
	next, old := run+".next", run+".old"
	for _, leftover := range []string{next, old} {
		if err := os.RemoveAll(leftover); err != nil {
			return err
		}
	}
	if err := linkTree(src, next); err != nil {
		_ = os.RemoveAll(next)
		return err
	}
	if err := os.Rename(run, old); err != nil && !errors.Is(err, fs.ErrNotExist) {
		_ = os.RemoveAll(next)
		return err
	}
	if err := os.Rename(next, run); err != nil {
		_ = os.Rename(old, run)
		return err
	}
	_ = os.RemoveAll(old)
	return nil
}

func linkTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if !mirrored(rel, entry) {
			return nil
		}
		return os.Link(path, target)
	})
}
