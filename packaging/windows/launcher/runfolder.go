// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	// runFolder is where every version runs from. Windows Firewall keys its rules
	// on the listening exe's full path, so a run from each `app-<version>` folder
	// asked again after every update. The folder holds hard links, which need no
	// elevation; a junction would not do, as the firewall records its target.
	runFolder = "app"
	// runFolderMarker ships in every version whose app knows the run folder
	// (client/packages/app/windows/CMakeLists.txt); an older one runs from its own folder.
	runFolderMarker = "layout-run-folder"
	// releaseTries spaced by releasePoll outlasts the runner's own 30 s wait for the copy a relaunch replaces.
	releaseTries = 160
	releasePoll  = 200 * time.Millisecond
)

// The steps tests replace: they cannot run an exe from a folder or make a link or rename fail.
var (
	runningFrom = processRunningFrom
	pause       = time.Sleep
	linkFile    = os.Link
	renamePath  = os.Rename
)

// runFrom returns the folder to start the version in dir from: the run folder
// when it holds that version or can be rebuilt to, and dir itself otherwise.
// wait gives a copy that is exiting from the run folder time to go.
func runFrom(root, dir string, wait bool) string {
	if !exists(filepath.Join(dir, runFolderMarker)) {
		return dir
	}
	run := filepath.Join(root, runFolder)
	if mirrors(dir, run) {
		return run
	}
	tries := 1
	if wait {
		tries = releaseTries
	}
	if !release(run, tries) || rebuild(dir, run) != nil {
		return dir
	}
	return run
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// errIrregular stops a mirror at a reparse point or device, which a hard link cannot copy faithfully.
var errIrregular = errors.New("the version folder holds something that is neither a file nor a folder")

// linked says whether the run folder links this entry: every file but the
// launcher, which only works from the root.
func linked(rel string, entry fs.DirEntry) (bool, error) {
	if entry.IsDir() {
		return false, nil
	}
	if !entry.Type().IsRegular() {
		return false, errIrregular
	}
	return !strings.EqualFold(rel, launcherName), nil
}

// mirrors reports whether every file of src is the very same file under run.
func mirrors(src, run string) bool {
	found := false
	err := filepath.WalkDir(src, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if ok, err := linked(rel, entry); !ok {
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

// runsFrom reports whether any of images sits directly in run, comparing
// folders by identity so a junctioned profile path still matches.
func runsFrom(run string, images []string) bool {
	want, err := os.Stat(run)
	if err != nil {
		return false
	}
	for _, image := range images {
		if have, err := os.Stat(filepath.Dir(image)); err == nil && os.SameFile(want, have) {
			return true
		}
	}
	return false
}

// rebuild links src into a fresh folder and renames it over run, so a failure
// part way leaves the old run folder or none, never a mix of two versions.
// The names carry this launcher's pid, so a stuck leftover never blocks a rebuild.
func rebuild(src, run string) error {
	clearLeftovers(run)
	suffix := strconv.Itoa(os.Getpid())
	next, old := run+".next-"+suffix, run+".old-"+suffix
	if err := linkTree(src, next); err != nil {
		_ = os.RemoveAll(next)
		return err
	}
	if err := renamePath(run, old); err != nil && !errors.Is(err, fs.ErrNotExist) {
		_ = os.RemoveAll(next)
		return err
	}
	if err := renamePath(next, run); err != nil {
		_ = renamePath(old, run)
		_ = os.RemoveAll(next)
		return err
	}
	_ = os.RemoveAll(old)
	return nil
}

// clearLeftovers removes what interrupted rebuilds left; one that cannot go yet is retried next time.
func clearLeftovers(run string) {
	for _, pattern := range []string{run + ".next-*", run + ".old-*"} {
		matches, _ := filepath.Glob(pattern)
		for _, leftover := range matches {
			_ = os.RemoveAll(leftover)
		}
	}
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
		if ok, err := linked(rel, entry); !ok {
			return err
		}
		return linkFile(path, target)
	})
}
